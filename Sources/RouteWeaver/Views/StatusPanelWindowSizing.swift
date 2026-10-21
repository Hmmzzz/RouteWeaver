import AppKit
import SwiftUI

/// Keeps MenuBarExtra's hosting window fitted to the natural-height panel.
/// SwiftUI may retain the window's previous height when status text or actions
/// disappear; a fixed-size root is then centered in that stale height.
/// Attach only as the background of StatusPopover, after its fixedSize modifier.
struct StatusPanelWindowSizing: NSViewRepresentable {
    var onVisibilityChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> StatusPanelSizingView {
        let view = StatusPanelSizingView()
        view.onVisibilityChange = onVisibilityChange
        return view
    }

    func updateNSView(_ view: StatusPanelSizingView, context: Context) {
        view.onVisibilityChange = onVisibilityChange
        view.scheduleFit()
        view.scheduleVisibilityRead()
    }

    static func dismantleNSView(_ view: StatusPanelSizingView, coordinator: ()) {
        view.stopObservingVisibility()
    }
}

/// Owns no window: it can only resize the window that contains this probe.
/// Resizing is event-driven and coalesced onto the next main-queue layout turn.
final class StatusPanelSizingView: NSView {
    private var fitScheduled = false
    private var applyingSize = false
    var onVisibilityChange: (Bool) -> Void = { _ in }
    private weak var observedWindow: NSWindow?
    private var visibilityObservers: [NSObjectProtocol] = []
    private var attachmentGeneration = 0
    private var scheduledVisibilityGeneration: Int?
    private var lastReportedVisibility: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeVisibility(of: window)
        scheduleFit()
    }

    deinit {
        for observer in visibilityObservers { NotificationCenter.default.removeObserver(observer) }
    }

    private func observeVisibility(of nextWindow: NSWindow?) {
        if observedWindow === nextWindow {
            scheduleVisibilityRead()
            return
        }
        attachmentGeneration += 1
        removeVisibilityObservers()
        observedWindow = nextWindow
        if let nextWindow {
            let generation = attachmentGeneration
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.willCloseNotification
            ]
            for name in names {
                visibilityObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nextWindow, queue: .main
                ) { [weak self] _ in
                    guard let self, self.attachmentGeneration == generation else { return }
                    self.scheduleVisibilityRead()
                })
            }
        }
        scheduleVisibilityRead()
    }

    private func removeVisibilityObservers() {
        for observer in visibilityObservers { NotificationCenter.default.removeObserver(observer) }
        visibilityObservers.removeAll()
        scheduledVisibilityGeneration = nil
    }

    func stopObservingVisibility() {
        attachmentGeneration += 1
        removeVisibilityObservers()
        observedWindow = nil
        scheduleVisibilityRead()
    }

    func scheduleVisibilityRead() {
        let generation = attachmentGeneration
        guard scheduledVisibilityGeneration != generation else { return }
        scheduledVisibilityGeneration = generation
        // Retain the probe through this one queued turn so dismantling still
        // reports false. A new attachment invalidates this generation first.
        DispatchQueue.main.async { [self] in
            guard attachmentGeneration == generation else { return }
            scheduledVisibilityGeneration = nil
            let visible = observedWindow?.isVisible == true
            guard lastReportedVisibility != visible else { return }
            lastReportedVisibility = visible
            onVisibilityChange(visible)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleFit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func scheduleFit() {
        guard !fitScheduled, !applyingSize else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitScheduled = false
            self.fitWindow()
        }
    }

    private func fitWindow() {
        guard !applyingSize, let window, let contentView = window.contentView,
              bounds.width > 1, bounds.height > 1 else { return }
        let before = contentView.bounds.size
        let target = NSSize(width: before.width, height: ceil(bounds.height))
        guard target.width > 1, abs(before.height - target.height) > 0.5 else { return }

        applyingSize = true
        let oldFrame = window.frame
        let measuredFrame = convert(bounds, to: contentView)
        // Update both sides of the AppKit/SwiftUI hosting boundary, so a later
        // hosting pass does not restore the stale preferred content height.
        window.contentViewController?.preferredContentSize = target
        window.setContentSize(target)
        var fittedFrame = window.frame
        fittedFrame.origin.x = oldFrame.minX
        fittedFrame.origin.y = oldFrame.maxY - fittedFrame.height
        window.setFrame(fittedFrame, display: window.isVisible)
        applyingSize = false

        writeDiagnostic(before: before, target: target,
                        after: contentView.bounds.size, measuredFrame: measuredFrame,
                        window: window)
    }

    private func writeDiagnostic(before: NSSize, target: NSSize, after: NSSize,
                                 measuredFrame: NSRect, window: NSWindow) {
        guard let path = ProcessInfo.processInfo.environment["ROUTEWEAVER_PANEL_LAYOUT_LOG"],
              !path.isEmpty else { return }
        let sample: [String: Any] = [
            "windowClass": String(describing: type(of: window)),
            "before": [before.width, before.height],
            "naturalContent": [bounds.width, bounds.height],
            "contentFrameBefore": [measuredFrame.minX, measuredFrame.minY,
                                   measuredFrame.width, measuredFrame.height],
            "target": [target.width, target.height],
            "after": [after.width, after.height],
            "visible": window.isVisible
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: sample, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
