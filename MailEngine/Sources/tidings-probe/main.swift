import ArgumentParser
import Foundation
import MailEngine
#if canImport(Darwin)
import Security
#endif

@main
struct TidingsProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tidings-probe",
        abstract: "M0 live checks for the Tidings mail engine.",
        discussion: """
            Live iCloud commands read the app-specific password from your Keychain. Store it once with:
              security add-generic-password -s Tidings -a you@icloud.com -w
            (you'll be prompted; the password never appears on screen or in shell history).
            """,
        subcommands: [Greeting.self, KeychainCheck.self, Capabilities.self, KeywordTestCommand.self, AICheck.self, BenchSearch.self, SeedTestServer.self]
    )
}

// MARK: - Shared options

struct ServerOptions: ParsableArguments {
    @Option(help: "Account address (also the Keychain account name).")
    var address: String

    @Option(help: "IMAP login name, if different from --address (e.g. just the part before @ for iCloud).")
    var login: String?

    @Option(help: "IMAP host. Defaults to iCloud.")
    var host: String = "imap.mail.me.com"

    @Option(help: "IMAP port.")
    var port: UInt16 = 993

    @Flag(help: "Disable TLS (local test server only).")
    var plaintext = false

    @Option(help: "Password for a local test server. Never use for real accounts; those come from Keychain.")
    var testPassword: String?

    @Flag(name: .customLong("simulate-icloud"), help: "Hide MOVE/SPECIAL-USE etc. to exercise iCloud code paths on another server.")
    var simulateICloud = false

    @Option(help: "Sign-in method: login (IMAP LOGIN, the app's default) or plain (AUTHENTICATE PLAIN, with SASL-IR when offered).")
    var auth: String = "login"

    @Flag(help: "Type the password at a hidden prompt instead of reading it from the Keychain. Nothing is stored or shown.")
    var askPassword = false

    @Flag(help: "Print sanitized connection and sign-in diagnostics (never the password).")
    var verbose = false

    var authMethod: IMAPAuthMethod {
        get throws {
            guard let method = IMAPAuthMethod(rawValue: auth.lowercased()) else { throw ValidationError("--auth must be login or plain") }
            return method
        }
    }

    func startDiagnostics() {
        guard verbose else { return }
        IMAPDiagnostics.echo = { line in FileHandle.standardError.write(Data("[imap] \(line)\n".utf8)) }
    }

    var endpoint: IMAPEndpoint {
        IMAPEndpoint(host: host, port: port, useTLS: !plaintext, username: login ?? address)
    }

    var profile: ServerProfile? { simulateICloud ? .iCloudSimulation : nil }

    func password() throws -> String {
        if askPassword {
            #if canImport(Darwin)
            var buffer = [CChar](repeating: 0, count: 1024)
            guard let read = readpassphrase("Password for \(login ?? address) (hidden): ", &buffer, buffer.count, 0) else {
                throw ValidationError("No password entered.")
            }
            let typed = String(cString: read)
            buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            return typed
            #else
            guard let typed = getpass("Password for \(login ?? address) (hidden): ").map({ String(cString: $0) }) else {
                throw ValidationError("No password entered.")
            }
            return typed
            #endif
        }
        if let testPassword {
            guard host == "127.0.0.1" || host == "localhost" else {
                throw ValidationError("--test-password is only allowed for localhost. Use the Keychain for real accounts.")
            }
            return testPassword
        }
        return try Keychain.password(service: Keychain.service, account: address)
    }
}

enum Keychain {
    /// The service the owner stores the app-specific password under (see `--help`).
    static let service = "Tidings"

    static func password(service: String, account: String) throws -> String {
        #if !canImport(Darwin)
        // No Keychain on Linux (ADR 0007): the password comes from the environment.
        guard let password = ProcessInfo.processInfo.environment["TIDINGS_PASSWORD"], !password.isEmpty else {
            throw ValidationError("No Keychain on this platform: set TIDINGS_PASSWORD.")
        }
        return password
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw ValidationError("""
                No Keychain item for service '\(service)', account '\(account)' (OSStatus \(status)).
                Create one with: security add-generic-password -s \(service) -a \(account) -w
                """)
        }
        return password
        #endif
    }
}

// MARK: - Commands

