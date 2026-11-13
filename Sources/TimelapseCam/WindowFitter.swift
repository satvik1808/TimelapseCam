import AppKit
import QuartzCore

/// Keeps the window's height equal to the content's height.
/// The width is free for the user to resize; the preview scales with it and the height follows.
final class WindowFitter: ObservableObject {
    static let minWidth: CGFloat = 480
    static let maxWidth: CGFloat = 1400

    private weak var window: NSWindow?
    private var measured = CGSize.zero   // content size from the most recent layout
    private var animating = false
    private var resizeObserver: NSObjectProtocol?

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.styleMask.insert(.resizable)

        // Runs after every resize, including manual drags, so the height always matches the width.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self, !self.animating else { return }
            self.fit(animated: false)
        }
        fit(animated: false)
    }

    func contentSizeChanged(_ size: CGSize, animated: Bool) {
        measured = size
        fit(animated: animated)
    }

    /// The content height at a given width. Only the 16:9 preview changes height with width,
    /// so this is exact even before SwiftUI has laid the content out at the new width.
    private func predictedHeight(forWidth width: CGFloat) -> CGFloat {
        measured.height + (width - measured.width) * 9 / 16
    }

    /// Sizes the window to the content, keeping the top edge in place and the window on screen.
    private func fit(animated: Bool) {
        guard let window, measured.height > 0, measured.width > 0 else { return }

        let current = window.contentRect(forFrameRect: window.frame)
        let titleBar = window.frame.height - current.height

        // Widest the window can be while its full height still fits on screen.
        var widestAllowed = Self.maxWidth
        if let visible = window.screen?.visibleFrame {
            let tallestContent = visible.height - titleBar
            let widthAtScreenHeight = measured.width + (tallestContent - measured.height) * 16 / 9
            widestAllowed = max(Self.minWidth, min(Self.maxWidth, floor(widthAtScreenHeight)))
        }

        let width = min(max(current.width, Self.minWidth), widestAllowed)
        let height = predictedHeight(forWidth: width)

        // Height is locked to the content; width can be dragged between the limits.
        window.contentMinSize = NSSize(width: Self.minWidth, height: height)
        window.contentMaxSize = NSSize(width: widestAllowed, height: height)

        guard abs(current.height - height) > 0.5 || abs(current.width - width) > 0.5 else { return }

        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height)).size
        var frame = NSRect(x: window.frame.minX,
                           y: window.frame.maxY - size.height,
                           width: size.width,
                           height: size.height)
        // Slide up rather than hang off the bottom of the screen.
        if let visible = window.screen?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }

        if animated && !window.inLiveResize {
            // Non-blocking, so it runs alongside the settings pane's own transition.
            animating = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                self?.animating = false
                self?.fit(animated: false)   // settle exactly on the final size
            })
        } else {
            window.setFrame(frame, display: true)
        }
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }
}

