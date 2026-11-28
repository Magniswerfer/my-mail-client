import ArgumentParser
import Foundation

/// The performance budgets of SPEC §15, measured on a synthetic mailbox and checked in CI.
///
///     tidings-bench seed    --dir D             # build a 250k-message store and a body cache
///     tidings-bench run     --dir D --out r.json  # measure, in a fresh process
///     tidings-bench compare --current r.json [--baseline b.json]
///
/// `compare` fails (exit 1) when a metric is over its budget, or more than 10% slower than the
/// baseline (the last run on main). See `docs/performance.md`.
@main
struct TidingsBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tidings-bench",
        abstract: "Measure the engine against the SPEC §15 performance budgets.",
        subcommands: [Seed.self, Run.self, Compare.self]
    )
}

struct Seed: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build the synthetic mailbox (store + cached bodies) in a directory."
    )
    @Option(help: "Number of synthetic messages.") var count = 250_000
    @Option(help: "Directory for the store and the cache (created; must not hold a store yet).") var dir: String

    func run() async throws {
        let start = ContinuousClock.now
        let summary = try Workload.seed(count: count, directory: URL(fileURLWithPath: dir))
        print("Seeded \(summary.messages) messages (\(summary.inbox) in the Inbox, \(summary.cached) cached bodies) in \(ContinuousClock.now - start)")
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Measure every budgeted metric on a seeded directory and write the results as JSON."
    )
    @Option(help: "A directory made by `seed`.") var dir: String
    @Option(help: "Where to write the results (JSON).") var out: String
    @Option(help: "Rounds over the typed search queries in each pass.") var rounds = 10
    @Option(help: "Passes over everything; each metric reports its median pass.") var repeats = 5

    func run() async throws {
        let results = try Measure.all(directory: URL(fileURLWithPath: dir), rounds: rounds, repeats: repeats)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: out))
        for metric in results.metrics {
            print(String(format: "%-34@ %10.2f %@   budget %@", metric.label as NSString, metric.value,
                         metric.unit as NSString, metric.budgetText as NSString))
        }
    }
}

struct Compare: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check results against the budgets and a baseline; exit 1 on a failure."
    )
    @Option(help: "Results of this run.") var current: String
    @Option(help: "Results to compare with (the last run on main). Skipped when absent.") var baseline: String?
    @Option(help: "Allowed slowdown against the baseline, in percent.") var tolerance = 10.0
    @Option(help: "Also append the report (Markdown) to this file, e.g. $GITHUB_STEP_SUMMARY.") var summary: String?
    @Flag(help: "Report slowdowns against the baseline as warnings only; budgets still fail. For shared CI runners, where two VMs with the same CPU can differ by more than the tolerance.")
    var warnOnRegression = false

    func run() throws {
        let decoder = JSONDecoder()
        let now = try decoder.decode(BenchResults.self, from: Data(contentsOf: URL(fileURLWithPath: current)))
        var base: BenchResults?
        if let baseline, FileManager.default.fileExists(atPath: baseline) {
            base = try decoder.decode(BenchResults.self, from: Data(contentsOf: URL(fileURLWithPath: baseline)))
        }
        let report = Report(current: now, baseline: base, tolerance: tolerance / 100)
        print(report.markdown)
        if let summary, let handle = FileHandle(forWritingAtPath: summary) {
            handle.seekToEndOfFile()
            handle.write(Data((report.markdown + "\n").utf8))
            try? handle.close()
        }
        if warnOnRegression {
            for warning in report.regressions { print("::warning::\(warning)") }
        }
        let failures = warnOnRegression ? report.budgetFailures : report.failures
        if !failures.isEmpty {
            print("\nFailed: " + failures.joined(separator: "; "))
            throw ExitCode.failure
        }
    }
}
