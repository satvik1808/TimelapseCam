import SwiftUI
import AVFoundation
import AppKit

@main
struct TimelapseCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single window, so the menu bar item can reopen it.
        Window("Timelapse Cam", id: "main") {
            ContentView()
        }
        .defaultSize(width: 580, height: 560)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The camera starts with the app, so the menu bar preview works even with the window closed.
        TimelapseEngine.shared.start()
        menuBar = MenuBarController(engine: TimelapseEngine.shared)
    }

    /// Keep running in the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct ContentView: View {
    @ObservedObject private var engine = TimelapseEngine.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showSettings = false
    @Environment(\.controlActiveState) private var windowState
    @AppStorage("animatedBackground") private var animatedBackground = true
    @StateObject private var windowFitter = WindowFitter()
    @State private var animateNextFit = false
    @State private var showThumbnail = false
    @State private var thumbnailFade: DispatchWorkItem?

    // Shared with SettingsView through the same keys.
    @AppStorage("interval") private var interval: Double = 5
    @AppStorage("regularVideo") private var regularVideo = false
    @AppStorage("fps") private var fps: Int = 30
    @AppStorage("codec") private var codecRaw = VideoCodec.hevc.rawValue
    @AppStorage("quality") private var qualityRaw = VideoQuality.medium.rawValue
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("stopAfterMinutes") private var stopAfterMinutes = 0
    @AppStorage("folderPath") private var folderPath = NSHomeDirectory() + "/Movies/Timelapses"
    @AppStorage("mirror") private var mirror = true
    @AppStorage("exposureBias") private var exposureBias: Double = 0
    @AppStorage("clockEnabled") private var clockSetting = false
    /// Off whenever the clock feature is switched off (see Features.clock).
    private var clockEnabled: Bool { Features.clock && clockSetting }
    @AppStorage("clockX") private var clockX = 0.85
    @AppStorage("clockY") private var clockY = 0.85
    @AppStorage("burnClock") private var burnClock = false
    @AppStorage("clockTint") private var clockTint = "#FFFFFF"
    @AppStorage("clockStyle") private var clockStyleRaw = ClockStyle.digital.rawValue
    @AppStorage("clockWarp") private var clockWarp = false
    @AppStorage("clockQuad") private var clockQuad = ""
    @AppStorage("clockWallScale") private var clockWallScale = 1.0
    @AppStorage("clockOcclude") private var clockOcclude = false
    @AppStorage("surfaceMode") private var surfaceMode = false
    @AppStorage("lockedPlane") private var lockedPlane = ""

    var body: some View {
        VStack(spacing: 12) {
            previewArea
            statsRow
            if engine.isRecording && !regularVideo && stopAfterMinutes > 0 {
                progressBar
            }
            recordControls
            footer
            if showSettings {
                SettingsView(engine: engine, onClose: toggleSettings)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(14)
        .frame(minWidth: WindowFitter.minWidth, idealWidth: 580, maxWidth: WindowFitter.maxWidth)
        .fixedSize(horizontal: false, vertical: true)
        // Measures the content's natural height for the current width; the window height follows it.
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ContentSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(ContentSizeKey.self) { size in
            windowFitter.contentSizeChanged(size, animated: animateNextFit)
            animateNextFit = false
        }
        // Pin content to the top, so while the window grows the pane is revealed instead of everything shifting.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { backdrop.ignoresSafeArea() }
        .background(WindowAccessor { window in
            windowFitter.attach(window)
        })
        .onChange(of: engine.frames) { _, count in
            if count > 0 { flashThumbnail() }
        }
        .onChange(of: showsSurfaces) { _, on in
            engine.setSurfaceScanning(on)
        }
        .onChange(of: clockSnapshot) { _, newValue in
            engine.updateClock(newValue)
        }
        .onAppear {
            engine.updateClock(clockSnapshot)
            engine.setSurfaceScanning(showsSurfaces)
            engine.applyCamera(CameraSettings.fromStorage())
            engine.start()
            MenuBarController.openMainWindow = { openWindow(id: "main") }
        }
    }

    /// Switches the live feed on or off. Disabled while recording, because recording needs the feed.
    private var liveFeedButton: some View {
        Button {
            engine.setLiveFeed(!engine.liveFeedOn)
        } label: {
            Label(engine.liveFeedOn ? "Live" : "Off",
                  systemImage: engine.liveFeedOn ? "eye.fill" : "eye.slash.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.black.opacity(0.55), in: Capsule())
        .disabled(engine.isRecording)
        .padding(8)
        .help(engine.liveFeedOn ? "Turn off the live feed" : "Turn on the live feed")
    }

    /// Surfaces are scanned and highlighted only while placing the clock on a wall, not while recording.
    private var showsSurfaces: Bool {
        clockEnabled && clockWarp && surfaceMode && lockedPlane.isEmpty && !engine.isRecording
    }

    private var clockStyle: ClockStyle { ClockStyle(rawValue: clockStyleRaw) ?? .digital }

    private var clockSnapshot: ClockSettings {
        let wallQuad = ClockQuad(storage: clockQuad) ?? .upright(centerX: clockX, centerY: clockY, style: clockStyle)
        return ClockSettings(enabled: clockEnabled, x: clockX, y: clockY, burn: burnClock, tintHex: clockTint,
                             style: clockStyle, warp: clockWarp ? wallQuad.scaled(clockWallScale) : nil,
                             occlude: clockOcclude)
    }

    // MARK: Backdrop

    /// Colour blobs that drift and slowly cycle through hues, so the glass has something to refract.
    /// This is most of the app's own CPU use, so it redraws only about 5 times a second
    /// (the blobs move slowly and are heavily blurred) and pauses when the window isn't in front.
    private var backdrop: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 5, paused: !animatedBackground || windowState != .key)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                blob(hue: wrap(t / 90), x: sin(t / 23) * 220, y: cos(t / 29) * 170, size: 440, blur: 90)
                blob(hue: wrap(t / 90 + 0.33), x: cos(t / 31) * 230, y: sin(t / 19) * 190, size: 400, blur: 90)
                blob(hue: wrap(t / 90 + 0.66), x: sin(t / 37 + 1) * 200, y: cos(t / 27 + 2) * 180, size: 320, blur: 80)
            }
        }
    }

    private func blob(hue: Double, x: Double, y: Double, size: CGFloat, blur: CGFloat) -> some View {
        Circle()
            .fill(Color(hue: hue, saturation: 0.6, brightness: 0.9).opacity(0.4))
            .frame(width: size, height: size)
            .blur(radius: blur)
            .offset(x: x, y: y)
    }

    private func wrap(_ value: Double) -> Double {
        value - floor(value)
    }

    // MARK: Preview

    private var previewArea: some View {
        ZStack {
            Color.black
            if engine.permissionDenied {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash.fill").font(.largeTitle)
                    Text("Camera access is off").font(.headline)
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .foregroundStyle(.white)
            } else if engine.liveFeedOn {
                CameraPreview(session: engine.session, mirrored: mirror, exposureEV: Float(exposureBias))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash.fill").font(.title)
                    Text("Live feed is off").font(.headline)
                }
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            liveFeedButton
        }
        .overlay {
            if clockEnabled {
                ClockOverlay(x: $clockX, y: $clockY, quadStorage: $clockQuad,
                             tint: Color(hex: clockTint), style: clockStyle,
                             warp: clockWarp, wallScale: clockWallScale,
                             editable: !engine.isRecording,
                             surfaces: engine.surfaces,
                             surfaceMode: clockEnabled && clockWarp && surfaceMode,
                             occlusionMask: clockOcclude ? engine.personMask : nil,
                             planeStorage: $lockedPlane)
            }
        }
        .overlay(alignment: .topLeading) {
            if engine.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.isPaused ? Color.yellow : Color.red)
                        .frame(width: 10, height: 10)
                    Text(engine.isPaused ? "PAUSED" : "REC")
                        .font(.caption.bold())
                        .monospacedDigit()
                    Text(formatDuration(engine.elapsed))
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glass(in: Capsule())
                .padding(12)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showThumbnail, let thumb = engine.thumbnail {
                VStack(alignment: .trailing, spacing: 4) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 160, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.7), lineWidth: 1))
                    Text("Last frame")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
                .padding(12)
                .allowsHitTesting(false)   // never blocks dragging the clock underneath
                .transition(.opacity)
            }
        }
    }

    // MARK: Stats

    private var statsRow: some View {
        HStack(spacing: 8) {
            StatTile(title: "Elapsed", value: formatDuration(engine.elapsed))
            StatTile(title: "File size",
                     value: ByteCountFormatter.string(fromByteCount: engine.fileSize, countStyle: .file))
            StatTile(title: "Frames", value: "\(engine.frames)")
            StatTile(title: "Video length", value: formatDuration(engine.videoSeconds))
        }
    }

    // MARK: Controls

    private var recordControls: some View {
        HStack(spacing: 12) {
            ModeSwitch(isVideo: $regularVideo, disabled: engine.isRecording)

            Button {
                if engine.isRecording {
                    engine.stopRecording()
                } else {
                    beginRecording()
                }
            } label: {
                Label(engine.isRecording ? "Stop" : "Record",
                      systemImage: engine.isRecording ? "stop.fill" : "record.circle")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .glassPrimaryButton()
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!engine.isPreviewing)

            Button {
                engine.togglePause()
            } label: {
                Label(engine.isPaused ? "Resume" : "Pause",
                      systemImage: engine.isPaused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .glassSecondaryButton()
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!engine.isRecording)
        }
        .controlSize(.regular)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let error = engine.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let saved = engine.savedURL {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Saved \(saved.lastPathComponent)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Open") { NSWorkspace.shared.open(saved) }
                    .glassSecondaryButton()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                    .glassSecondaryButton()
            } else {
                Text(engine.isPreviewing ? "Ready. ⌘R to record, ⌘P to pause."
                     : engine.liveFeedOn ? "Starting camera…"
                     : "Live feed is off. Turn it on to record.")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                toggleSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .glassSecondaryButton()
            .keyboardShortcut(",", modifiers: .command)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Recording start, progress and countdown

    /// Starts recording with the current settings.
    private func beginRecording() {
        engine.startRecording(folder: URL(fileURLWithPath: folderPath),
                              interval: regularVideo ? 0 : interval,
                              fps: fps,
                              codec: VideoCodec(rawValue: codecRaw) ?? .hevc,
                              quality: VideoQuality(rawValue: qualityRaw) ?? .medium,
                              keepAwake: keepAwake,
                              stopAfter: TimeInterval(stopAfterMinutes * 60))
    }

    /// Progress toward the automatic stop time, shown during timelapse recording.
    private var progressBar: some View {
        let total = Double(stopAfterMinutes * 60)
        let fraction = min(engine.elapsed / total, 1)
        let remaining = max(total - engine.elapsed, 0)
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geo.size.width * fraction, 0))
                        .animation(.linear(duration: 0.25), value: fraction)
                }
            }
            .frame(height: 8)
            HStack {
                Text("\(Int(fraction * 100))% of timelapse")
                Spacer()
                Text("\(formatDuration(remaining)) left")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Helpers

    /// Shows the last-frame thumbnail, then fades it out if no new frame arrives for 2.5 s.
    private func flashThumbnail() {
        withAnimation(.easeOut(duration: 0.2)) { showThumbnail = true }
        thumbnailFade?.cancel()
        let fade = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.8)) { showThumbnail = false }
        }
        thumbnailFade = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: fade)
    }

    private func toggleSettings() {
        // The content height changes, and the window animates to it via onPreferenceChange.
        animateNextFit = true
        withAnimation(.easeInOut(duration: 0.22)) {
            showSettings.toggle()
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .glass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The main content's natural size, used to size the window.
struct ContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        // Views that don't report a size contribute the zero default; keep the real one.
        let next = nextValue()
        if next.height > 0 { value = next }
    }
}

/// Hands back the NSWindow hosting this view, once it's attached.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Hosts the live AVCaptureVideoPreviewLayer.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool
    let exposureEV: Float

    func makeNSView(context: Context) -> PreviewNSView {
        PreviewNSView(session: session, mirrored: mirrored, exposureEV: exposureEV)
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.setMirrored(mirrored)
        nsView.setExposure(exposureEV)
    }
}

final class PreviewNSView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private var mirrored: Bool

    init(session: AVCaptureSession, mirrored: Bool, exposureEV: Float) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        self.mirrored = mirrored
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
        setExposure(exposureEV)
    }

    /// Brightens or darkens the live preview to match the saved frames.
    func setExposure(_ ev: Float) {
        if ev == 0 {
            previewLayer.filters = nil
        } else if let filter = CIFilter(name: "CIExposureAdjust") {
            filter.setValue(ev, forKey: kCIInputEVKey)
            previewLayer.filters = [filter]
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        setMirrored(mirrored)
    }

    /// Flips the live preview horizontally to match the recording.
    func setMirrored(_ on: Bool) {
        mirrored = on
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = on
    }
}

