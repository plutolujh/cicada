import AppKit
import Combine
import SwiftUI

/// A tiny floating window that shows only the live pill (recording / listening status).
/// It stays on top, can be dragged anywhere, and lives independently of the main window
/// and the menu-bar popover.
@MainActor
final class FloatingPillWindowController: NSObject, NSWindowDelegate {
    enum State { case hidden, visible }

    private var panel: NSPanel?
    /// The view over the pill that makes it draggable.
    private var overlay: PillDragOverlay?
    private weak var model: AppModel?
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        super.init()
        // Auto-show when recording/listening starts, auto-hide when both stop.
        model.$running
            .combineLatest(model.$micState.map { $0 != .idle })
            .sink { [weak self] running, micActive in
                guard let self else { return }
                if running || micActive { self.show() } else { self.hide() }
            }
            .store(in: &cancellables)
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    /// The panel itself, for the debug commands that move it around.
    var window: NSPanel? { panel }
    /// Where the pill's buttons are, so a test can see they stay clickable.
    var buttonRegions: [CGRect] { overlay?.buttonRegions ?? [] }

    func show() {
        guard let model else { return }
        model.setFloatingPillVisible(true)
        if panel == nil {
            // Borderless: a pill on the desktop has no title bar, no close button, no traffic
            // lights. It is dragged by its own body instead (the AppKit drag in the hosting view).
            let p = FloatingPillPanel(
                contentRect: defaultFrame(),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = .floating
            p.delegate = self
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.isReleasedWhenClosed = false
            p.sharingType = .none
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            // The pill itself is the entire content; no title bar, no extra chrome. The
            // overlay on top of it is what makes the pill draggable.
            let overlay = PillDragOverlay(below: NSView())
            overlay.onBodyDoubleClick = { [weak model] in model?.toggleMainWindow?() }
            let host = FloatingPillHostingView(rootView: FloatingPillView(model: model) {
                [weak overlay] regions in
                overlay?.setButtonRegions(regions)
            })
            overlay.setContent(host)
            self.overlay = overlay
            let container = NSView(frame: .zero)
            container.addSubview(host)
            container.addSubview(overlay)
            host.translatesAutoresizingMaskIntoConstraints = false
            overlay.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                host.topAnchor.constraint(equalTo: container.topAnchor),
                host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: container.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            p.contentView = container
            p.setFrameAutosaveName("LiveSubsFloatingPill")
            if !p.setFrameUsingName("LiveSubsFloatingPill") { p.setFrame(defaultFrame(), display: false) }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        model?.setFloatingPillVisible(false)
        panel?.orderOut(nil)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the panel just hides it; the meeting/recording continues.
    }

    private func defaultFrame() -> NSRect {
        let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        // Top-center by default. The panel is the pill: no chrome around it.
        return NSRect(x: v.midX - 218, y: v.maxY - 40, width: 436, height: 36)
    }
}

/// The panel that holds the pill.
///
/// A borderless panel is not a key window by default, and a SwiftUI button in it would then
/// need two clicks; this one can take the key so the pill's buttons work on the first click.
private final class FloatingPillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A view over the pill that lets it be dragged by its body.
///
/// SwiftUI takes the mouse down itself, so the drag cannot live in the hosting view. This view
/// sits on top of it and takes the mouse instead.
///
/// The pill's body is dragged, the pill's buttons are not. Which is which is decided by the
/// pill itself: SwiftUI knows where its buttons are, so it tells this view, and a press over a
/// button is handed straight back to the pill (it becomes a click on the button).
///
/// The drag waits for the pointer to move. A press that stands still is a click, and a pair of
/// clicks is a double click — the pill opens the main window on one. Only once the pointer has
/// travelled is it a drag, and then the window follows it. That way the whole pair of clicks
/// reaches the pill and the drag does not swallow it.
private final class PillDragOverlay: NSView {
    /// The pill's own content, drawn below.
    private weak var below: NSView?
    /// Toggled when the pill's body is double-clicked: opens or minimises the main window.
    var onBodyDoubleClick: (() -> Void)?
    /// The rectangles that belong to a button, in the overlay's coordinates. A press inside one
    /// of them belongs to the pill, not to the drag.
    private(set) var buttonRegions: [CGRect] = []
    /// How far the pointer has to travel before the press becomes a drag.
    private let dragThreshold: CGFloat = 3

    /// The press that has not turned into a drag yet.
    private var pendingPress: NSEvent?
    /// Where the press began, in this view's coordinates.
    private var pressOrigin: NSPoint = .zero
    /// Whether the window is being dragged right now.
    private var dragging = false

    init(below: NSView) {
        self.below = below
        super.init(frame: .zero)
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Points the overlay at the pill's content, once it exists.
    func setContent(_ view: NSView) {
        below = view
    }

    /// Sets where the pill's buttons are. The frames come from SwiftUI's coordinate space and
    /// are in the hosting view's coordinates, so they are moved into this view's.
    func setButtonRegions(_ regions: [CGRect]) {
        guard let below else { return }
        buttonRegions = regions.map { $0.offsetBy(dx: below.frame.minX, dy: below.frame.minY) }
    }

    /// Only the pill's body is draggable; over a button the click goes down to the pill.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if buttonRegions.contains(where: { $0.contains(point) }) { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // A double click on the body toggles the main window. Buttons never reach the overlay
        // (hitTest hands them to the pill), so a click here is always on the body.
        if event.clickCount == 2 {
            pendingPress = nil
            dragging = false
            onBodyDoubleClick?()
            return
        }
        // The press is remembered, not acted on. It becomes a drag when the pointer moves and
        // a click when it does not, and only the pill can tell the two apart.
        pendingPress = event
        pressOrigin = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !dragging {
            // The pointer has moved far enough: this is a drag.
            guard hypot(point.x - pressOrigin.x, point.y - pressOrigin.y) >= dragThreshold else { return }
            dragging = true
            pendingPress = nil
            // AppKit drags the window itself: it follows the pointer exactly, with no lag.
            window?.performDrag(with: event)
            return
        }
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pendingPress = nil
            dragging = false
        }
        guard !dragging, let press = pendingPress else { return }
        // The pointer never moved: this is a click, and it belongs to the pill.
        forwardToPill(press)
    }

    /// Gives the click to the view below, so the pill sees it.
    private func forwardToPill(_ event: NSEvent) {
        guard let below else { return }
        let point = below.convert(event.locationInWindow, from: nil)
        guard let target = below.hitTest(point) else { return }
        target.mouseDown(with: event)
        target.mouseUp(with: event)
    }
}

/// The hosting view that carries the pill.
///
/// The panel never activates the app, so it is almost never the key window when clicked; a plain
/// hosting view would spend that click on focus and every button would need two.
private final class FloatingPillHostingView: NSHostingView<FloatingPillView> {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: FloatingPillView) {
        super.init(rootView: rootView)
    }

    @MainActor required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

/// The SwiftUI view shown inside the floating panel.
private struct FloatingPillView: View {
    @ObservedObject var model: AppModel
    /// Told where the pill's buttons are, so the drag overlay steps aside over them.
    var onButtonRegions: ([CGRect]) -> Void

    var body: some View {
        ListenPill(model: model)
            .frame(height: 36)
            .padding(.horizontal, 8)
            .coordinateSpace(name: "PillButtonSpace")
            .onPreferenceChange(PillButtonRegions.self) { onButtonRegions($0) }
    }
}