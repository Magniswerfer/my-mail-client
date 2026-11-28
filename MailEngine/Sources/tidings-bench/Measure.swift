import Foundation
import MailEngine
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct BenchError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

struct BenchResults: Codable {
    var version = 1
    var commit: String?
    var date: Date
    var platform: String
    /// The processor model: timings are only compared between runs on the same one.
    var cpu: String?
    var messages: Int
    var metrics: [Metric]
}

struct Metric: Codable {
    var id: String
    var label: String
    var unit: String
    var value: Double
    /// SPEC §15's limit; nil for a figure that is only reported.
    var budget: Double?
    /// Changes smaller than this never count as a regression (timer and runner noise).
    var noiseFloor: Double
    /// Checked against the baseline.
    var gated: Bool

    var budgetText: String { budget.map { String(format: "< %g %@", $0, unit) } ?? "—" }
}

/// What each budget covers, as far as the engine goes (the UI's share — SwiftUI layout, the
/// WKWebView, scrolling — is not measurable headless and is not in these numbers):
///
/// - **Cold launch → usable stream**: open the store (GRDB pool + migration check) and read the
///   Inbox conversations the stream shows (`threads(mailbox:)`), as `AppModel.reload` does.
/// - **Search keystroke → results**: phase 1 of `AppModel.runSearch`, the hits plus the person
///   card, over the typed sequence from `tidings-probe bench-search`. **Facets**: phase 2.
/// - **Open cached message**: the conversation's messages, the raw body from the cache tier and
///   a full MIME parse (text, HTML, attachment list).
/// - **Memory**: the process's peak resident size after all of the above.
enum Measure {
    static let typed = ["f", "fa", "fak", "fakt", "faktu", "faktura", "faktura z", "faktura za",
                        "s", "sk", "sko", "sko from:zalando", "m", "mø", "møde", "møde projekt",
                        "invoice after:2024-01-01", "category:advertising", "has:attachment kontrakt",
                        "from:anna", "\"din pakke\"", "security -password"]
    /// Extra prefixes for the person card: names and addresses people type ("no" → noreply@…).
    static let senderPrefixes = ["an", "anna", "pe", "peter", "no", "noreply", "post", "ma"]

    /// Runs the whole measurement `repeats` times and keeps each metric's median run, so one
    /// noisy pass (a busy CI neighbour) moves nothing: a single pass's search p95 varies ±15%
    /// on identical code, the median of five a few percent.
    static func all(directory: URL, rounds: Int, repeats: Int) throws -> BenchResults {
        var passes: [BenchResults] = []
        for n in 1...max(1, repeats) {
            passes.append(try once(directory: directory, rounds: rounds))
            print("pass \(n): " + passes[passes.count - 1].metrics.filter(\.gated)
                .map { String(format: "%@ %.2f", $0.id, $0.value) }.joined(separator: ", "))
        }
        var result = passes[0]
        for i in result.metrics.indices {
            result.metrics[i].value = percentile(passes.map { $0.metrics[i].value }, 0.5)
        }
        return result
    }

