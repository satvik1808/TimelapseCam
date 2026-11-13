import SwiftUI
import AppKit

/// Everything the user can configure, shown in a sheet from the gear button.
struct SettingsView: View {
    @ObservedObject var engine: TimelapseEngine
    var onClose: () -> Void

    @AppStorage("resolution") private var resolutionRaw = Resolution.hd1080.rawValue
    @AppStorage("codec") private var codecRaw = VideoCodec.hevc.rawValue
    @AppStorage("quality") private var qualityRaw = VideoQuality.medium.rawValue
    @AppStorage("fps") private var fps: Int = 30
    @AppStorage("mirror") private var mirror = true
    @AppStorage("exposureBias") private var exposureBias: Double = 0
    @AppStorage("lockExposure") private var lockExposure = false
    @AppStorage("lockWhiteBalance") private var lockWhiteBalance = false
    @AppStorage("clockEnabled") private var clockEnabled = false
    @AppStorage("burnClock") private var burnClock = false
    @AppStorage("clockX") private var clockX = 0.85
    @AppStorage("clockY") private var clockY = 0.85
    @AppStorage("clockTint") private var clockTint = "#FFFFFF"
    @AppStorage("clockStyle") private var clockStyleRaw = ClockStyle.digital.rawValue
    @AppStorage("clockWarp") private var clockWarp = false
    @AppStorage("clockQuad") private var clockQuad = ""
    @AppStorage("clockWallScale") private var clockWallScale = 1.0
    @AppStorage("clockOcclude") private var clockOcclude = false
    @AppStorage("surfaceMode") private var surfaceMode = false
    @AppStorage("lockedPlane") private var lockedPlane = ""
    @State private var wallMessage: String?
    @AppStorage("interval") private var interval: Double = 5
    @AppStorage("regularVideo") private var regularVideo = false
    @AppStorage("stopAfterMinutes") private var stopAfterMinutes = 0
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("animatedBackground") private var animatedBackground = true
    @AppStorage("folderPath") private var folderPath = NSHomeDirectory() + "/Movies/Timelapses"

    private let intervalOptions: [(label: String, seconds: Double)] = [
        ("1 second", 1), ("2 seconds", 2), ("5 seconds", 5), ("10 seconds", 10),
        ("30 seconds", 30), ("1 minute", 60), ("5 minutes", 300)
    ]

