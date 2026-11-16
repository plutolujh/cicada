import SwiftUI
import AppKit

// The AI view's diagram: the question in the middle, its branches around it, and the
// relations between them drawn as curves that end on the boxes they join.
//
// The layout is computed rather than measured: every box has a known size before it is
// drawn, so the curves can be laid out to meet the boxes exactly. That also makes the
// picture in an exported file the same drawing as the one on screen.

/// How the AI view draws a topic's "why" diagram.
enum MindMapStyle: String, CaseIterable, Identifiable {
    case auto, radial, tree, fishbone, graph
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return L("自动")
        case .radial: return L("平衡图")
        case .tree: return L("树形")
        case .fishbone: return L("鱼骨图")
        case .graph: return L("关系图")
        }
    }

    /// The style that fits the content: a couple of branches read best around the question,
    /// a handful in the relation graph, many in the tree where each one has room.
    static func pick(branchCount: Int, detailLength: Int) -> MindMapStyle {
        if branchCount <= 2 { return .radial }
        if branchCount <= 6 && detailLength <= 120 { return .graph }
        return .tree
    }
}

/// The style picker: five small segments in one rounded row.
///
/// Not the system segmented `Picker`: it keeps a minimum width for its labels and paints over
/// its neighbours when the row is narrow, which covered the button next to it. This one sizes
/// to its labels and shrinks the text instead of spilling out.
struct MindMapStylePicker: View {
    @Binding var style: MindMapStyle

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MindMapStyle.allCases) { s in
                Button { style = s } label: {
                    Text(s.title)
                        .font(.system(size: 11, weight: style == s ? .semibold : .regular))
                        .foregroundStyle(style == s ? Palette.ink : Palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: 50)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .background {
                            if style == s {
                                RoundedRectangle(cornerRadius: 6).fill(Color.white)
                                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(s.title)
            }
        }
        .padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.fill))
        .frame(minWidth: 176, maxWidth: 244)
    }
}

/// A box in the diagram: the question, or one of its branches.
struct MindMapBox: Identifiable {
    enum Kind { case question, branch }
    var id: String
    var kind: Kind = .branch
    var title: String
    var detail: String
    var tint: Color
    /// No transcript line backs this branch: it is drawn as a guess.
    var weak = false
    /// When the branch was said, if it was.
    var time: Double?
    /// Where the box sits, in the diagram's own coordinates.
    var frame: CGRect
}

/// A curve between two boxes.
struct MindMapLink {
    enum Kind { case spoke, relation }
    var from: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var to: CGPoint
    var tint: Color
    var weak = false
    var kind: Kind = .spoke
}

/// A laid-out diagram: the boxes, the curves, and how big the whole thing is.
struct MindMapLayout {
    var boxes: [MindMapBox] = []
    var links: [MindMapLink] = []
    var size: CGSize = .zero
}

/// Lays the diagram out for a given width.
enum MindMapLayoutBuilder {
    /// How many lines of a branch's explanation are shown.
    struct Detail {
        var labelLines = 2
        var detailLines = 3
        /// The exported file has the whole page to itself, so it can show more.
        static var file: Detail { Detail(labelLines: 3, detailLines: 6) }
    }

    static func build(_ fish: Fishbone, style: MindMapStyle, width: CGFloat, detail: Detail = Detail()) -> MindMapLayout {
        switch style {
        case .radial: return radial(fish, width: width, detail: detail)
        case .tree: return tree(fish, width: width, detail: detail)
        case .graph: return graph(fish, width: width, detail: detail)
        case .fishbone, .auto: return MindMapLayout()
        }
    }

    // MARK: - Balanced

