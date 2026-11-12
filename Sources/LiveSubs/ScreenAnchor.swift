import AppKit
import SwiftUI

/// Reports where a view sits on the screen, so a menu can be popped open under it.
///
/// The menu is a native `NSMenu`, so it has to be opened with an event at a screen position;
/// SwiftUI has no way to ask where its own button is.
struct ScreenAnchor: NSViewRepresentable {
    /// The point the menu opens at, in screen coordinates.
    @Binding var rect: NSRect?

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        // A view that never draws still knows where it is once it is in a window.
        v.postsFrameChangedNotifications = true
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let frame = view.convert(view.bounds, to: nil)
            let screen = window.convertToScreen(frame)
            if rect != screen { rect = screen }
        }
    }
}
