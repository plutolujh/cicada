import AppKit
import SwiftUI

// The mindmap as a picture.
//
// A file cannot hold a SwiftUI view, but it can hold a picture: the export gets the same
// diagram the reader saw in the meeting record, drawn by the same view — including the style
// the reader picked (平衡图 / 树形 / 鱼骨图).

@MainActor
enum FishboneImage {
    /// The picture of one fishbone, or nil when it cannot be drawn.
    static func image(_ fish: Fishbone, style: MindMapStyle = .auto, width: CGFloat = 460) -> NSImage? {
        // The width is passed in, not measured: the export draws the view in one pass, so a
        // diagram that measured itself would come out empty.
        let view = AdaptiveMindMapView(fishbone: fish, style: style, showsHint: false,
                                       width: width, detail: .file)
            .frame(width: width)
            .padding(12)
            .background(Color.white)
        let r = ImageRenderer(content: view)
        r.scale = 2
        return r.nsImage
    }

    /// One picture per topic that has a fishbone, keyed by the topic.
    static func images(_ notes: MeetingNotes, style: MindMapStyle = .auto) -> [String: NSImage] {
        var out: [String: NSImage] = [:]
        for t in notes.topics {
            guard let f = t.fishbone, let img = image(f, style: style) else { continue }
            out[t.id] = img
        }
        return out
    }
}