struct KeychainCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keychain-check",
        abstract: "Check the stored password's shape without revealing it, and without logging in."
    )
    @Option(help: "Keychain account name used when saving the password.") var address: String

    func run() async throws {
        let password = try Keychain.password(service: Keychain.service, account: address)
        let appSpecific = password.range(of: #"^[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}$"#, options: .regularExpression) != nil
        let undashed = password.range(of: #"^[a-z]{16}$"#, options: .regularExpression) != nil
        print("Keychain item found for '\(address)'.")
        print("  length: \(password.count) characters (an app-specific password is 19: xxxx-xxxx-xxxx-xxxx)")
        print("  matches app-specific format: \(appSpecific ? "yes" : undashed ? "yes, but without dashes" : "NO")")
        print("  contains whitespace: \(password.contains(where: \.isWhitespace) ? "YES, remove it" : "no")")
        print("  contains uppercase or digits: \(password.contains(where: { $0.isUppercase || $0.isNumber }) ? "yes (app-specific passwords are lowercase letters only)" : "no")")
    }
}

struct Greeting: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the pre-login capability list (no credentials needed).")

    @Option var host: String = "imap.mail.me.com"
    @Option var port: UInt16 = 993
    @Flag var plaintext = false

    func run() async throws {
        let caps = try await MailSession.probeGreeting(
            endpoint: IMAPEndpoint(host: host, port: port, useTLS: !plaintext, username: "")
        )
        print(caps.joined(separator: " "))
    }
}

struct Capabilities: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Log in (read-only) and report capabilities, ENABLE result, mailboxes and their detected roles."
    )
    @OptionGroup var server: ServerOptions

    func run() async throws {
        server.startDiagnostics()
        let password = try server.password()
        try await MailSession.open(endpoint: server.endpoint, password: password, profile: server.profile, auth: server.authMethod) { session in
            print("Pre-login capabilities:\n  \(session.greetingCapabilities.joined(separator: " "))")
            print("Post-login capabilities:\n  \(session.capabilities.joined(separator: " "))")
            print("CONDSTORE/QRESYNC enabled: \(session.qresyncEnabled)")
            for cap in ["IDLE", "CONDSTORE", "QRESYNC", "MOVE", "UIDPLUS", "SPECIAL-USE", "ESEARCH", "LIST-STATUS", "COMPRESS=DEFLATE", "NOTIFY"] {
                print(String(format: "  %-18@ %@", cap as NSString, session.supports(cap) ? "yes" : "no"))
            }
            let boxes = try await session.listMailboxes()
            let roles = MailboxRoleResolver.resolve(boxes)
            print("\nMailboxes (\(boxes.count)):")
            for box in boxes {
                let role = roles.first { $0.value == box.path }?.key.rawValue ?? ""
                print("  \(box.path)  \(box.attributes.joined(separator: " "))  \(role.isEmpty ? "" : "→ \(role)")")
            }
            let inbox = try await session.select("INBOX", readOnly: true)
            print("\nINBOX (EXAMINE, read-only): exists=\(inbox.exists) uidValidity=\(inbox.uidValidity.map(String.init) ?? "-") highestModSeq=\(inbox.highestModSeq.map(String.init) ?? "-")")
            print("PERMANENTFLAGS: \(inbox.permanentFlags.joined(separator: " "))")

            // Read-only: what incremental sync will ask this server (no bodies, nothing changed).
            print("\nIncremental sync: \(session.resyncMode)")
            if let modSeq = inbox.highestModSeq, session.resyncMode != .none {
                let since = modSeq > 200 ? modSeq - 200 : 1
                let vanished = session.resyncMode == .qresync
                do {
                    let start = ContinuousClock.now
                    let changes = try await session.fetchChanges(since: since, vanished: vanished)
                    let gone = changes.vanished.map { " vanished \($0.count) UIDs in \($0.ranges.count) ranges" } ?? ""
                    print("  UID FETCH 1:* (CHANGEDSINCE \(since)\(vanished ? " VANISHED" : "")): \(changes.summaries.count) changed,\(gone) in \(ContinuousClock.now - start)")
                } catch {
                    print("  UID FETCH CHANGEDSINCE\(vanished ? " VANISHED" : ""): FAILED \(error)")
                }
                do {
                    let start = ContinuousClock.now
                    let uids = try await session.allUIDs()
                    print("  UID SEARCH\(session.supports("ESEARCH") ? " RETURN (ALL)" : "") ALL: \(uids.count) UIDs in \(uids.ranges.count) ranges (EXISTS \(inbox.exists)) in \(ContinuousClock.now - start)")
                } catch {
                    print("  UID SEARCH ALL: FAILED \(error)")
                }
            }
        }
    }
}

struct KeywordTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keyword-test",
        abstract: "Fenced test: do custom IMAP keywords persist? Only touches messages it creates inside 'Tidings-Test'."
    )
    @OptionGroup var server: ServerOptions
    @Flag(help: "Print the report as JSON.") var json = false

    func run() async throws {
        let test = KeywordTest(endpoint: server.endpoint, password: try server.password(), profile: server.profile)
        let report = try await test.run { line in print(line) }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        }
        print(report.passed ? "\nRESULT: keywords are usable on \(report.server)" : "\nRESULT: keywords are NOT reliable on \(report.server)")
    }
}

