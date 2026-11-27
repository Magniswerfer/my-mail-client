import Foundation
import MailEngine

/// "Wrong value…" / "Find Code…" / "Find Amount…": a message and the field to pick in it.
struct HighlightPick: Identifiable {
    let id = UUID()
    let message: StoredMessage
    let field: HighlightTraining.Field
}

/// Teaching the highlights (codes, amounts on receipts and bills), both ways: "not this one",
/// "never from this sender", and "this is the value", which remembers the label in front of it
/// for the sender's next mail. Synced with your other state.
extension AppModel {
    /// A message's highlights as shown: minus what you've said never to show from its sender.
    func visibleHighlights(of message: StoredMessage) -> [Highlight] {
        (message.highlights ?? []).filter { highlightTraining.shows($0.kind, from: message.fromAddress) }
    }

    /// "Not Useful Here": gone from this message only.
    func hideHighlight(_ highlight: Highlight, on message: StoredMessage) {
        guard let id = message.id else { return }
        let before = message.highlights
        try? store.setHighlights((before ?? []).filter { $0 != highlight }, messageID: id)
        reload()
        let undo = offerUndo(named: String(localized: "Hide")) { [weak self] in
            try? self?.store.setHighlights(before, messageID: id)
            self?.toast = nil
            self?.reload()
        }
        show(Toast(message: String(localized: "Hidden on this message"), symbol: "eye.slash", undo: undo))
    }

    /// "Never from Shop": this kind of highlight isn't shown from the sender again.
    func neverShowHighlight(_ field: HighlightTraining.Field, from message: StoredMessage) {
        let before = highlightTraining
        var training = highlightTraining
        training.set(.init(sender: message.fromAddress, field: field, suppressed: true))
        saveTraining(training)
        let undo = offerUndo(named: String(localized: "Hide")) { [weak self] in
            self?.saveTraining(before)
            self?.toast = nil
        }
        let what = field == .code ? String(localized: "No more codes from \(message.senderDisplay)")
                                  : String(localized: "No more amounts from \(message.senderDisplay)")
        show(Toast(message: what, symbol: "eye.slash", undo: undo))
    }

    /// "This is the value": shown on this message, and learned for the sender by its label.
    func useHighlightValue(_ candidate: HighlightCandidate, field: HighlightTraining.Field, on message: StoredMessage) {
        guard let id = message.id else { return }
        let beforeTraining = highlightTraining
        let beforeHighlights = message.highlights
        var training = highlightTraining
        training.set(.init(sender: message.fromAddress, field: field, label: candidate.label.isEmpty ? nil : candidate.label))
        saveTraining(training)
        var highlights = message.highlights ?? []
        if let i = highlights.firstIndex(where: { $0.kind.field == field }) {
            highlights[i].value = candidate.value
        } else {
            highlights.append(Highlight(kind: field == .code ? .code : .receipt, title: message.senderDisplay, value: candidate.value))
        }
        try? store.setHighlights(highlights, messageID: id)
        highlightPick = nil
        reload()
        let undo = offerUndo(named: String(localized: "Use Value")) { [weak self] in
            self?.saveTraining(beforeTraining)
            try? self?.store.setHighlights(beforeHighlights, messageID: id)
            self?.toast = nil
            self?.reload()
        }
        let message = candidate.label.isEmpty
            ? String(localized: "Using \(candidate.value)")
            : String(localized: "Using \(candidate.value); next time after “\(candidate.label)”")
        show(Toast(message: message, symbol: "checkmark.circle", undo: undo))
    }

    /// Forgets one thing you taught (Settings).
    func forgetHighlightRule(_ rule: HighlightTraining.Rule) {
        var training = highlightTraining
        training.remove(sender: rule.sender, field: rule.field)
        saveTraining(training)
    }

    /// The values in a message that could be its code or amount.
    func highlightCandidates(_ field: HighlightTraining.Field, in message: StoredMessage) async -> [HighlightCandidate] {
        guard let raw = try? await rawMessage(message) else { return [] }
        let parsed = MIMEParser.parse(raw)
        return HighlightExtractor.candidates(field, subject: parsed.subject, text: parsed.plainText)
    }

    /// ⌘K "Find Code…" / "Find Amount…" on the newest message of the selected conversation.
    func pickHighlight(_ field: HighlightTraining.Field) {
        guard let thread = targetThreads.first, let message = readerMessages(inThread: thread.threadID).last else { return }
        highlightPick = HighlightPick(message: message, field: field)
    }

    /// ⌘K "Stop Codes and Amounts from This Sender".
    func neverShowHighlightsFromSelected() {
        guard let thread = targetThreads.first, let message = readerMessages(inThread: thread.threadID).last else { return }
        let fields = Set(visibleHighlights(of: message).compactMap(\.kind.field))
        for field in fields.isEmpty ? Set(HighlightTraining.Field.allCases) : fields { neverShowHighlight(field, from: message) }
    }

    private func saveTraining(_ training: HighlightTraining) {
        highlightTraining = training
        try? store.saveHighlightTraining(training)
        scheduleCloudPush()
        reload()
    }
}
