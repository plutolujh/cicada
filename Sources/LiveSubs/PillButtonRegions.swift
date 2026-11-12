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

/// Marks a button of the pill: it reports where it is, so the drag overlay steps aside there.
struct PillButton: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: PillButtonRegions.self,
                    value: [geo.frame(in: .named("PillButtonSpace"))]
                )
            }
        )
    }
}

extension View {
    /// Reports this button's place in the pill, so it stays clickable under the drag overlay.
    func pillButton() -> some View {
        modifier(PillButton())
    }
}
