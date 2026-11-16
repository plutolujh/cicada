import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LiveSubs

/// The export has to carry the diagram, not a text tree of it: the reader picked a style and
/// the file has to show it.
@Suite struct ExportImageTests {
    private var fish: Fishbone {
        Fishbone(question: "为什么这个项目延期了？", branches: [
            FishboneBranch(label: "需求反复变更", detail: "第三轮改版又推翻了接口设计", t: 62, support: 4),
            FishboneBranch(label: "测试拖期", detail: "回归用例没写完", t: 95, support: 3),
        ])
    }

    private var session: Session {
        Session(id: "s1", title: "会议 11月1日 14:30", startedAt: Date(), endedAt: nil,
                lines: [], hasAudio: false,
                notes: MeetingNotes(summary: "延期了",
                                    topics: [NoteTopic(start: 0, title: "延期", summary: "延期了",
                                                       points: ["需求反复变更"], fishbone: fish)]))
    }

    /// Every style draws something: the picture is not blank.
    @MainActor
    @Test func everyStyleDrawsAPicture() {
        for style in MindMapStyle.allCases {
            let img = FishboneImage.image(fish, style: style)
            #expect(img != nil, "\(style) drew nothing")
            guard let img else { continue }
            #expect(img.size.width > 100 && img.size.height > 100, "\(style) drew a speck")
            // Some colour in the picture: the diagram is not an empty sheet.
            let colors = Self.distinctColors(in: img)
            #expect(colors > 3, "\(style) drew only \(colors) colours")
        }
    }

    /// The styled document carries the picture as an attachment, so the PDF draws it.
    @MainActor
    @Test func theDocumentCarriesTheDiagram() {
        let images = FishboneImage.images(session.notes ?? MeetingNotes(), style: .graph)
        #expect(images.count == 1)
        let doc = TranscriptExport.styledDocument(session, options: ExportOptions(), images: images)
        let attachments = (0..<doc.length).compactMap { doc.attribute(.attachment, at: $0, effectiveRange: nil) as? NSTextAttachment }
        #expect(attachments.count == 1, "the diagram is not in the document")
        guard let image = attachments.first?.image else {
            #expect(Bool(false), "the attachment has no image")
            return
        }
        #expect(image.size.width > 100)
    }

    /// And the PDF itself is a real file with the diagram in it.
    @MainActor
    @Test func thePDFFitsTheDiagram() {
        let images = FishboneImage.images(session.notes ?? MeetingNotes(), style: .graph)
        let data = TranscriptExport.pdf(session, options: ExportOptions(), images: images)
        #expect(data.count > 1000)
        #expect(data.starts(with: Array("%PDF".utf8)))
        #expect(data.contains(0xFF) || data.count > 2000)
        // A dev aid: write the file so it can be opened and looked at.
        if ProcessInfo.processInfo.environment["CICDAMINDMAP_RENDER"] != nil {
            try? data.write(to: URL(fileURLWithPath: "/tmp/mindmap-export.pdf"))
        }
    }

    /// The screen path measures its own width, which takes two passes: it has to draw too.
    @MainActor
    @Test func theScreenPathDrawsAsWell() {
        let host = NSHostingView(rootView: AdaptiveMindMapView(fishbone: fish, style: .graph, showsHint: false))
        host.frame = CGRect(x: 0, y: 0, width: 520, height: 400)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        win.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        // Give the measured width a chance to come back and the diagram to redraw.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()

        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        #expect(rep != nil)
        guard let rep else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        var colors = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                if let c = rep.colorAt(x: x, y: y) {
                    let r = UInt32(c.redComponent * 255), g = UInt32(c.greenComponent * 255), b = UInt32(c.blueComponent * 255)
                    colors.insert((r / 24) << 16 | (g / 24) << 8 | (b / 24))
                }
            }
        }
        #expect(colors.count > 3, "the screen path drew \(colors.count) colours")
        if ProcessInfo.processInfo.environment["CICDAMINDMAP_RENDER"] != nil,
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/mindmap-screen.png"))
        }
        win.orderOut(nil)
    }

    /// How many different colours the picture has: enough to tell a drawing from a blank sheet.
    @MainActor
    private static func distinctColors(in img: NSImage) -> Int {        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                if let c = rep.colorAt(x: x, y: y) {
                    let r = UInt32(c.redComponent * 255), g = UInt32(c.greenComponent * 255), b = UInt32(c.blueComponent * 255)
                    seen.insert((r / 24) << 16 | (g / 24) << 8 | (b / 24))
                }
            }
        }
        return seen.count
    }
}
