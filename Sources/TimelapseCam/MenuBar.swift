import AppKit
import AVFoundation
import Combine

/// Owns the menu bar item. Hovering over it shows a small live preview, and clicking it opens a menu
/// with the live feed toggle, a way back to the main window, and Quit.
final class MenuBarController: NSObject, NSMenuDelegate {
    /// Opens the main window when it has been closed. Set from the SwiftUI view that owns the window.
    static var openMainWindow: (() -> Void)?

    private let engine: TimelapseEngine
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let preview: HoverPreviewView
    private let feedItem = NSMenuItem(title: "", action: #selector(toggleFeed), keyEquivalent: "")
    private var closeWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init(engine: TimelapseEngine) {
        self.engine = engine
        preview = HoverPreviewView(session: engine.session)
        super.init()

        // Menu shown on click.
        let menu = NSMenu()
        menu.delegate = self
        feedItem.target = self
        menu.addItem(feedItem)
        let show = NSMenuItem(title: "Show Timelapse Cam", action: #selector(showMainWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Timelapse Cam", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        // Hover over the icon to see the preview.
        if let button = statusItem.button {
            button.addTrackingArea(NSTrackingArea(rect: .zero,
                                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: self,
                                                  userInfo: nil))
        }
        popover.behavior = .semitransient
        popover.animates = true
        let controller = NSViewController()
        controller.view = preview
        popover.contentViewController = controller
        popover.contentSize = preview.frame.size
        preview.onEnter = { [weak self] in self?.cancelClose() }
        preview.onExit = { [weak self] in self?.scheduleClose() }

        // Keep the icon, menu and preview in step with the engine.
        engine.$liveFeedOn
            .sink { [weak self] on in
                self?.updateIcon(feedOn: on)
                self?.preview.setFeedOn(on)
                self?.refreshMenu()
            }
            .store(in: &cancellables)
        engine.$isRecording
            .sink { [weak self] _ in self?.refreshMenu() }
            .store(in: &cancellables)
    }

    // MARK: Icon and menu

    private func updateIcon(feedOn: Bool) {
        let image = NSImage(systemSymbolName: feedOn ? "video.fill" : "video.slash.fill",
                            accessibilityDescription: "Timelapse Cam")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func refreshMenu() {
        feedItem.title = engine.liveFeedOn ? "Turn Off Live Feed" : "Turn On Live Feed"
        // The feed can't change while recording, because recording needs it.
        feedItem.isEnabled = !engine.isRecording
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        cancelClose()
        popover.close()
    }

    // MARK: Hover preview

    @objc func mouseEntered(with event: NSEvent) {
        cancelClose()
        guard !popover.isShown, let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc func mouseExited(with event: NSEvent) {
        scheduleClose()
    }

    /// Closes the preview after a short pause, so moving the pointer onto it doesn't close it.
    private func scheduleClose() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.popover.close() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }

    // MARK: Actions

    @objc private func toggleFeed() {
        engine.setLiveFeed(!engine.liveFeedOn)
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "Timelapse Cam" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            Self.openMainWindow?()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// The contents of the hover popover: the live feed, or a note when the feed is off.
final class HoverPreviewView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    private let feedView: PreviewNSView
    private let offLabel = NSTextField(labelWithString: "Live feed is off")

    init(session: AVCaptureSession) {
        let mirrored = UserDefaults.standard.object(forKey: "mirror") as? Bool ?? true
        feedView = PreviewNSView(session: session, mirrored: mirrored, exposureEV: 0)
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(feedView)

        offLabel.font = .systemFont(ofSize: 13, weight: .medium)
        offLabel.textColor = .secondaryLabelColor
        offLabel.alignment = .center
        addSubview(offLabel)

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setFeedOn(_ on: Bool) {
        feedView.isHidden = !on
        offLabel.isHidden = on
    }

    override func layout() {
        super.layout()
        feedView.frame = bounds
        offLabel.frame = NSRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
