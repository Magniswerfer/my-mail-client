import Foundation
import Testing
@testable import MailEngine

@Suite struct HighlightTrainingTests {
    let receipt = """
        Tak for din ordre hos Cykelbutikken
        Varer: 2 stk.
        Fragt: 49,00 kr.
        Beløb i alt: 1.249,00 kr.
        Heraf moms 249,80 kr.
        """

    @Test func candidatesCarryTheirLabels() {
        let found = HighlightExtractor.candidates(.amount, subject: "Ordrebekræftelse", text: receipt)
        #expect(found.map(\.value) == ["49,00 kr.", "1.249,00 kr.", "249,80 kr."])
        #expect(found.map(\.label) == ["Fragt", "Beløb i alt", "Heraf moms"])

        let codes = HighlightExtractor.candidates(.code, subject: "Din kode", text: "Hej\nDin engangskode\n483 920\nOrdre AB12CD")
        #expect(codes.map(\.value) == ["483920", "AB12CD"])
        #expect(codes.first?.label == "Din engangskode")
    }

    @Test func aLearnedLabelPicksTheValue() {
        // The heuristic takes the "i alt" line; this sender's total is on "Heraf moms" (say).
        var training = HighlightTraining()
        training.set(.init(sender: "Shop@Example.dk", field: .amount, label: "Heraf moms"))
        let found = [Highlight(kind: .receipt, title: "Shop", value: "1.249,00 kr.")]
        let applied = training.apply(to: found, sender: "shop@example.dk", senderName: "Shop", text: receipt)
        #expect(applied.map(\.value) == ["249,80 kr."])

        // And adds one when nothing was found: the value can sit on the line under its label.
        training.set(.init(sender: "bank@example.dk", field: .code, label: "Din engangskode"))
        let added = training.apply(to: [], sender: "bank@example.dk", senderName: "Banken",
                                   text: "Hej\nDin engangskode\n483 920\n")
        #expect(added.first?.kind == .code)
        #expect(added.first?.value == "483920")
    }

    @Test func neverFromASenderHidesThatKindOnly() {
        var training = HighlightTraining()
        training.set(.init(sender: "news@example.dk", field: .amount, suppressed: true))
        let found = [Highlight(kind: .receipt, title: "N", value: "10 kr."), Highlight(kind: .code, title: "N", value: "123456")]
        let applied = training.apply(to: found, sender: "NEWS@example.dk", senderName: "N", text: "")
        #expect(applied.map(\.kind) == [.code])
        #expect(!training.shows(.bill, from: "news@example.dk"))
        #expect(training.shows(.code, from: "news@example.dk"))
        #expect(training.shows(.receipt, from: "other@example.dk"))
    }

    @Test func trainingIsStoredAndSynced() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-hl-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        var training = HighlightTraining()
        training.set(.init(sender: "a@b.dk", field: .code, label: "Kode"))
        try store.saveHighlightTraining(training)
        #expect(try store.highlightTraining() == training)
        let snapshot = try store.cloudSnapshot(accounts: CloudAccounts([]), settings: [:])
        #expect(snapshot[StateRecordType.highlightTraining.rawValue]?["training"] != nil)
    }
}
