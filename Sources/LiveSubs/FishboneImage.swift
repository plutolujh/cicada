import AppKit
import SwiftUI

// The fishbone as a picture.
//
// A file cannot hold a SwiftUI view, but it can hold a picture: the export gets the same
// diagram the reader saw in the meeting record, drawn by the same view.

@MainActor
enum FishboneImage {
    /// The picture of one fishbone, or nil when it cannot be drawn.
    static func image(_ fish: Fishbone, width: CGFloat = 460) -> NSImage? {
        let view = FishboneView(fishbone: fish, showsHint: false)
            .frame(width: width)
            .padding(12)
            .background(Color.white)
        let r = ImageRenderer(content: view)
        r.scale = 2
        return r.nsImage
    }

    /// One picture per topic that has a fishbone, keyed by the topic.
    static func images(_ notes: MeetingNotes) -> [String: NSImage] {
        var out: [String: NSImage] = [:]
        for t in notes.topics {
            guard let f = t.fishbone, let img = image(f) else { continue }
            out[t.id] = img
        }
        return out
    }
}