    /// The question in the middle, branches to the left and to the right.
    private static func radial(_ fish: Fishbone, width: CGFloat, detail: Detail) -> MindMapLayout {
        let gap: CGFloat = 30
        let centerW = questionWidth(question(fish), limit: width * 0.34)
        let branchW = max(80, (width - centerW - 2 * gap) / 2)
        let centerH = questionHeight(question(fish), boxWidth: centerW)
        var layout = MindMapLayout()

        var left: [(index: Int, height: CGFloat)] = []
        var right: [(index: Int, height: CGFloat)] = []
        for (i, b) in fish.branches.enumerated() {
            let h = boxHeight(title: b.label, detail: b.detail, boxWidth: branchW,
                              labelLines: detail.labelLines, detailLines: detail.detailLines)
            if i % 2 == 0 { left.append((i, h)) } else { right.append((i, h)) }
        }
        let leftH = stackHeight(left.map(\.height))
        let rightH = stackHeight(right.map(\.height))
        let contentH = max(leftH, rightH, centerH)
        let centerRect = CGRect(x: (width - centerW) / 2, y: (contentH - centerH) / 2, width: centerW, height: centerH)
        layout.boxes.append(MindMapBox(id: "question", kind: .question, title: question(fish), detail: "",
                                       tint: Palette.accent, frame: centerRect))

        var frames = [CGRect?](repeating: nil, count: fish.branches.count)
        var y = (contentH - leftH) / 2
        for item in left {
            frames[item.index] = CGRect(x: 0, y: y, width: branchW, height: item.height)
            y += item.height + stackGap
        }
        y = (contentH - rightH) / 2
        for item in right {
            frames[item.index] = CGRect(x: width - branchW, y: y, width: branchW, height: item.height)
            y += item.height + stackGap
        }
        for (i, b) in fish.branches.enumerated() {
            guard let frame = frames[i] else { continue }
            layout.boxes.append(branchBox(b, index: i, frame: frame))
            // The curve leaves the question sideways and arrives at the box sideways.
            let from = i % 2 == 0 ? CGPoint(x: centerRect.minX, y: centerRect.midY)
                                  : CGPoint(x: centerRect.maxX, y: centerRect.midY)
            let to = i % 2 == 0 ? CGPoint(x: frame.maxX, y: frame.midY)
                                : CGPoint(x: frame.minX, y: frame.midY)
            let dx = abs(to.x - from.x)
            let dir: CGFloat = to.x >= from.x ? 1 : -1
            layout.links.append(MindMapLink(from: from,
                                            control1: CGPoint(x: from.x + dir * dx * 0.35, y: from.y),
                                            control2: CGPoint(x: to.x - dir * dx * 0.35, y: to.y),
                                            to: to, tint: branchTint(i), weak: b.support == 0))
        }
        layout.size = CGSize(width: width, height: contentH)
        return layout
    }

    // MARK: - Tree

    /// The question on the left, a trunk running right, and every branch hanging off it.
    private static func tree(_ fish: Fishbone, width: CGFloat, detail: Detail) -> MindMapLayout {
        let rootW = questionWidth(question(fish), limit: width * 0.30)
        let childW = max(80, width - rootW - 76)
        let rootH = questionHeight(question(fish), boxWidth: rootW)
        var layout = MindMapLayout()

        var heights: [CGFloat] = []
        for b in fish.branches {
            heights.append(boxHeight(title: b.label, detail: b.detail, boxWidth: childW,
                                     labelLines: detail.labelLines, detailLines: detail.detailLines))
        }
        let childrenH = stackHeight(heights)
        let contentH = max(childrenH, rootH)
        let rootRect = CGRect(x: 0, y: (contentH - rootH) / 2, width: rootW, height: rootH)
        layout.boxes.append(MindMapBox(id: "question", kind: .question, title: question(fish), detail: "",
                                       tint: Palette.accent, frame: rootRect))
        let trunkX = rootRect.maxX + 24
        let childX = width - childW

        var y = (contentH - childrenH) / 2
        for (i, b) in fish.branches.enumerated() {
            let rect = CGRect(x: childX, y: y, width: childW, height: heights[i])
            y += heights[i] + stackGap
            layout.boxes.append(branchBox(b, index: i, frame: rect))
            // Down the trunk, then along it into the box.
            layout.links.append(MindMapLink(from: CGPoint(x: rootRect.maxX, y: rootRect.midY),
                                            control1: CGPoint(x: trunkX, y: rootRect.midY),
                                            control2: CGPoint(x: trunkX, y: rect.midY),
                                            to: CGPoint(x: rect.minX, y: rect.midY),
                                            tint: branchTint(i), weak: b.support == 0))
        }
        layout.size = CGSize(width: width, height: contentH)
        return layout
    }

