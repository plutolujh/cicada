import Combine
import Foundation
import Testing
@testable import LiveSubs

/// Pinning a meeting: the flag lands, the list is told to redraw, and it survives a restart.
@MainActor
struct SessionStoreTests {
    /// A store with a scratch folder, holding the given meetings.
    private func makeStore(_ meetings: [Session]) -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cicada-store-tests-\(UUID().uuidString)", isDirectory: true)
        let root = dir.appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for s in meetings {
            let d = root.appendingPathComponent(s.id, isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            if let data = try? encoder.encode(s) {
                try? data.write(to: d.appendingPathComponent("session.json"))
            }
        }
        return (SessionStore(root: root, trashRoot: dir.appendingPathComponent("Trash", isDirectory: true)), dir)
    }

    private func meeting(_ id: String) -> Session {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return Session(id: id, title: "会议 \(id)", startedAt: start, endedAt: start.addingTimeInterval(60),
                       lines: [], hasAudio: false)
    }

    @Test func pinningTellsTheListToRedraw() {
        let (store, dir) = makeStore([meeting("a")])
        defer { try? FileManager.default.removeItem(at: dir) }
        var told = 0
        let c = store.objectWillChange.sink { told += 1 }
        store.togglePin("a")
        #expect(store.isPinned("a"))
        #expect(told > 0)
        store.togglePin("a")
        #expect(!store.isPinned("a"))
        #expect(told > 1)
        _ = c
    }

    @Test func pinningSurvivesARestart() {
        let (store, dir) = makeStore([meeting("a")])
        defer { try? FileManager.default.removeItem(at: dir) }
        store.togglePin("a")
        let again = SessionStore(root: dir.appendingPathComponent("Sessions"),
                                 trashRoot: dir.appendingPathComponent("Trash", isDirectory: true))
        #expect(again.isPinned("a"))
    }
}