struct AICheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ai-check",
        abstract: "Check Foundation Models and embedding availability for Danish/English; optionally classify samples."
    )
    @Flag(help: "Also run a few sample classifications on-device.") var generate = false

    func run() async throws {
        let report = await OnDeviceAICheck.run(generate: generate)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}

struct BenchSearch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench-search",
        abstract: "Build a synthetic mailbox and measure as-you-type search latency against the 30 ms p95 budget."
    )
    /// SPEC §15 budgets, in milliseconds at p95.
    static let hitsBudget = 30.0
    static let facetsBudget = 100.0

    @Option(help: "Number of synthetic messages.") var count = 250_000
    @Option(help: "Database path (default: a temp file).") var database: String?

    func run() async throws {
        let path = database ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("tidings-bench-\(count).sqlite").path
        let store = try MailStore(path: path)
        let existing = try store.count()
        if existing < count {
            print("Generating \(count - existing) synthetic messages into \(path)…")
            let clock = ContinuousClock()
            let start = clock.now
            let all = SyntheticCorpus().messages(count: count)
            let batchSize = 5_000
            for chunk in stride(from: existing, to: count, by: batchSize) {
                try store.upsert(Array(all[chunk..<min(chunk + batchSize, count)]))
            }
            print("Indexed in \(clock.now - start)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        print("Store: \(try store.count()) messages, \(size >> 20) MB on disk")

        let engine = SearchEngine(store: store)
        let typed = ["f", "fa", "fak", "fakt", "faktu", "faktura", "faktura z", "faktura za",
                     "s", "sk", "sko", "sko from:zalando", "m", "mø", "møde", "møde projekt",
                     "invoice after:2024-01-01", "category:advertising", "has:attachment kontrakt",
                     "from:anna", "\"din pakke\"", "security -password"]
        _ = try engine.hits(SearchQuery(parsing: "warmup"))
        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        var hitSamples: [Double] = []
        var facetSamples: [Double] = []
        for round in 0..<5 {
            for text in typed {
                let q = SearchQuery(parsing: text)
                let h = try engine.hits(q)
                let f = q.wantsFacets ? try engine.facets(q) : nil
                hitSamples.append(ms(h.duration))
                if let f { facetSamples.append(ms(f.duration)) }
                if round == 0 {
                    print(String(format: "%-28@ hits %6.2f ms   facets %7@  %7@ matches  top: %@",
                                 "\"\(text)\"" as NSString, ms(h.duration),
                                 (f.map { String(format: "%.2f ms", ms($0.duration)) } ?? "skipped") as NSString,
                                 (f.map { String($0.total) } ?? "-") as NSString,
                                 (h.hits.first?.subject ?? "-") as NSString))
                }
            }
        }
        func stats(_ s: [Double]) -> (Double, Double, Double) {
            let x = s.sorted()
            return (x[x.count / 2], x[Int(Double(x.count) * 0.95)], x.last!)
        }
        let (h50, h95, hMax) = stats(hitSamples)
        let (f50, f95, fMax) = stats(facetSamples)
        print(String(format: "\nHits   (phase 1) — p50 %.2f ms, p95 %.2f ms, max %.2f ms  budget p95 < %.0f ms  %@",
                     h50, h95, hMax, Self.hitsBudget, h95 < Self.hitsBudget ? "✓" : "✗ OVER"))
        print(String(format: "Facets (phase 2) — p50 %.2f ms, p95 %.2f ms, max %.2f ms  budget p95 < %.0f ms %@",
                     f50, f95, fMax, Self.facetsBudget, f95 < Self.facetsBudget ? "✓" : "✗ OVER"))
    }
}

struct SeedTestServer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seed-test-server",
        abstract: "Fill the LOCAL Dovecot test server with realistic Danish/English mail. Refuses any other host."
    )
    @Option(help: "Test-server user (any name works on the local Dovecot).") var user = "magnus"
    @Option var port: UInt16 = 31143
    @Flag(help: "Also add mail that mentions plans (dinner, a webinar, a table booking) for calendar suggestions.")
    var datePlans = false
    @Flag(help: "Seed the second test account's mail (magnus@work.test) instead, for trying two accounts.")
    var work = false

    func run() async throws {
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: port, useTLS: false, username: user)
        let count = try await TestServerSeeder.seed(endpoint: endpoint, password: "tidings-test", datePlans: datePlans, work: work)
        print("Seeded \(count) messages for user '\(user)' on 127.0.0.1:\(port).")
    }
}