    // MARK: - Relation graph

    /// The question in the middle, every branch a framed node around it, and the branches
    /// that were said close together linked to each other.
    private static func graph(_ fish: Fishbone, width: CGFloat, detail: Detail) -> MindMapLayout {
        let n = fish.branches.count
        var layout = MindMapLayout()
        guard n > 0 else {
            layout.size = CGSize(width: width, height: 0)
            return layout
        }
        let nodeW = max(80, min(130, width * 0.27))
        let centerW = questionWidth(question(fish), limit: width * 0.32)
        var heights: [CGFloat] = []
        for b in fish.branches {
            heights.append(boxHeight(title: b.label, detail: b.detail, boxWidth: nodeW,
                                     labelLines: detail.labelLines, detailLines: detail.detailLines))
        }
        let maxH = heights.max() ?? 60
        let centerH = questionHeight(question(fish), boxWidth: centerW)
        let centerSize = CGSize(width: centerW, height: centerH)

        // The ring grows until no two boxes touch: a diagram where they do is unreadable.
        let ring = ring(n: n, nodeW: nodeW, heights: heights, centerSize: centerSize, width: width)
        let cx = width / 2
        let cy = ring.ry + maxH / 2 + 10
        let centerRect = CGRect(x: cx - centerW / 2, y: cy - centerH / 2, width: centerW, height: centerH)
        layout.boxes.append(MindMapBox(id: "question", kind: .question, title: question(fish), detail: "",
                                       tint: Palette.accent, frame: centerRect))

        var centers: [CGPoint] = []
        for i in 0..<n {
            let p = ring.centers[i]
            let at = CGPoint(x: cx + p.x, y: cy + p.y)
            centers.append(at)
            let rect = CGRect(x: at.x - nodeW / 2, y: at.y - heights[i] / 2, width: nodeW, height: heights[i])
            layout.boxes.append(branchBox(fish.branches[i], index: i, frame: rect))
        }
        for i in 0..<n {
            let rect = layout.boxes[i + 1].frame
            let from = edgePoint(of: centerRect, towards: centers[i])
            let to = edgePoint(of: rect, towards: CGPoint(x: centerRect.midX, y: centerRect.midY))
            let bend = perpendicular(from: from, to: to, amount: 16)
            layout.links.append(MindMapLink(from: from,
                                            control1: CGPoint(x: from.x + (to.x - from.x) * 0.35 + bend.x,
                                                              y: from.y + (to.y - from.y) * 0.35 + bend.y),
                                            control2: CGPoint(x: from.x + (to.x - from.x) * 0.65 + bend.x,
                                                              y: from.y + (to.y - from.y) * 0.65 + bend.y),
                                            to: to, tint: branchTint(i), weak: fish.branches[i].support == 0))
        }
        // Branches said at the same time belong to the same stretch of talk: link them.
        for i in 0..<n {
            guard let ti = fish.branches[i].t else { continue }
            for j in (i + 1)..<n {
                guard let tj = fish.branches[j].t, abs(ti - tj) <= relatedWindow else { continue }
                let a = layout.boxes[i + 1].frame
                let b = layout.boxes[j + 1].frame
                let from = edgePoint(of: a, towards: CGPoint(x: b.midX, y: b.midY))
                let to = edgePoint(of: b, towards: CGPoint(x: a.midX, y: a.midY))
                let bend = perpendicular(from: from, to: to, amount: 12)
                layout.links.append(MindMapLink(from: from,
                                                control1: CGPoint(x: from.x + (to.x - from.x) * 0.35 + bend.x,
                                                                  y: from.y + (to.y - from.y) * 0.35 + bend.y),
                                                control2: CGPoint(x: from.x + (to.x - from.x) * 0.65 + bend.x,
                                                                  y: from.y + (to.y - from.y) * 0.65 + bend.y),
                                                to: to, tint: Palette.tertiary, kind: .relation))
            }
        }
        layout.size = CGSize(width: width, height: 2 * ring.ry + maxH + 20)
        return layout
    }

