import SwiftUI
import AppKit
import Testing
@testable import LiveSubs

/// Writes the diagrams to PNGs so they can be looked at. Not an assertion: the images land
/// in /tmp, and only when CICADAMINDMAP_RENDER is set, so a normal test run stays quiet.
@Suite struct MindMapRenderTests {
    @MainActor
    @Test func renderTheDiagrams() throws {
        guard ProcessInfo.processInfo.environment["CICDAMINDMAP_RENDER"] != nil else { return }
        let fish = Fishbone(question: "为什么这个项目延期了？", branches: [
            FishboneBranch(label: "需求反复变更", detail: "第三轮改版又推翻了接口设计，前端返工两周", t: 62, support: 4),
            FishboneBranch(label: "测试拖期", detail: "回归用例没写完，联调又等了外部接口", t: 95, support: 3),
            FishboneBranch(label: "关键人请假", detail: "架构师休假两周，评审无人拍板", t: 110, support: 2),
            FishboneBranch(label: "依赖方未就绪", detail: "支付网关的联调环境到周三才可用", t: 400, support: 1),
            FishboneBranch(label: "排期过于乐观", detail: "没有人预留返工buffer", t: 405, support: 0),
        ])
        for style in [MindMapStyle.radial, .tree, .graph, .fishbone] {
            let view = AdaptiveMindMapView(fishbone: fish, style: style, showsHint: false,
                                           width: 460, detail: .file)
                .frame(width: 460)
                .padding(12)
                .background(Color.white)
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: "/tmp/mindmap-\(style.rawValue).png"))
        }
    }
}