    /// Re-read from storage each time, so changes are pushed to the camera.
    private var cameraSnapshot: CameraSettings { CameraSettings.fromStorage() }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Camera") {
                    Picker("Camera", selection: Binding(
                        get: { engine.selectedCameraID },
                        set: { engine.selectCamera($0) }
                    )) {
                        ForEach(engine.cameras, id: \.uniqueID) { camera in
                            Text(camera.localizedName).tag(camera.uniqueID)
                        }
                    }
                    Toggle("Mirror image", isOn: $mirror)
                }
                .disabled(engine.isRecording)

                Section("Video") {
                    Picker("Resolution", selection: $resolutionRaw) {
                        ForEach(Resolution.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Codec", selection: $codecRaw) {
                        ForEach(VideoCodec.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Quality", selection: $qualityRaw) {
                        ForEach(VideoQuality.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Playback frame rate", selection: $fps) {
                        ForEach([24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                }
                .disabled(engine.isRecording)

                if Features.clock {
                    Section("Clock") {
                        Toggle("Show clock and save it as a separate video", isOn: $clockEnabled)
                        Picker("Clock style", selection: $clockStyleRaw) {
                            ForEach(ClockStyle.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        Toggle("Fit clock to a wall (perspective)", isOn: $clockWarp)
                        if clockWarp {
                            Toggle("Pick a plane", isOn: $surfaceMode)
                            if surfaceMode {
                                if lockedPlane.isEmpty {
                                    Text("Click a highlighted surface on the preview to use its plane.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    HStack {
                                        Text("Plane locked. Click or drag anywhere on the preview; the clock keeps this plane's perspective.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Button("Choose a different plane") { lockedPlane = "" }
                                            .glassSecondaryButton()
                                    }
                                }
                            }
                            HStack {
                                Button("Detect wall shape", action: detectWall)
                                    .glassSecondaryButton()
                                Button("Reset shape") {
                                    clockQuad = ""
                                    clockWallScale = 1
                                    wallMessage = nil
                                }
                                .glassSecondaryButton()
                            }
                            LabeledContent("Size on wall") {
                                HStack {
                                    Slider(value: $clockWallScale, in: 0.3...2.5)
                                        .frame(width: 180)
                                    Text("\(Int((clockWallScale * 100).rounded()))%")
                                        .monospacedDigit()
                                        .frame(width: 48, alignment: .trailing)
                                }
                            }
                            Text(wallMessage ?? "Drag the four corners on the preview to line the clock up with the wall, or detect a flat shape such as a poster, frame or door.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("Keep clock behind people", isOn: $clockOcclude)
                        Toggle("Also burn clock into the main video", isOn: $burnClock)
                            .disabled(!clockEnabled)
                        ColorPicker("Clock glass colour", selection: Binding(
                            get: { Color(hex: clockTint) },
                            set: { clockTint = $0.hexString }
                        ), supportsOpacity: false)
                        Button("Reset clock position") {
                            clockX = 0.85
                            clockY = 0.85
                        }
                        .glassSecondaryButton()
                    }
                    .disabled(engine.isRecording && !clockEnabled)
                }

                Section("Exposure") {
                    LabeledContent("Brightness") {
                        HStack {
                            Slider(value: $exposureBias, in: -3...3, step: 0.1)
                                .frame(width: 180)
                            Text(String(format: "%+.1f EV", exposureBias))
                                .monospacedDigit()
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                    Toggle("Lock exposure", isOn: $lockExposure)
                    Toggle("Lock white balance", isOn: $lockWhiteBalance)
                    Button("Reset exposure") {
                        exposureBias = 0
                        lockExposure = false
                        lockWhiteBalance = false
                    }
                    .glassSecondaryButton()
                }

                Section("Timelapse") {
                    Picker("Capture every", selection: $interval) {
                        ForEach(intervalOptions, id: \.seconds) { Text($0.label).tag($0.seconds) }
                    }
                    .disabled(regularVideo)
                    Toggle("End recording automatically", isOn: Binding(
                        get: { stopAfterMinutes > 0 },
                        set: { stopAfterMinutes = $0 ? 60 : 0 }
                    ))
                    if stopAfterMinutes > 0 {
                        Stepper(value: $stopAfterMinutes, in: 1...1440) {
                            LabeledContent("End after", value: durationText(stopAfterMinutes))
                        }
                    }
                    LabeledContent("Save to") {
                        HStack {
                            Text(folderPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Choose…", action: chooseFolder)
                                .glassSecondaryButton()
                        }
                    }
                    Toggle("Keep Mac awake while recording", isOn: $keepAwake)
                    Toggle("Animated background", isOn: $animatedBackground)
                    Text("Turning this off makes the app use almost no CPU of its own. The background also pauses whenever the window isn't in front.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(engine.isRecording)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: 380)

            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .glassSecondaryButton()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onChange(of: cameraSnapshot) { _, newValue in
            engine.applyCamera(newValue)
        }
    }

    /// "90 min" or "2 h 30 min".
    /// Finds a flat rectangle in the camera view and places the clock on it in perspective.
    /// Keeps the clock where it is and at its current size, and gives it the perspective of the
    /// nearest flat shape the camera can see (poster, frame, door, window).
    private func detectWall() {
        wallMessage = "Looking for a flat shape…"
        let style = ClockStyle(rawValue: clockStyleRaw) ?? .digital
        // The clock exactly as it's shown now.
        let shown = (ClockQuad(storage: clockQuad) ?? .upright(centerX: clockX, centerY: clockY, style: style))
            .scaled(clockWallScale)
        let centre = shown.wallCentre
        let height = shown.screenHeight()

        engine.detectWall { walls in
            guard let wall = ClockQuad.nearestWall(to: centre, in: walls),
                  let placed = ClockQuad.placed(at: centre, height: height, onWall: wall,
                                                aspect: style.canvasAspect) else {
                wallMessage = "No clear wall shape found near the clock. Drag the corners on the preview instead."
                return
            }
            // Store without the size slider applied, so the slider keeps its current value.
            clockQuad = placed.scaled(1 / clockWallScale).storage
            wallMessage = "Matched the clock to the nearest wall. Drag the corners to fine-tune."
        }
    }

    private func durationText(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: folderPath)
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }
}