    /// Where the branch boxes sit on the ring, and how big the ring has to be for none of
    /// them to touch.
    private struct Ring {
        var centers: [CGPoint]
        var rx: CGFloat
        var ry: CGFloat
    }

    /// Grows the ring until the boxes stand clear of each other and of the question.
    private static func ring(n: Int, nodeW: CGFloat, heights: [CGFloat], centerSize: CGSize, width: CGFloat) -> Ring {
        // The ring is as wide as the drawing allows; only its height may grow.
        let rx = max(width / 2 - nodeW / 2 - 4, 40)
        var ry: CGFloat = 54
        for _ in 0..<200 {
            let centers = ringCenters(n: n, rx: rx, ry: ry)
            if ringIsClear(centers: centers, nodeW: nodeW, heights: heights, centerSize: centerSize) {
                return Ring(centers: centers, rx: rx, ry: ry)
            }
            ry *= 1.06
        }
        return Ring(centers: ringCenters(n: n, rx: rx, ry: ry), rx: rx, ry: ry)
    }

    /// The branch boxes sit on an ellipse around the question, starting at the top.
    private static func ringCenters(n: Int, rx: CGFloat, ry: CGFloat) -> [CGPoint] {
        (0..<n).map { i in
            let angle = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(n)
            return CGPoint(x: CGFloat(cos(angle)) * rx, y: CGFloat(sin(angle)) * ry)
        }
    }

