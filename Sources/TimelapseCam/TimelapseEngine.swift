import AVFoundation
import AppKit
import CoreImage
import IOKit.pwr_mgt
import Vision

// MARK: - Option types

enum Resolution: String, CaseIterable, Identifiable {
    case hd720, hd1080, uhd4k

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .uhd4k: return "4K"
        }
    }

    var preset: AVCaptureSession.Preset {
        switch self {
        case .hd720: return .hd1280x720
        case .hd1080: return .hd1920x1080
        case .uhd4k: return .hd4K3840x2160
        }
    }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc, h264

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hevc: return "HEVC (smaller files)"
        case .h264: return "H.264 (most compatible)"
        }
    }

    var avType: AVVideoCodecType {
        switch self {
        case .hevc: return .hevc
        case .h264: return .h264
        }
    }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case low, medium, high

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Target bits per pixel per frame; higher means larger files and sharper video.
    var bitsPerPixel: Double {
        switch self {
        case .low: return 0.05
        case .medium: return 0.12
        case .high: return 0.25
        }
    }
}

/// Camera-side settings. Stored with @AppStorage under the same keys, read with `fromStorage()`.
struct CameraSettings: Equatable {
    var resolution: Resolution = .hd1080
    var mirror = true
    var exposureBias: Float = 0      // software brightness in EV, -3...+3
    var lockExposure = false
    var lockWhiteBalance = false

    static func fromStorage(_ d: UserDefaults = .standard) -> CameraSettings {
        CameraSettings(
            resolution: Resolution(rawValue: d.string(forKey: "resolution") ?? "") ?? .hd1080,
            mirror: d.object(forKey: "mirror") as? Bool ?? true,
            exposureBias: Float(d.double(forKey: "exposureBias")),
            lockExposure: d.bool(forKey: "lockExposure"),
            lockWhiteBalance: d.bool(forKey: "lockWhiteBalance")
        )
    }
}

/// The clock overlay. Position is the centre as fractions of the frame (0,0 = top left).
struct ClockSettings: Equatable {
    var enabled = false
    var x: Double = 0.85
    var y: Double = 0.85
    var burn = false   // also draw the clock into the main video
    var tintHex = "#FFFFFF"   // glass colour of the clock
    var style: ClockStyle = .digital
    var warp: ClockQuad? = nil   // when set, the clock is drawn in perspective into these corners
    var occlude = false          // cut people out of the clock so it looks like it's behind them
}

enum ClockStyle: String, CaseIterable, Identifiable {
    case digital, analog

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Analog clock diameter as a fraction of the frame height (same in preview and video).
    static let analogDiameter: CGFloat = 0.24

    /// Width:height of the clock's own canvas before it's warped onto a wall.
    var canvasAspect: CGFloat { self == .analog ? 1 : 3.6 }
}

/// Hand angles in degrees clockwise from 12, with a smoothly sweeping second hand.
func clockHandAngles(for date: Date) -> (hour: Double, minute: Double, second: Double) {
    let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
    let second = Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1_000_000_000
    let minute = Double(c.minute ?? 0) + second / 60
    let hour = Double((c.hour ?? 0) % 12) + minute / 60
    return (hour * 30, minute * 6, second * 6)
}

/// Settings used by the capture queue while a recording is active.
struct RecordingSettings {
    let url: URL
    let interval: TimeInterval   // real seconds between captured frames
    let fps: Int                 // playback frame rate of the finished video
    let codec: VideoCodec
    let quality: VideoQuality
    let clockURL: URL?           // separate transparent clock video, if enabled
}

/// The separate clock video writer, which runs alongside the main file.
private struct ClockFile {
    let url: URL
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
}

// MARK: - Engine

/// Owns the camera session, captures frames at the chosen interval and
/// writes them to a .mov file. Each captured frame becomes one output frame,
/// so a 1 hour recording at 1 frame / 5 s and 30 fps plays back in 24 s.
final class TimelapseEngine: NSObject, ObservableObject {

