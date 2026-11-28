import Foundation

/// The verdict on one run: over budget, or slower than the baseline by more than the tolerance
/// (and by more than the metric's noise floor, so a 0.2 ms wobble on a 3 ms query isn't a failure).
struct Report {
    var current: BenchResults
    var baseline: BenchResults?
    var tolerance: Double

    var failures: [String] { budgetFailures + regressions }

    var budgetFailures: [String] {
        current.metrics.compactMap { metric in
            if case .overBudget = verdict(metric) { "\(metric.label) is over budget" } else { nil }
        }
    }

    var regressions: [String] {
        current.metrics.compactMap { metric in
            if case .regressed(let change) = verdict(metric) {
                String(format: "%@ is %.0f%% slower than main", metric.label, change * 100)
            } else { nil }
        }
    }

    enum Verdict { case ok, overBudget, regressed(Double), slowerElsewhere, info }

    /// Timings from another processor model aren't comparable: a slowdown is shown, not failed.
    var sameMachine: Bool { baseline?.cpu != nil && baseline?.cpu == current.cpu }

    func verdict(_ metric: Metric) -> Verdict {
        if let budget = metric.budget, metric.value >= budget { return .overBudget }
        if metric.gated, let base = baselineValue(metric), base > 0 {
            let change = metric.value / base - 1
            if change > tolerance, metric.value - base > metric.noiseFloor {
                return sameMachine ? .regressed(change) : .slowerElsewhere
            }
        }
        return metric.gated ? .ok : .info
    }

    func baselineValue(_ metric: Metric) -> Double? {
        // A baseline from a different mailbox size isn't comparable.
        guard let baseline, baseline.messages == current.messages else { return nil }
        return baseline.metrics.first { $0.id == metric.id }?.value
    }

    var markdown: String {
        var lines = [
            "### Performance budgets (SPEC §15)",
            "",
            "\(current.messages) synthetic messages · \(current.platform)" + (current.cpu.map { " · \($0)" } ?? "") + baselineNote,
            "",
            "| Metric | This run | Budget | main | Change | |",
            "|---|---:|---:|---:|---:|---|",
        ]
        for metric in current.metrics {
            let base = baselineValue(metric)
            let change = base.flatMap { $0 > 0 ? String(format: "%+.0f%%", (metric.value / $0 - 1) * 100) : nil } ?? "—"
            let mark: String = switch verdict(metric) {
            case .ok: "✅"
            case .overBudget: "❌ over budget"
            case .regressed: "❌ regression"
            case .slowerElsewhere: "⚠️ slower (other CPU, not gated)"
            case .info: ""
            }
            lines.append("| \(metric.label) | \(format(metric.value, metric.unit)) | \(metric.budgetText) | \(base.map { format($0, metric.unit) } ?? "—") | \(change) | \(mark) |")
        }
        return lines.joined(separator: "\n")
    }

    var baselineNote: String {
        guard let baseline else { return " · no baseline from main yet" }
        guard baseline.messages == current.messages else { return " · baseline has a different mailbox size; not compared" }
        return " · compared with main" + (baseline.commit.map { " at `\($0.prefix(7))`" } ?? "")
            + (sameMachine ? "" : " (on another CPU: \(baseline.cpu ?? "unknown"); slowdowns not gated)")
    }

    func format(_ value: Double, _ unit: String) -> String {
        String(format: value < 10 ? "%.2f %@" : "%.1f %@", value, unit)
    }
}