    /// Whether every box stands clear of the others. The boxes are measured against the
    /// centre of the ring, so the question sits in the middle of it.
    private static func ringIsClear(centers: [CGPoint], nodeW: CGFloat, heights: [CGFloat], centerSize: CGSize) -> Bool {
        func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
            a.insetBy(dx: -0.5, dy: -0.5).intersects(b.insetBy(dx: -0.5, dy: -0.5))
        }
        let question = CGRect(x: -centerSize.width / 2, y: -centerSize.height / 2,
                              width: centerSize.width, height: centerSize.height)
        var rects: [CGRect] = [question]
        for (i, c) in centers.enumerated() {
            rects.append(CGRect(x: c.x - nodeW / 2, y: c.y - heights[i] / 2, width: nodeW, height: heights[i]))
        }
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count where overlaps(rects[i], rects[j]) {
                return false
            }
        }
        return true
    }

    // MARK: - Shared

    /// Two branches said within this many seconds of each other count as related.
    private static let relatedWindow: Double = 45
    private static let stackGap: CGFloat = 12
    /// The padding inside every box, so the text is measured in the space it really has.
    static let boxPaddingH: CGFloat = 10
    static let boxPaddingV: CGFloat = 9

    private static func question(_ fish: Fishbone) -> String {
        fish.question.isEmpty ? L("为什么") : fish.question
    }

    /// How wide the question's box has to be to hold the question, up to `limit`. The
    /// question is usually a full sentence, so a fixed width would cut it off.
    private static func questionWidth(_ text: String, limit: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .bold)
        let bound = (text as NSString).boundingRect(
            with: NSSize(width: limit, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        return min(ceil(bound.width) + 26, limit)
    }

    /// How tall the question's box is: the question, wrapped, plus its padding.
    private static func questionHeight(_ text: String, boxWidth: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .bold)
        let bound = (text as NSString).boundingRect(
            with: NSSize(width: boxWidth - 26, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        return 10 * 2 + ceil(bound.height) + 2
    }

    private static func branchBox(_ b: FishboneBranch, index: Int, frame: CGRect) -> MindMapBox {
        MindMapBox(id: b.id, title: b.label, detail: b.detail, tint: branchTint(index),
                   weak: b.support == 0, time: b.t, frame: frame)
    }

    private static func stackHeight(_ heights: [CGFloat]) -> CGFloat {
        guard !heights.isEmpty else { return 0 }
        return heights.reduce(0, +) + stackGap * CGFloat(heights.count - 1)
    }

    /// The point on the box's border that faces `towards`.
    private static func edgePoint(of rect: CGRect, towards target: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - center.x
        let dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let tx = abs(dx) > 0.0001 ? (rect.width / 2) / abs(dx) : CGFloat.greatestFiniteMagnitude
        let ty = abs(dy) > 0.0001 ? (rect.height / 2) / abs(dy) : CGFloat.greatestFiniteMagnitude
        let t = min(tx, ty)
        return CGPoint(x: center.x + dx * t, y: center.y + dy * t)
    }

    /// A sideways push, so a curve between two boxes bows instead of running straight.
    private static func perpendicular(from: CGPoint, to: CGPoint, amount: CGFloat) -> CGPoint {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let len = max((dx * dx + dy * dy).squareRoot(), 1)
        return CGPoint(x: -dy / len * amount, y: dx / len * amount)
    }

    /// How tall a box is: the text it holds, wrapped, plus its padding. `boxWidth` is the
    /// width of the whole box, so the padding comes off before the text is measured.
    static func boxHeight(title: String, detail: String, boxWidth: CGFloat, labelLines: Int, detailLines: Int) -> CGFloat {
        let inner = boxWidth - boxPaddingH * 2
        let labelH = textHeight(title, size: 12, weight: .semibold, width: inner, maxLines: labelLines)
        let detailH = detail.isEmpty ? 0 : textHeight(detail, size: 11, weight: .regular, width: inner, maxLines: detailLines)
        return boxPaddingV * 2 + labelH + (detailH > 0 ? 3 + detailH : 0)
    }

    /// The height a piece of text takes when it is wrapped to `width`.
    static func textHeight(_ text: String, size: CGFloat, weight: NSFont.Weight, width: CGFloat, maxLines: Int) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let bound = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        let line = font.boundingRectForFont.height
        return min(ceil(bound.height), ceil(line) * CGFloat(maxLines)) + 2
    }
}

// MARK: - Drawing

/// The diagram, drawn: the curves underneath, the boxes on top.
struct MindMapDrawing: View {
    let fishbone: Fishbone
    let style: MindMapStyle
    let onJump: (Double) -> Void
    /// The width to draw in. The screen uses a fixed width so the layout is certain before the
    /// first draw: inside a ScrollView a measured width starts at zero and flashes a wrong,
    /// overflowing diagram until the two-pass measurement comes back. The export passes its
    /// own width so the picture is laid out in one pass.
    var width: CGFloat = 460
    var detail: MindMapLayoutBuilder.Detail = .init()

    var body: some View {
        drawing(width: width)
    }

    private func drawing(width: CGFloat) -> AnyView {
        let layout = MindMapLayoutBuilder.build(fishbone, style: style, width: width, detail: detail)
        return AnyView(
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for link in layout.links {
                        var path = Path()
                        path.move(to: link.from)
                        path.addCurve(to: link.to, control1: link.control1, control2: link.control2)
                        let weak = link.weak || link.kind == .relation
                        let color = weak ? Color(white: 0.80) : link.tint.opacity(0.55)
                        let stroke = weak
                            ? StrokeStyle(lineWidth: 1.2, dash: [4, 3])
                            : StrokeStyle(lineWidth: 2, lineCap: .round)
                        ctx.stroke(path, with: .color(color), style: stroke)
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height)
                .allowsHitTesting(false)

                ForEach(layout.boxes) { box in
                    boxView(box)
                        .frame(width: box.frame.width, height: box.frame.height)
                        .offset(x: box.frame.minX, y: box.frame.minY)
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)
        )
    }