    // MARK: UI state (main thread only)

    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var selectedCameraID = ""
    @Published private(set) var isPreviewing = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0     // wall-clock recording time, excluding pauses
    @Published private(set) var frames = 0
    @Published private(set) var fileSize: Int64 = 0
    @Published private(set) var videoSeconds: Double = 0      // how long the finished video will play
    @Published private(set) var thumbnail: NSImage?           // last captured frame
    @Published private(set) var savedURL: URL?
    @Published var errorMessage: String?
    /// Where people are in the live view, as an alpha mask: opaque = background, clear = person.
    @Published private(set) var personMask: CGImage?
    /// Flat shapes currently visible (top-left origin, TL/TR/BR/BL), while surface scanning is on.
    @Published private(set) var surfaces: [TrackedSurface] = []
    private var surfaceScanningOnMain = false   // drops late results after scanning is switched off
    private var wallDetectionPending = false     // main thread
    private var frameDeliveryOn = false          // only touched on `sessionQueue`

    private var activeURL: URL?
    private var autoStopAfter: TimeInterval = 0
    private var timer: Timer?
    private var sleepAssertion: IOPMAssertionID = 0
    private var mainClock = ClockSettings()    // main-thread copy, used when a recording starts

    // MARK: Capture pipeline

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "timelapse.session")
    private let videoQueue = DispatchQueue(label: "timelapse.video", qos: .userInitiated)
    private let ciContext = CIContext()
    private var currentInput: AVCaptureDeviceInput?
    private var camera = CameraSettings()          // only touched on `sessionQueue`

    // Everything below is only touched on `videoQueue`.
    private var config: RecordingSettings?
    private var outputURL: URL?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var clockFile: ClockFile?
    private var pendingStart = false
    private var paused = false
    private var frameIndex: Int64 = 0
    private var lastCapture: CFAbsoluteTime?
    private var lastThumbnail: CFAbsoluteTime?
    private var exposureEV: Float = 0      // software brightness (EV) applied to saved frames
    private var clock = ClockSettings()
    private var wallDetection: (([[CGPoint]]) -> Void)?   // pending "detect wall" request
    private var surfaceScanning = false
    private var lastSurfaceScan: CFAbsoluteTime = 0
    private let surfaceTracker = SurfaceTracker()   // smooths surfaces from scan to scan
    private var latestPersonMask: CIImage?                 // white = person, at camera-frame size
    private var lastMaskTime: CFAbsoluteTime = 0
    private let segmentation: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private let sequenceHandler = VNSequenceRequestHandler()   // smooths the mask from frame to frame

    // MARK: Camera & preview

    /// Asks for camera permission if needed, then starts the live preview.
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginPreview()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.beginPreview() } else { self.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    private func beginPreview() {
        permissionDenied = false
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
        cameras = found
        if !found.contains(where: { $0.uniqueID == selectedCameraID }) {
            selectedCameraID = found.first?.uniqueID ?? ""
        }
        if selectedCameraID.isEmpty {
            errorMessage = "No camera found."
            return
        }
        selectCamera(selectedCameraID)
    }

    /// Switches the live feed to another camera. Ignored while recording.
    func selectCamera(_ id: String) {
        guard !isRecording, !id.isEmpty else { return }
        selectedCameraID = id
        sessionQueue.async {
            let ok = self.configureInput(id)
            if ok && !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async {
                self.isPreviewing = ok
                if !ok { self.errorMessage = "Couldn't open that camera." }
            }
        }
    }

    /// Applies camera settings (resolution, mirror, exposure) to the live session.
    func applyCamera(_ settings: CameraSettings) {
        let ev = settings.exposureBias
        videoQueue.async { self.exposureEV = ev }
        sessionQueue.async {
            let resolutionChanged = settings.resolution != self.camera.resolution
            self.camera = settings
            if resolutionChanged, let id = self.currentInput?.device.uniqueID {
                _ = self.configureInput(id)
            } else {
                self.applyMirror()
                self.applyTuning()
            }
        }
    }

    /// Looks for flat rectangles in view (posters, frames, doors, windows) on the next frame.
    /// Calls back on the main thread with each one's corners (top-left origin, TL/TR/BR/BL);
    /// empty if none were found.
    func detectWall(completion: @escaping ([[CGPoint]]) -> Void) {
        wallDetectionPending = true
        refreshFrameDelivery()
        videoQueue.async {
            self.wallDetection = { walls in
                self.wallDetectionPending = false
                self.refreshFrameDelivery()
                completion(walls)
            }
        }
    }

    /// Camera frames are only sent to the app (and converted, which costs CPU) when something uses them:
    /// recording, a wall detection, keeping the clock behind people, or surface scanning.
    /// The live preview doesn't need them; macOS draws it separately.
    private func refreshFrameDelivery() {
        let needed = isRecording || wallDetectionPending || surfaceScanningOnMain
            || (mainClock.enabled && mainClock.occlude)
        sessionQueue.async {
            self.frameDeliveryOn = needed
            self.videoOutput.connection(with: .video)?.isEnabled = needed
        }
    }

    /// Runs on `videoQueue`.
    private func findWallShapes(in pixels: CVPixelBuffer) -> [[CGPoint]] {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.08
        request.quadratureTolerance = 35   // allow strong perspective
        request.minimumConfidence = 0.4
        request.maximumObservations = 12
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:]).perform([request])
        // Vision uses a bottom-left origin; the app uses top-left.
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        return (request.results ?? []).map {
            [flip($0.topLeft), flip($0.topRight), flip($0.bottomRight), flip($0.bottomLeft)]
        }
    }

    /// Updates the clock overlay. Safe to call while recording; the clock file follows the change.
    func updateClock(_ settings: ClockSettings) {
        mainClock = settings
        refreshFrameDelivery()
        let maskingOn = settings.enabled && settings.occlude
        if !maskingOn { personMask = nil }
        videoQueue.async {
            self.clock = settings
            if !maskingOn { self.latestPersonMask = nil }
        }
    }

    /// While on, looks for flat shapes about three times a second and publishes the tracked,
    /// smoothed result in `surfaces`.
    func setSurfaceScanning(_ on: Bool) {
        surfaceScanningOnMain = on
        refreshFrameDelivery()
        if !on { surfaces = [] }
        videoQueue.async {
            self.surfaceScanning = on
            self.lastSurfaceScan = 0
            self.surfaceTracker.reset()
        }
    }

    /// Finds people in the frame. Runs on `videoQueue`.
    private func updatePersonMask(from frame: CVPixelBuffer) {
        try? sequenceHandler.perform([segmentation], on: frame, orientation: .up)
        guard let maskBuffer = segmentation.results?.first?.pixelBuffer else {
            latestPersonMask = nil
            DispatchQueue.main.async { self.personMask = nil }
            return
        }
        let mask = CIImage(cvPixelBuffer: maskBuffer)   // white = person, at the model's own size
        let scaleX = CGFloat(CVPixelBufferGetWidth(frame)) / mask.extent.width
        let scaleY = CGFloat(CVPixelBufferGetHeight(frame)) / mask.extent.height
        latestPersonMask = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // For the preview: opaque where the clock may show, clear where a person is.
        let previewMask = mask.applyingFilter("CIColorInvert").applyingFilter("CIMaskToAlpha")
        let image = ciContext.createCGImage(previewMask, from: mask.extent)
        DispatchQueue.main.async { self.personMask = image }
    }

    /// The clock frame with people cut out of it (transparent where a person is). Runs on `videoQueue`.
    private func cutOutPeople(from clockFrame: CVPixelBuffer, mask: CIImage) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(clockFrame), height = CVPixelBufferGetHeight(clockFrame)
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return nil }
        let clear = CIImage(color: CIColor.clear).cropped(to: full)
        filter.setValue(clear, forKey: kCIInputImageKey)                         // used where the mask is white
        filter.setValue(CIImage(cvPixelBuffer: clockFrame), forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask.cropped(to: full), forKey: kCIInputMaskImageKey)
        guard let image = filter.outputImage else { return nil }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var output: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &output)
        guard let output else { return nil }
        ciContext.render(image, to: output, bounds: full, colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    /// Runs on `sessionQueue`.
    private func configureInput(_ id: String) -> Bool {
        guard let device = AVCaptureDevice(uniqueID: id),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        session.beginConfiguration()
        if let old = currentInput { session.removeInput(old) }
        if session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        }
        // Fall back to the best preset the camera supports if the chosen one isn't available.
        let preset = camera.resolution.preset
        session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .high

        if !session.outputs.contains(videoOutput) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        }
        applyMirror()
        session.commitConfiguration()
        applyTuning()
        videoOutput.connection(with: .video)?.isEnabled = frameDeliveryOn
        return true
    }

    /// Runs on `sessionQueue`.
    private func applyMirror() {
        guard let connection = videoOutput.connection(with: .video),
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = camera.mirror
    }

    /// Exposure and white balance. Runs on `sessionQueue`.
    private func applyTuning() {
        guard let device = currentInput?.device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if camera.lockExposure {
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            } else if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }

            if camera.lockWhiteBalance {
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        } catch {
            // Device couldn't be locked; keep the current exposure settings.
        }
    }

    // MARK: Recording controls

    func startRecording(folder: URL,
                        interval: TimeInterval,
                        fps: Int,
                        codec: VideoCodec,
                        quality: VideoQuality,
                        keepAwake: Bool,
                        stopAfter: TimeInterval) {
        guard isPreviewing, !isRecording else { return }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Can't use that folder: \(error.localizedDescription)"
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Timelapse \(formatter.string(from: Date()))"
        let url = folder.appendingPathComponent("\(base).mov")
        let clockURL = mainClock.enabled ? folder.appendingPathComponent("\(base) clock.mov") : nil
        let settings = RecordingSettings(url: url, interval: interval, fps: fps,
                                         codec: codec, quality: quality, clockURL: clockURL)

        errorMessage = nil
        savedURL = nil
        thumbnail = nil
        elapsed = 0
        frames = 0
        fileSize = 0
        videoSeconds = 0
        isPaused = false
        isRecording = true
        refreshFrameDelivery()
        activeURL = url
        autoStopAfter = stopAfter
        if keepAwake { setKeepAwake(true) }

        videoQueue.async {
            self.config = settings
            self.outputURL = url
            self.frameIndex = 0
            self.lastCapture = nil
            self.paused = false
            self.pendingStart = true
            self.lastThumbnail = nil
        }
        startTimer()
    }

    func togglePause() {
        guard isRecording else { return }
        isPaused.toggle()
        let nowPaused = isPaused
        videoQueue.async { self.paused = nowPaused }
    }

    func stopRecording() {
        guard isRecording else { return }
        videoQueue.async {
            let url = self.outputURL
            let count = self.frameIndex
            let writer = self.writer
            let input = self.writerInput
            let clockFile = self.clockFile

            // No more frames will be appended after this point.
            self.resetCaptureState()

            guard let writer, let input, count > 0 else {
                // Nothing was captured: discard the empty files.
                writer?.cancelWriting()
                clockFile?.writer.cancelWriting()
                if let url { try? FileManager.default.removeItem(at: url) }
                if let clockURL = clockFile?.url { try? FileManager.default.removeItem(at: clockURL) }
                DispatchQueue.main.async { self.finishRecording(savedAt: nil, error: nil) }
                return
            }

            let group = DispatchGroup()
            input.markAsFinished()
            group.enter()
            writer.finishWriting { group.leave() }

            if let clockFile {
                clockFile.input.markAsFinished()
                group.enter()
                clockFile.writer.finishWriting { group.leave() }
            }

            group.notify(queue: .main) {
                let ok = writer.status == .completed
                self.finishRecording(savedAt: ok ? url : nil, error: writer.error)
            }
        }
    }

    /// Runs on `videoQueue`.
    private func resetCaptureState() {
        config = nil
        writer = nil
        writerInput = nil
        adaptor = nil
        clockFile = nil
        pendingStart = false
        paused = false
    }

    private func finishRecording(savedAt url: URL?, error: Error?) {
        timer?.invalidate()
        timer = nil
        setKeepAwake(false)
        isRecording = false
        refreshFrameDelivery()
        isPaused = false
        refreshFileSize()
        if let error {
            errorMessage = "Couldn't finish the video: \(error.localizedDescription)"
        } else if let url, frames > 0 {
            savedURL = url
        }
    }

    // MARK: Timer, file size, keep-awake

    private func startTimer() {
        timer?.invalidate()
        var last = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            let now = Date()
            let delta = now.timeIntervalSince(last)
            last = now
            if !self.isPaused { self.elapsed += delta }
            self.refreshFileSize()
            if self.autoStopAfter > 0, self.elapsed >= self.autoStopAfter {
                self.stopRecording()
            }
        }
    }

    private func refreshFileSize() {
        guard let url = activeURL else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func setKeepAwake(_ on: Bool) {
        if on, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoIdleSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Timelapse recording in progress" as CFString,
                &sleepAssertion
            )
        } else if !on, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    // MARK: Writer helpers (videoQueue)

    private func makeWriter(_ cfg: RecordingSettings, width: Int, height: Int) -> Bool {
        do {
            try? FileManager.default.removeItem(at: cfg.url)
            let w = try AVAssetWriter(outputURL: cfg.url, fileType: .mov)
            // Write the file in 10 s fragments so its size grows while recording.
            w.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

            let bitrate = Int(Double(width * height * cfg.fps) * cfg.quality.bitsPerPixel)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: cfg.codec.avType,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate]
            ])
            input.expectsMediaDataInRealTime = true

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            guard w.canAdd(input) else { return false }
            w.add(input)
            guard w.startWriting() else { return false }
            w.startSession(atSourceTime: .zero)

            writer = w
            writerInput = input
            self.adaptor = adaptor
            return true
        } catch {
            return false
        }
    }

    /// The clock video uses ProRes 4444 so it keeps a transparent background.
    private func makeClockFile(url: URL, width: Int, height: Int) -> ClockFile? {
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        guard w.canAdd(input) else { return nil }
        w.add(input)
        guard w.startWriting() else { return nil }
        w.startSession(atSourceTime: .zero)
        return ClockFile(url: url, writer: w, input: input, adaptor: adaptor)
    }

    /// Returns a copy of `pixels` brightened by `exposureEV`. Runs on `videoQueue`.
    private func applyExposure(_ pixels: CVPixelBuffer, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool, let filter = CIFilter(name: "CIExposureAdjust") else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output else { return nil }
        filter.setValue(CIImage(cvPixelBuffer: pixels), forKey: kCIInputImageKey)
        filter.setValue(exposureEV, forKey: kCIInputEVKey)
        guard let image = filter.outputImage else { return nil }
        ciContext.render(image, to: output)
        return output
    }

    /// Draws `overlay` (with alpha) on top of `frame`. Runs on `videoQueue`.
    private func composite(_ overlay: CVPixelBuffer, over frame: CVPixelBuffer, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool, let filter = CIFilter(name: "CISourceOverCompositing") else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output else { return nil }
        filter.setValue(CIImage(cvPixelBuffer: overlay), forKey: kCIInputImageKey)
        filter.setValue(CIImage(cvPixelBuffer: frame), forKey: kCIInputBackgroundImageKey)
        guard let image = filter.outputImage else { return nil }
        ciContext.render(image, to: output)
        return output
    }

    /// Draws the clock as a glassy pill on a transparent frame the same size as the video.
    private func makeClockFrame(width: Int, height: Int, settings: ClockSettings, time: Date) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            attributes as CFDictionary, &buffer)
        guard let buffer else { return nil }

        // Wall mode: draw the clock upright on its own canvas, then warp it into the wall corners.
        if let quad = settings.warp {
            let tint = TimelapseEngine.tintColor(settings.tintHex)
            let full = CGRect(x: 0, y: 0, width: width, height: height)
            guard let warped = warpedClock(quad, settings: settings, width: width, height: height,
                                           tint: tint, time: time) else { return nil }
            let canvas = warped.cropped(to: full)
                .composited(over: CIImage(color: CIColor.clear).cropped(to: full))
            ciContext.render(canvas, to: buffer, bounds: full, colorSpace: CGColorSpaceCreateDeviceRGB())
            return buffer
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        // Settings are measured from the top; Core Graphics measures from the bottom.
        let centre = CGPoint(x: CGFloat(settings.x) * CGFloat(width),
                             y: (1 - CGFloat(settings.y)) * CGFloat(height))
        let tint = TimelapseEngine.tintColor(settings.tintHex)

        switch settings.style {
        case .analog:
            drawAnalogClock(in: context, centre: centre,
                            diameter: CGFloat(height) * ClockStyle.analogDiameter,
                            tint: tint, time: time)
        case .digital:
            drawDigitalClock(in: context, centre: centre, frameHeight: height, tint: tint, time: time)
        }
        return buffer
    }

    /// The clock drawn upright on its own canvas, then perspective-warped onto `quad` in a frame of width × height.
    private func warpedClock(_ quad: ClockQuad, settings: ClockSettings, width: Int, height: Int,
                             tint: NSColor, time: Date) -> CIImage? {
        let canvasHeight = max(64, Int(CGFloat(height) * 0.4))
        let canvasWidth = Int(CGFloat(canvasHeight) * settings.style.canvasAspect)
        guard let canvas = CGContext(
            data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        canvas.clear(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

        let centre = CGPoint(x: CGFloat(canvasWidth) / 2, y: CGFloat(canvasHeight) / 2)
        switch settings.style {
        case .analog:
            drawAnalogClock(in: canvas, centre: centre, diameter: CGFloat(canvasHeight) * 0.9, tint: tint, time: time)
        case .digital:
            // The digital pill is about 2 × its font size tall; this makes it ~90% of the canvas height.
            drawDigitalClock(in: canvas, centre: centre, frameHeight: canvasHeight * 9, tint: tint, time: time)
        }
        guard let upright = canvas.makeImage(), let filter = CIFilter(name: "CIPerspectiveTransform") else { return nil }

        // Quad points use a top-left origin; Core Image uses bottom-left.
        func vector(_ p: CGPoint) -> CIVector {
            CIVector(x: p.x * CGFloat(width), y: (1 - p.y) * CGFloat(height))
        }
        filter.setValue(CIImage(cgImage: upright), forKey: kCIInputImageKey)
        filter.setValue(vector(quad.points[0]), forKey: "inputTopLeft")
        filter.setValue(vector(quad.points[1]), forKey: "inputTopRight")
        filter.setValue(vector(quad.points[2]), forKey: "inputBottomRight")
        filter.setValue(vector(quad.points[3]), forKey: "inputBottomLeft")
        return filter.outputImage
    }

    /// Glassy round clock face with ticks and hour, minute and second hands.
    private func drawAnalogClock(in context: CGContext, centre: CGPoint, diameter: CGFloat, tint: NSColor, time: Date) {
        let radius = diameter / 2
        let face = CGRect(x: centre.x - radius, y: centre.y - radius, width: diameter, height: diameter)

        // Soft shadow under the face.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -diameter * 0.02), blur: diameter * 0.08,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setFillColor(tint.withAlphaComponent(0.25).cgColor)
        context.fillEllipse(in: face)
        context.restoreGState()

        // Rim.
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(max(1, diameter * 0.02))
        context.strokeEllipse(in: face.insetBy(dx: diameter * 0.01, dy: diameter * 0.01))

        // Ticks: long every 5 minutes, short in between.
        context.setLineCap(.round)
        for i in 0..<60 {
            let major = i % 5 == 0
            let angle = Double(i) * 6 * .pi / 180
            let outer = radius * 0.88
            let inner = radius * (major ? 0.72 : 0.8)
            context.setStrokeColor(NSColor.white.withAlphaComponent(major ? 0.9 : 0.4).cgColor)
            context.setLineWidth(max(1, diameter * (major ? 0.022 : 0.01)))
            context.move(to: point(centre, angle, inner))
            context.addLine(to: point(centre, angle, outer))
            context.strokePath()
        }

        // Hands, each with a small shadow.
        let angles = clockHandAngles(for: time)
        let hands: [(degrees: Double, length: CGFloat, width: CGFloat, color: NSColor, tail: CGFloat)] = [
            (angles.hour, radius * 0.5, diameter * 0.045, .white, 0),
            (angles.minute, radius * 0.72, diameter * 0.03, .white, 0),
            (angles.second, radius * 0.8, diameter * 0.012, .systemOrange, radius * 0.15)
        ]
        for hand in hands {
            let angle = hand.degrees * .pi / 180
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -hand.width * 0.3), blur: hand.width,
                              color: NSColor.black.withAlphaComponent(0.4).cgColor)
            context.setStrokeColor(hand.color.cgColor)
            context.setLineWidth(max(1, hand.width))
            context.move(to: point(centre, angle + .pi, hand.tail))
            context.addLine(to: point(centre, angle, hand.length))
            context.strokePath()
            context.restoreGState()
        }

        // Centre cap.
        let cap = diameter * 0.07
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: centre.x - cap / 2, y: centre.y - cap / 2, width: cap, height: cap))
        let dot = diameter * 0.035
        context.setFillColor(NSColor.systemOrange.cgColor)
        context.fillEllipse(in: CGRect(x: centre.x - dot / 2, y: centre.y - dot / 2, width: dot, height: dot))
    }

    /// A point `distance` from `centre` at `angle` radians clockwise from 12 (Core Graphics y-up).
    private func point(_ centre: CGPoint, _ angle: Double, _ distance: CGFloat) -> CGPoint {
        CGPoint(x: centre.x + CGFloat(sin(angle)) * distance,
                y: centre.y + CGFloat(cos(angle)) * distance)
    }

    /// Glassy pill with the time as text.
    private func drawDigitalClock(in context: CGContext, centre: CGPoint, frameHeight height: Int, tint: NSColor, time: Date) {
        let fontSize = CGFloat(height) * 0.05
        let text = NSAttributedString(
            string: time.formatted(.dateTime.hour().minute().second()),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        let textSize = text.size()
        let padX = fontSize * 0.8
        let padY = fontSize * 0.4
        let pillWidth = textSize.width + padX * 2
        let pillHeight = textSize.height + padY * 2

        let rect = CGRect(x: centre.x - pillWidth / 2, y: centre.y - pillHeight / 2,
                          width: pillWidth, height: pillHeight)
        let path = CGPath(roundedRect: rect, cornerWidth: pillHeight / 2, cornerHeight: pillHeight / 2, transform: nil)

        context.setFillColor(tint.withAlphaComponent(0.22).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(tint.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(max(1, fontSize * 0.05))
        context.addPath(path)
        context.strokePath()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: CGPoint(x: rect.minX + padX, y: rect.minY + padY))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Parses "#RRGGBB" into an sRGB colour; falls back to white.
    static func tintColor(_ hex: String) -> NSColor {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return .white }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255,
                       alpha: 1)
    }

    private func makeThumbnail(_ pixels: CVPixelBuffer) -> NSImage? {
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Frame capture

extension TimelapseEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // A pending "detect wall" request uses the next camera frame, recording or not.
        if let callback = wallDetection, let frame = CMSampleBufferGetImageBuffer(sampleBuffer) {
            wallDetection = nil
            let walls = findWallShapes(in: frame)
            DispatchQueue.main.async { callback(walls) }
        }

        // Live analysis for the preview and recording, throttled to keep the CPU free.
        if let frame = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let now = CFAbsoluteTimeGetCurrent()
            if clock.enabled, clock.occlude, now - lastMaskTime >= 1.0 / 15 {
                lastMaskTime = now
                updatePersonMask(from: frame)
            }
            if surfaceScanning, now - lastSurfaceScan >= 0.33 {
                lastSurfaceScan = now
                let found = surfaceTracker.update(with: findWallShapes(in: frame))
                DispatchQueue.main.async { if self.surfaceScanningOnMain { self.surfaces = found } }
            }
        }

        guard let cfg = config, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)

        if pendingStart {
            pendingStart = false
            let ok = makeWriter(cfg, width: width, height: height)
            if !ok {
                config = nil
                DispatchQueue.main.async {
                    self.errorMessage = "Couldn't start the recording file."
                    self.stopRecording()
                }
                return
            }
            // The clock file is optional; if it fails, the main recording still goes ahead.
            if let clockURL = cfg.clockURL {
                clockFile = makeClockFile(url: clockURL, width: width, height: height)
            }
        }

        guard !paused,
              let writer, writer.status == .writing,
              let writerInput, let adaptor else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastCapture, now - last < cfg.interval { return }
        guard writerInput.isReadyForMoreMediaData else { return }

        let pts = CMTime(value: frameIndex, timescale: CMTimeScale(cfg.fps))

        // Clock layer for this frame, drawn at the moment of capture.
        let wantsClock = clockFile != nil || (clock.enabled && clock.burn)
        var clockBuffer = wantsClock
            ? makeClockFrame(width: width, height: height, settings: clock, time: Date())
            : nil
        // Cut people out, so the clock sits behind them in the clock file and the burn-in.
        if clock.occlude, let clockFrame = clockBuffer, let mask = latestPersonMask,
           let masked = cutOutPeople(from: clockFrame, mask: mask) {
            clockBuffer = masked
        }

        // Brightness, then optional clock burn-in, applied to a copy of the frame.
        var frame = pixels
        if exposureEV != 0, let adjusted = applyExposure(pixels, pool: adaptor.pixelBufferPool) {
            frame = adjusted
        }
        if clock.enabled, clock.burn, let clockBuffer,
           let composed = composite(clockBuffer, over: frame, pool: adaptor.pixelBufferPool) {
            frame = composed
        }

        guard adaptor.append(frame, withPresentationTime: pts) else {
            let message = writer.error?.localizedDescription ?? "Recording failed."
            config = nil
            DispatchQueue.main.async {
                self.errorMessage = message
                self.stopRecording()
            }
            return
        }

        if let clockFile, clockFile.input.isReadyForMoreMediaData, let clockBuffer {
            clockFile.adaptor.append(clockBuffer, withPresentationTime: pts)
        }

        frameIndex += 1
        lastCapture = now
        let count = Int(frameIndex)

        // Thumbnail refresh is throttled, since regular video captures every frame.
        var thumb: NSImage?
        if lastThumbnail == nil || now - lastThumbnail! >= 0.5 {
            thumb = makeThumbnail(frame)
            lastThumbnail = now
        }
        let fps = cfg.fps
        DispatchQueue.main.async {
            self.frames = count
            self.videoSeconds = Double(count) / Double(fps)
            if let thumb { self.thumbnail = thumb }
        }
    }
}