    static func once(directory: URL, rounds: Int) throws -> BenchResults {
        let path = Workload.storePath(directory)
        guard FileManager.default.fileExists(atPath: path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        let own: Set<String> = [Workload.me]

        // Cold launch → usable stream. The first open in this process is the coldest the runner
        // allows (the OS may still cache the file from `seed`); later opens show the spread.
        var launch: [Double] = []
        var inboxThreads = 0
        for _ in 0..<7 {
            let start = ContinuousClock.now
            let store = try MailStore(path: path)
            inboxThreads = try store.threads(mailbox: "INBOX", ownAddresses: own).count
            launch.append(ms(ContinuousClock.now - start))
        }

        let store = try MailStore(path: path)
        let messages = try store.count()

        // Search, phase 1 (hits) and phase 2 (facets).
        let engine = SearchEngine(store: store)
        _ = try engine.hits(SearchQuery(parsing: "warmup"))
        var hits: [Double] = []
        var facets: [Double] = []
        var contact: [Double] = []
        for _ in 0..<rounds {
            for text in typed {
                // What the app waits for before results show (AppModel.runSearch, phase 1): the
                // hits and the person card above them.
                let query = SearchQuery(parsing: text)
                let start = ContinuousClock.now
                _ = try engine.hits(query)
                _ = try engine.contact(for: query)
                hits.append(ms(ContinuousClock.now - start))
                if query.wantsFacets { facets.append(ms(try engine.facets(query).duration)) }
            }
            // The person card alone, with prefixes that match busy senders.
            for text in typed + senderPrefixes {
                let start = ContinuousClock.now
                _ = try engine.contact(for: SearchQuery(parsing: text))
                contact.append(ms(ContinuousClock.now - start))
            }
        }

        // Open a cached message.
        let cache = Workload.cache(directory)
        let opened = try store.threads(mailbox: "INBOX", ownAddresses: own, limit: Workload.cachedBodies)
            .map(\.latest)
            .filter { cache.cachedRaw(for: $0, store: store) != nil }
        guard !opened.isEmpty else { throw BenchError("no cached bodies in \(directory.path); run `seed` first") }
        var open: [Double] = []
        var parsedBytes = 0
        for _ in 0..<3 {
            for message in opened {
                let start = ContinuousClock.now
                let conversation = try store.messages(inThread: message.threadID ?? "")
                guard let raw = cache.cachedRaw(for: message, store: store) else { continue }
                let parsed = MIMEParser.parse(raw)
                parsedBytes &+= conversation.count + parsed.plainText.utf8.count + (parsed.html?.utf8.count ?? 0) + parsed.attachments.count
                open.append(ms(ContinuousClock.now - start))
            }
        }
        precondition(parsedBytes > 0)

        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        print("Inbox: \(inboxThreads) conversations; first open \(String(format: "%.1f", launch[0])) ms; \(opened.count) cached bodies")

        return BenchResults(
            commit: ProcessInfo.processInfo.environment["GITHUB_SHA"],
            date: Date(),
            platform: platform,
            cpu: cpuModel,
            messages: messages,
            metrics: [
                Metric(id: "launch.stream", label: "Cold launch → usable stream (p50)", unit: "ms",
                       value: percentile(launch, 0.5), budget: 400, noiseFloor: 5, gated: true),
                Metric(id: "search.hits.p95", label: "Search keystroke → results (p95)", unit: "ms",
                       value: percentile(hits, 0.95), budget: 30, noiseFloor: 1, gated: true),
                Metric(id: "search.facets.p95", label: "Search facets (p95)", unit: "ms",
                       value: percentile(facets, 0.95), budget: 100, noiseFloor: 3, gated: true),
                Metric(id: "search.contact.p95", label: "Search person card (p95)", unit: "ms",
                       value: percentile(contact, 0.95), budget: nil, noiseFloor: 5, gated: true),
                Metric(id: "open.cached.p95", label: "Open cached message (p95)", unit: "ms",
                       value: percentile(open, 0.95), budget: 50, noiseFloor: 1, gated: true),
                Metric(id: "memory.peak", label: "Peak memory", unit: "MB",
                       value: peakResidentMB(), budget: 300, noiseFloor: 8, gated: true),
                Metric(id: "store.size", label: "Store on disk", unit: "MB",
                       value: Double(size) / 1_048_576, budget: nil, noiseFloor: 0, gated: false),
            ]
        )
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    static func percentile(_ samples: [Double], _ p: Double) -> Double {
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    static func peakResidentMB() -> Double {
        var usage = rusage()
        #if os(Linux)
        getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage)
        #else
        getrusage(RUSAGE_SELF, &usage)
        #endif
        #if canImport(Darwin)
        return Double(usage.ru_maxrss) / 1_048_576   // bytes
        #else
        return Double(usage.ru_maxrss) / 1_024       // kilobytes
        #endif
    }

    static var cpuModel: String? {
        #if os(Linux)
        guard let info = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8) else { return nil }
        let line = info.split(separator: "\n").first { $0.hasPrefix("model name") }
        return line?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        #else
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #endif
    }

    static var platform: String {
        #if os(Linux)
        let os = "Linux"
        #else
        let os = "macOS"
        #endif
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "\(os) \(arch), \(ProcessInfo.processInfo.activeProcessorCount) cores"
    }
}