    private func boxView(_ box: MindMapBox) -> some View {
        if box.kind == .question {
            return AnyView(
                Text(box.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .background(RoundedRectangle(cornerRadius: 12).fill(box.tint))
                    .shadow(color: box.tint.opacity(0.25), radius: 6, y: 2)
            )
        }
        let weak = box.weak
        return AnyView(
            Button { if let t = box.time { onJump(t) } } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(box.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(weak ? Palette.tertiary : Palette.ink)
                        .lineLimit(detail.labelLines).fixedSize(horizontal: false, vertical: true)
                    if !box.detail.isEmpty {
                        Text(box.detail)
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                            .lineLimit(detail.detailLines).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10).fill(weak ? Color.white : box.tint.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(weak ? Color(white: 0.85) : box.tint.opacity(0.5),
                            style: weak ? StrokeStyle(lineWidth: 1, dash: [4, 3]) : StrokeStyle(lineWidth: 1)))
                .shadow(color: weak ? .clear : box.tint.opacity(0.15), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .help(weak ? L("依据较少，仅供参考") : L("看原话"))
        )
    }
}

// MARK: - Adaptive

/// A per-topic diagram for the AI view.
struct AdaptiveMindMapView: View {
    let fishbone: Fishbone
    var style: MindMapStyle = .auto
    var onJump: (Double) -> Void = { _ in }
    /// The "点击分支跳回原话" hint is for the screen, where a file has no lines to jump to.
    var showsHint = true
    /// The width to draw in. The screen uses a fixed width so the layout is certain before the
    /// first draw: inside a ScrollView a measured width starts at zero and flashes a wrong,
    /// overflowing diagram until the two-pass measurement comes back. The export passes its
    /// own width so the picture is laid out in one pass.
    var width: CGFloat = 460
    var detail: MindMapLayoutBuilder.Detail = .init()

    private var kind: MindMapStyle {
        switch style {
        case .auto:
            let detail = fishbone.branches.reduce(0) { $0 + $1.detail.count }
            return MindMapStyle.pick(branchCount: fishbone.branches.count, detailLength: detail)
        case .radial, .tree, .fishbone, .graph: return style
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                switch kind {
                case .fishbone:
                    FishboneView(fishbone: fishbone, onJump: onJump, showsHint: showsHint)
                case .radial, .tree, .graph:
                    MindMapDrawing(fishbone: fishbone, style: kind, onJump: onJump, width: width, detail: detail)
                case .auto:
                    EmptyView()
                }
            }
            if showsHint && kind != .fishbone {
                Text(L("点击分支跳回原话")).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            }
        }
        .mindMapFrame()
    }
}

/// The card every diagram sits in, so the screen and the exported file look the same.
private struct MindMapFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.raised.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1)))
    }
}

extension View {
    func mindMapFrame() -> some View { modifier(MindMapFrame()) }
}

private let branchTints: [Color] = [
    Color(red: 0.91, green: 0.45, blue: 0.17), // orange
    Color(red: 0.20, green: 0.55, blue: 0.85), // blue
    Color(red: 0.22, green: 0.68, blue: 0.45), // green
    Color(red: 0.55, green: 0.40, blue: 0.80), // purple
    Color(red: 0.85, green: 0.35, blue: 0.45), // rose
    Color(red: 0.15, green: 0.65, blue: 0.70), // teal
]

func branchTint(_ i: Int) -> Color { branchTints[i % branchTints.count] }
