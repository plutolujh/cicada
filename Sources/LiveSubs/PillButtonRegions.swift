import SwiftUI

/// Where the pill's buttons are, so the floating panel can let them be clicked.
///
/// The pill is drawn by SwiftUI, but the window that carries it is an AppKit panel with a
/// drag overlay on top of the content. The overlay must know where the buttons are, or it
/// would swallow their clicks. Asking SwiftUI for the button's own frame is exact; guessing
/// from the layout is not, because the pill has a different set of buttons in every state.
struct PillButtonRegions: PreferenceKey {
    /// The frames of the pill's buttons, in the pill's own coordinates.
    static var value: [CGRect] = []

    static var defaultValue: [CGRect] { [] }

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

/// Where the pill's buttons are, in the pill's own local coordinates.
///
/// The double click that opens the main window has to know whether the click landed on a
/// button: a double click on 暂停 is a double click on 暂停, not an instruction to open a
/// window. The named space above belongs to the floating panel and sits outside the pill, so
/// this one measures inside it — the tap and the regions are then in the same space.
struct PillLocalButtonRegions: PreferenceKey {
    static var value: [CGRect] = []

    static var defaultValue: [CGRect] { [] }

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

/// Marks a button of the pill: it reports where it is, so the drag overlay steps aside there.
///
/// The place is reported twice: once in the floating panel's named space, which is outside the
/// pill, and once in the pill's own space, which the pill uses to tell its body from its
/// buttons when a double click asks for the main window.
struct PillButton: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: PillButtonRegions.self,
                        value: [geo.frame(in: .named("PillButtonSpace"))]
                    )
                    .preference(
                        key: PillLocalButtonRegions.self,
                        value: [geo.frame(in: .named("PillLocalSpace"))]
                    )
            }
        )
    }
}

/// Marks the pill's own body: the part that is not a button.
///
/// A double click on the body opens the main window. A double click on a button belongs to
/// that button, so the body has to be told apart from the buttons — in the listening state the
/// logo on the left ends the meeting and the 暂停 / 结束 on the right do their own things, and
/// only the stretch between them is the body.
///
/// The frames are reported in the pill's own space, the same one the double click's location
/// comes in.
struct PillBodyRegion: PreferenceKey {
    static var value: CGRect = .null

    static var defaultValue: CGRect { .null }

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        guard !next.isNull else { return }
        value = value.isNull ? next : value.union(next)
    }
}

extension View {
    /// Reports this button's place in the pill, so it stays clickable under the drag overlay.
    func pillButton() -> some View {
        modifier(PillButton())
    }

    /// Reports this part of the pill as its body: a double click here opens the main window.
    func pillBody() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: PillBodyRegion.self,
                    value: geo.frame(in: .named("PillLocalSpace"))
                )
            }
        )
    }
}

/// Where a double click on the pill lands, and what it should do.
///
/// The pill carries three kinds of place, and they answer differently:
///
/// - the logo on the left ends the meeting, so a double click there keeps that action and
///   opens nothing;
/// - the 暂停 / 恢复 / 停止 / 结束 on the right are buttons, so a double click there is that
///   button's and opens nothing;
/// - the stretch between them is the body, and a double click there opens the main window.
///
/// The rule is kept apart from the view so it can be checked without a mouse: the pill is
/// small, the windows are hard to aim at, and the mistake — a double click that ends the
/// meeting instead of opening the window — is the one that must not happen.
struct PillDoubleClick {
    /// The body of the pill, in the pill's own coordinates.
    var body: CGRect = .null
    /// The buttons of the pill, in the pill's own coordinates.
    var buttons: [CGRect] = []

    /// Whether a double click at this point opens the main window.
    ///
    /// Only the body does. A click on a button is that button's, and the body is only there in
    /// the states that have one: in the idle state the whole pill is the 开始听 button, so
    /// there is no body and a double click there just starts listening.
    func opensMainWindow(at point: CGPoint) -> Bool {
        guard !body.isNull else { return false }
        // A button wins over the body: the regions are measured from the same drawing, but a
        // button's frame may reach into the body's stretch.
        if buttons.contains(where: { $0.contains(point) }) { return false }
        return body.contains(point)
    }
}
