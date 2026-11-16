import Foundation
import Testing
@testable import LiveSubs

/// The AI view's diagram: the boxes have to sit where they are drawn, and the curves have
/// to end on them.
@Suite struct MindMapTests {
    private func branch(_ label: String, _ detail: String = "", t: Double? = nil, support: Int = 2) -> FishboneBranch {
        FishboneBranch(label: label, detail: detail, t: t, support: support)
    }

    private func fish(_ branches: [FishboneBranch]) -> Fishbone {
        Fishbone(question: "Why late?", branches: branches)
    }

    private func boxes(_ layout: MindMapLayout) -> [MindMapBox] {
        layout.boxes.filter { $0.kind == .branch }
    }

    @Test func everyBranchGetsABox() {
        let f = fish([branch("Tests"), branch("Review"), branch("Scope")])
        for style in [MindMapStyle.radial, .tree, .graph] {
            let layout = MindMapLayoutBuilder.build(f, style: style, width: 460)
            #expect(boxes(layout).count == 3)
            #expect(layout.boxes.first?.kind == .question)
            // One curve per branch.
            #expect(layout.links.filter { $0.kind == .spoke }.count == 3)
        }
    }

    @Test func boxesStayInsideTheDiagram() {
        let f = fish([branch("Tests", "They were slow"), branch("Review", "Two days"), branch("Scope")])
        for style in [MindMapStyle.radial, .tree, .graph] {
            let layout = MindMapLayoutBuilder.build(f, style: style, width: 460)
            for box in layout.boxes {
                #expect(box.frame.minX >= -0.5)
                #expect(box.frame.maxX <= layout.size.width + 0.5)
                #expect(box.frame.minY >= -0.5)
                #expect(box.frame.maxY <= layout.size.height + 0.5)
            }
        }
    }

    /// No two boxes may overlap: a diagram where they do is unreadable.
    @Test func noTwoBoxesOverlap() {
        let f = fish((0..<6).map { branch("Reason \($0)", "Some explanation for it") })
        for style in [MindMapStyle.radial, .tree, .graph] {
            let layout = MindMapLayoutBuilder.build(f, style: style, width: 460)
            let rects = layout.boxes.map(\.frame)
            for i in 0..<rects.count {
                for j in (i + 1)..<rects.count {
                    let overlap = rects[i].intersects(rects[j])
                    #expect(!overlap, "\(style): box \(i) overlaps box \(j)")
                }
            }
        }
    }

    /// Every curve has to start and end on the boxes it joins.
    @Test func curvesEndOnTheirBoxes() {
        let f = fish([branch("Tests", "They were slow", t: 30), branch("Review", "Two days", t: 40)])
        for style in [MindMapStyle.radial, .tree, .graph] {
            let layout = MindMapLayoutBuilder.build(f, style: style, width: 460)
            for link in layout.links {
                for point in [link.from, link.to] {
                    let onBox = layout.boxes.contains { $0.frame.insetBy(dx: -0.5, dy: -0.5).contains(point) }
                    #expect(onBox, "\(style): a curve ends in the empty")
                }
            }
        }
    }

    /// Branches said at the same time belong to the same stretch of talk: they are linked.
    @Test func branchesSaidTogetherAreLinked() {
        let together = fish([branch("A", t: 10), branch("B", t: 20), branch("C", t: 300)])
        let layout = MindMapLayoutBuilder.build(together, style: .graph, width: 460)
        #expect(layout.links.contains { $0.kind == .relation })

        let apart = fish([branch("A", t: 10), branch("B", t: 900)])
        let apartLayout = MindMapLayoutBuilder.build(apart, style: .graph, width: 460)
        #expect(!apartLayout.links.contains { $0.kind == .relation })
    }

    /// A branch with no transcript line behind it is drawn as a guess.
    @Test func aBranchWithoutEvidenceIsWeak() {
        let f = fish([branch("Tests", support: 0)])
        let layout = MindMapLayoutBuilder.build(f, style: .graph, width: 460)
        #expect(boxes(layout).first?.weak == true)
    }

    /// The style that fits: a couple of branches around the question, many in the tree.
    @Test func theStyleFitsTheContent() {
        #expect(MindMapStyle.pick(branchCount: 2, detailLength: 20) == .radial)
        #expect(MindMapStyle.pick(branchCount: 4, detailLength: 40) == .graph)
        #expect(MindMapStyle.pick(branchCount: 9, detailLength: 40) == .tree)
        // A long explanation needs room, so it goes to the tree.
        #expect(MindMapStyle.pick(branchCount: 4, detailLength: 400) == .tree)
    }

    /// A box is tall enough for the text it holds, and no taller.
    @Test func aBoxIsSizedForItsText() {
        let short = MindMapLayoutBuilder.boxHeight(title: "Tests", detail: "", boxWidth: 140, labelLines: 2, detailLines: 3)
        let long = MindMapLayoutBuilder.boxHeight(title: "Tests", detail: String(repeating: "long text ", count: 20),
                                                   boxWidth: 140, labelLines: 2, detailLines: 3)
        #expect(long > short)
        // The detail is capped at the number of lines it is allowed.
        let capped = MindMapLayoutBuilder.boxHeight(title: "Tests", detail: String(repeating: "long text ", count: 20),
                                                    boxWidth: 140, labelLines: 2, detailLines: 1)
        #expect(capped < long)
    }
}
