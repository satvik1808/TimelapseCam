import SwiftUI
import AppKit

// Liquid Glass on macOS 26+, with a material fallback on older systems.
extension View {
    @ViewBuilder
    func glass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    /// Glass surface, tinted when `tint` is set. Not "interactive" glass: the button style
    /// handles presses itself, so the glass never competes for clicks.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, tint: Color?) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = tint.map { Glass.regular.tint($0) } ?? Glass.regular
            self.glassEffect(glass, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay {
                    if let tint { shape.fill(tint.opacity(0.35)) }
                }
        }
    }

    func glassPrimaryButton() -> some View {
        buttonStyle(TactileButtonStyle(tint: .red))
    }

    func glassSecondaryButton() -> some View {
        buttonStyle(TactileButtonStyle())
    }
}

/// A button that sinks in, darkens and loses its shadow while pressed, with a haptic tap on press.
struct TactileButtonStyle: ButtonStyle {
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        TactileButtonBody(configuration: configuration, tint: tint)
    }
}

private struct TactileButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let pressed = configuration.isPressed

        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 32)
            .foregroundStyle(tint == nil ? Color.primary : Color.white)
            .glassSurface(in: shape, tint: tint)
            .overlay(shape.fill(Color.black.opacity(pressed ? 0.14 : 0)))        // pressed-in shade
            .overlay(shape.stroke(.white.opacity(pressed ? 0.7 : 0.25), lineWidth: 1))
            .shadow(color: .black.opacity(pressed ? 0.05 : 0.25),
                    radius: pressed ? 1 : 8, y: pressed ? 0 : 4)
            .scaleEffect(pressed ? 0.95 : 1)
            // Applied after the scale, so the whole button stays clickable even while it's squished,
            // and clicks on the glass (not just the text) count.
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: pressed)
            .onChange(of: pressed) { _, isDown in
                if isDown { Haptics.tap() }
            }
    }
}

extension Color {
    /// Creates a colour from "#RRGGBB".
    init(hex: String) {
        self.init(nsColor: TimelapseEngine.tintColor(hex))
    }

    /// The colour as "#RRGGBB", for storing in settings.
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

enum Haptics {
    /// A light trackpad tap, when the Mac has haptic feedback.
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
