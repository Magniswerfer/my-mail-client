import Foundation
import Testing
@testable import MailEngine

/// A no-change sync of a big folder (SPEC §15). Off by default (seeding takes a while):
/// `TIDINGS_BENCH=10000 swift test --package-path MailEngine --filter SyncBenchmarkTests`.
@Suite(.serialized) struct SyncBenchmarkTests {
    static var size: Int? { ProcessInfo.processInfo.environment["TIDINGS_BENCH"].flatMap(Int.init) }

    @Test func noChangeSyncOfALargeFolder() async throws {
        guard let size = Self.size, await SyncIntegrationTests.serverAvailable else { return }
        let user = "bench-\(UUID().uuidString.prefix(8))"
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: 31143, useTLS: false, username: user)
        let seedStart = ContinuousClock.now
        try await MailSession.open(endpoint: endpoint, password: "tidings-test") { session in
            for i in 0..<size {
                let raw = """
                    From: Sender \(i % 50) <sender\(i % 50)@example.com>\r
                    To: me@example.com\r
                    Subject: Benchmark message \(i)\r
                    Date: Mon, 2 Nov 2026 10:00:00 +0100\r
                    Message-ID: <bench-\(i)@example.com>\r
                    \r
                    Body of message \(i).\r

                    """
                _ = try await session.append(to: "INBOX", message: Data(raw.utf8), flags: i % 3 == 0 ? ["\\Seen"] : [])
            }
        }
        print("bench: seeded \(size) messages in \(ContinuousClock.now - seedStart)")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-bench-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        let account = AccountConfig(id: "bench", displayName: "Bench", endpoint: endpoint, addresses: ["me@example.com"])
        let sync = AccountSync(account: account, password: "tidings-test", store: store,
                               cache: MessageCache(directory: dir.appendingPathComponent("cache")), profile: .generic)

        let firstStart = ContinuousClock.now
        try await sync.syncOnce()
        print("bench: first sync \(ContinuousClock.now - firstStart)")
        #expect(try store.count() == size)

        var timings: [Duration] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            try await sync.syncOnce()
            timings.append(ContinuousClock.now - start)
        }
        let sorted = timings.sorted()
        print("bench: no-change sync of \(size) messages: median \(sorted[sorted.count / 2]), runs \(timings)")
        #expect(try store.count() == size)
    }
}
