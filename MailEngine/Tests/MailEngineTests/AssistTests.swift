import Foundation
import Testing
@testable import MailEngine

private let me = "magnus@example.dk"

private func store() throws -> MailStore {
    try MailStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("tidings-assist-\(UUID()).sqlite").path)
}

private func message(_ uid: UInt32, thread: String, from: String, name: String? = nil, to: String,
                     daysAgo: Double, mailbox: String = "INBOX", subject: String = "Tilbud") -> StoredMessage {
    StoredMessage(accountID: "a", mailbox: mailbox, uid: uid, messageID: "m\(uid)@x", threadID: thread, subject: subject,
                  fromName: name, fromAddress: from, recipients: to, date: Date().addingTimeInterval(-daysAgo * 86_400))
}

@Suite struct ThreadDigestTests {
    @Test func ownWordsOnlyAndNewestKeptWhole() {
        let quoted = "Sounds good, Tuesday works.\n\nOn Mon, Anna wrote:\n> Shall we meet Tuesday?\n> Best"
        var a = message(1, thread: "t", from: "anna@firma.dk", name: "Anna", to: me, daysAgo: 2)
        a.bodyText = TextCompression.compress(String(repeating: "Lang historik. ", count: 600))
        var b = message(2, thread: "t", from: me, to: "anna@firma.dk", daysAgo: 1)
        b.bodyText = TextCompression.compress(quoted)
        let digest = ThreadDigest(subject: "Møde", messages: [b, a], ownAddresses: [me])
        #expect(digest.entries.map(\.sender) == ["Anna", me], "oldest first")
        #expect(digest.entries[1].text == "Sounds good, Tuesday works.", "quotes and attribution dropped")
        #expect(digest.entries[1].isMine)
        #expect(digest.entries.reduce(0) { $0 + $1.text.count } <= ThreadDigest.characterBudget + 2)
        #expect(digest.entries[0].text.hasSuffix("…"), "the oldest message is the one shortened")
        #expect(digest.prompt.contains("--- Me, "))
        #expect(digest.isWorthSummarizing)
        #expect(!ThreadDigest(subject: "x", messages: [b], ownAddresses: [me]).isWorthSummarizing, "a short single message needs no summary")
    }
}

@Suite struct AutoDraftTests {
    @Test func candidatesAreYourUnansweredMailToPeople() throws {
        let s = try store()
        var waiting = message(1, thread: "waiting", from: me, to: "Anna <anna@firma.dk>", daysAgo: 4, mailbox: "Sent Messages")
        waiting.bodyText = TextCompression.compress("Hej Anna, kan du sende tilbuddet inden fredag? Så kan vi komme videre.")
        var answered = message(2, thread: "answered", from: me, to: "bo@firma.dk", daysAgo: 5, mailbox: "Sent Messages")
        answered.bodyText = TextCompression.compress("Hvad siger du til planen for næste uge, Bo? Giv lyd.")
        let reply = message(3, thread: "answered", from: "bo@firma.dk", to: me, daysAgo: 4)
        var tooNew = message(4, thread: "new", from: me, to: "cy@firma.dk", daysAgo: 1, mailbox: "Sent Messages")
        tooNew.bodyText = waiting.bodyText
        var thanks = message(5, thread: "thanks", from: me, to: "di@firma.dk", daysAgo: 4, mailbox: "Sent Messages")
        thanks.bodyText = TextCompression.compress("Tak!")
        var robot = message(6, thread: "robot", from: me, to: "noreply@shop.dk", daysAgo: 4, mailbox: "Sent Messages")
        robot.bodyText = waiting.bodyText
        try s.upsert([waiting, answered, reply, tooNew, thanks, robot].map { ($0, $0.plainText ?? "") })

        let found = try s.followUpCandidates(accountID: "a", ownAddresses: [me])
        #expect(found.map(\.threadID) == ["waiting"])

        try s.saveAutoDraft(AutoDraft(threadID: "waiting", accountID: "a", outboxID: nil, messageID: found[0].id!))
        #expect(try s.followUpCandidates(accountID: "a", ownAddresses: [me]).isEmpty, "never drafted twice")
    }

    @Test func aReplyRetiresTheDraftAndDismissingSticks() throws {
        let s = try store()
        var mine = message(1, thread: "t", from: me, to: "anna@firma.dk", daysAgo: 4, mailbox: "Sent Messages")
        mine.bodyText = TextCompression.compress("Kan du nå at kigge på kontrakten i denne uge?")
        try s.upsert([(mine, mine.plainText!)])
        let stored = try #require(try s.messages(inThread: "t").first)
        let item = try s.save(OutboxItem(accountID: "a", message: OutgoingMessage(from: MailAddress(name: nil, address: me),
                                                                                 to: [MailAddress(name: nil, address: "anna@firma.dk")],
                                                                                 subject: "Re: Tilbud", text: "Følger lige op"),
                                         state: .draft, kind: .reply, originalLocalID: stored.id))
        try s.saveAutoDraft(AutoDraft(threadID: "t", accountID: "a", outboxID: item.id, messageID: stored.id!))
        #expect(try s.pendingAutoDrafts().count == 1)

        let answer = message(2, thread: "t", from: "anna@firma.dk", to: me, daysAgo: 1)
        try s.upsert([(answer, "Ja, i morgen.")])
        #expect(try s.retireAnsweredAutoDrafts() == 1)
        #expect(try s.pendingAutoDrafts().isEmpty)
        #expect(try s.outboxItem(id: item.id!) == nil, "the stale draft is deleted")
        #expect(try s.autoDraft(threadID: "t")?.dismissed == true)
    }
}

@Suite struct ContactProfileTests {
    @Test func historyColleaguesSignatureAndReplyTime() throws {
        let s = try store()
        var fromAnna = message(2, thread: "t1", from: "anna@firma.dk", name: "Anna Holm", to: me, daysAgo: 9.5)
        fromAnna.bodyText = TextCompression.compress("""
            Det lyder godt.

            Venlig hilsen
            Anna Holm · Projektleder
            +45 12 34 56 78
            www.firma.dk · linkedin.com/in/annaholm
            """)
        try s.upsert([
            (message(1, thread: "t1", from: me, to: "Anna Holm <anna@firma.dk>", daysAgo: 10), "Spørgsmål"),
            (fromAnna, fromAnna.plainText!),
            (message(3, thread: "t2", from: me, to: "anna@firma.dk", daysAgo: 5), "Opfølgning"),
            (message(4, thread: "t2", from: "anna@firma.dk", to: me, daysAgo: 4.5), "Svar"),
            (message(5, thread: "t3", from: me, to: "anna@firma.dk", daysAgo: 2), "Igen"),
            (message(6, thread: "t3", from: "anna@firma.dk", to: me, daysAgo: 1.5), "Svar igen"),
            (message(7, thread: "t9", from: "bo@firma.dk", name: "Bo", to: me, daysAgo: 3), "Kollega"),
            (message(8, thread: "t8", from: "noreply@firma.dk", to: me, daysAgo: 3), "Robot"),
        ])
        let p = try s.contactProfile(address: "Anna@Firma.dk", ownAddresses: [me])
        #expect(p.name == "Anna Holm")
        #expect(p.received == 3 && p.sent == 3)
        #expect(p.recent.map(\.threadID) == ["t3", "t2", "t1"])
        #expect(p.recent.allSatisfy { $0.fromThem })
        #expect(p.colleagues.map(\.address) == ["bo@firma.dk"], "robots left out")
        #expect(p.isOrganisation)
        #expect(p.typicalReplyHours.map { abs($0 - 12) < 0.5 } == true, "median of 12 h answers")
        #expect(p.signature.phones == ["+45 12 34 56 78"])
        #expect(p.signature.links.map(\.kind) == [.website, .linkedIn])
        #expect(p.signature.links.last?.label == "annaholm")
    }

    @Test func signatureIgnoresQuotedTextAndDates() {
        let info = SignatureInfo.extract(from: """
            Mvh Bo
            github.com/bo-dev · https://bsky.app/profile/bo.dk
            Mødet er 24.11.2026, ordre 2026112400

            On Mon, Anna wrote:
            > https://www.linkedin.com/in/anna
            """)
        #expect(info.links.map(\.kind) == [.bluesky, .github])
        #expect(info.phones == ["2026112400"] || info.phones.isEmpty, "dates with dots never count")
    }
}

@Suite struct AvailabilityTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        c.firstWeekday = 2
        return c
    }

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func workingHoursMinusMeetingsSnappedToQuarters() {
        // Tuesday 24 Nov 2026, 08:10. Meetings 10:00–11:20 and 13:00–16:50.
        let busy = [DateInterval(start: at(24, 10), end: at(24, 11, 20)), DateInterval(start: at(24, 13), end: at(24, 16, 50))]
        var options = Availability.Options()
        options.days = 1
        let slots = Availability.freeSlots(busy: busy, from: at(24, 8, 10), calendar: calendar, options: options)
        #expect(slots.map { [$0.start, $0.end] } == [[at(24, 9, 15), at(24, 10)], [at(24, 11, 30), at(24, 13)]],
                "lead time rounds 09:10 up to 09:15; 16:50–17:00 is too short")
    }

    @Test func weekendsSkippedAndDaysCounted() {
        var options = Availability.Options()
        options.days = 2
        // Friday 27 Nov 18:00 → Monday 30 and Tuesday 1 Dec, whole days.
        let slots = Availability.freeSlots(busy: [], from: at(27, 18), calendar: calendar, options: options)
        #expect(slots.map { calendar.component(.day, from: $0.start) } == [30, 1])
        #expect(slots.first.map { calendar.component(.hour, from: $0.start) } == 9)
    }
}

@Suite struct IntroReplyTests {
    func parsed(_ raw: String) -> ParsedMessage { MIMEParser.parse(Data(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8)) }

    @Test func introducerMovesToBcc() throws {
        let m = parsed("""
            From: Anna Holm <anna@firma.dk>
            To: Magnus <magnus@example.dk>, Bo Berg <bo@startup.io>
            Cc: Carl <carl@firma.dk>
            Subject: Magnus, meet Bo

            Introducing you two.
            """)
        let plan = try #require(IntroReply.plan(for: m, ownAddresses: [me]))
        #expect(plan.bcc.map(\.address) == ["anna@firma.dk"])
        #expect(plan.to.map(\.address) == ["bo@startup.io"])
        #expect(plan.cc.map(\.address) == ["carl@firma.dk"])
        #expect(IntroReply.firstName(plan.introducer) == "Anna")
        #expect(IntroReply.firstName(MailAddress(name: "Holm, Anna", address: "x@y")) == "Anna")
        #expect(IntroReply.firstName(MailAddress(name: nil, address: "bo.berg@startup.io")) == "Bo")
    }

    @Test func noIntroWithoutAnyoneElse() {
        let m = parsed("From: anna@firma.dk\nTo: magnus@example.dk\nSubject: Hej\n\nx")
        #expect(IntroReply.plan(for: m, ownAddresses: [me]) == nil)
    }
}

@Suite struct SendCheckTests {
    let anna = MailAddress(name: "Anna Holm", address: "anna@firma.dk")
    let bo = MailAddress(name: "Bo Berg", address: "bo@firma.dk")

    @Test func promisedAttachment() {
        let text = "Hej Anna,\n\nJeg har vedhæftet kontrakten.\n\n-- \nMagnus"
        #expect(SendCheck.problems(text: text, attachmentCount: 0, recipients: [anna], conversationPeople: [], ownAddresses: [me])
                == [.missingAttachment(phrase: "vedhæft")])
        #expect(SendCheck.problems(text: text, attachmentCount: 1, recipients: [anna], conversationPeople: [], ownAddresses: [me]).isEmpty)
        #expect(SendCheck.problems(text: "Bo is unattached to the idea", attachmentCount: 0, recipients: [anna],
                                   conversationPeople: [], ownAddresses: [me]).isEmpty, "whole words only")
        #expect(SendCheck.problems(text: "Ok!\n\nOn Mon, Anna wrote:\n> see attached", attachmentCount: 0, recipients: [anna],
                                   conversationPeople: [], ownAddresses: [me]).isEmpty, "quotes don't count")
        #expect(SendCheck.problems(text: "Hi\n\n-- \nAttached: my vCard", attachmentCount: 0, recipients: [anna],
                                   conversationPeople: [], ownAddresses: [me]).isEmpty, "signatures don't count")
    }

    @Test func namedSomeoneWhoWasDropped() {
        let text = "Hej Anna og Bo, det lyder godt."
        let found = SendCheck.problems(text: text, attachmentCount: 0, recipients: [anna],
                                       conversationPeople: [anna, bo, MailAddress(name: "Magnus", address: me)], ownAddresses: [me])
        #expect(found == [.missingPerson(bo)])
    }
}

@Suite struct DarkModeTests {
    @Test func plainAndLightlyStyledCanDarken() {
        #expect(HTMLDarkMode.canDarken("<p>Hej <b>Anna</b></p>"))
        #expect(HTMLDarkMode.canDarken(##"<table bgcolor="#FFFFFF"><td style="background-color: rgb(255,255,255); color:#333">x</td></table>"##))
        #expect(HTMLDarkMode.canDarken(##"<div style="background: transparent">x</div>"##))
    }

    @Test func designedMailKeepsItsColours() {
        #expect(!HTMLDarkMode.canDarken(##"<table bgcolor="#1a73e8">x</table>"##))
        #expect(!HTMLDarkMode.canDarken(##"<div style="background-color:#f2f2f2">x</div>"##), "grey cards are design")
        #expect(!HTMLDarkMode.canDarken(##"<div style="background:url(hero.jpg)">x</div>"##))
    }
}

@Suite struct ReplyLaterStoreTests {
    @Test func keywordShowsOnTheConversationAndLinksResolve() throws {
        let s = try store()
        var a = message(1, thread: "t", from: "anna@firma.dk", to: me, daysAgo: 2)
        var b = message(2, thread: "t", from: "anna@firma.dk", to: me, daysAgo: 1)
        b.flags = "\\Seen \(replyLaterKeyword)"
        a.flags = "\\Seen"
        var archived = b
        archived.uid = 3
        archived.mailbox = "Archive"
        try s.upsert([(a, "x"), (b, "y"), (archived, "y")])
        let threads = try s.threads(mailbox: "INBOX", ownAddresses: [me])
        #expect(threads.first?.isReplyLater == true)
        #expect(try s.message(messageID: "<m2@x>")?.mailbox == "INBOX", "the Inbox copy wins")
        #expect(try s.message(messageID: "nope@x") == nil)
    }
}

@Suite struct ReplyCandidateTests {
    @Test func needsReplyHeuristic() {
        #expect(NeedsReply.likely(subject: "Møde", text: "Hej Magnus, kan du sende tallene inden fredag?"))
        #expect(NeedsReply.likely(subject: "Plan", text: "Please let me know which option works for you."))
        #expect(!NeedsReply.likely(subject: "FYI", text: "Here are the notes from today. No action needed."))
        #expect(!NeedsReply.likely(subject: "Re: x", text: "Thanks!\n\nOn Mon, Bo wrote:\n> Can you check?"), "a question only in the quote")
    }

    @Test func candidatesAreRecentPrimaryAsksToYou() throws {
        let s = try store()
        var ask = message(1, thread: "ask", from: "anna@firma.dk", name: "Anna", to: "Magnus <\(me)>", daysAgo: 0.5)
        ask.bodyText = TextCompression.compress("Hej Magnus, kan du kigge på budgettet i morgen?")
        var fyi = message(2, thread: "fyi", from: "bo@firma.dk", to: me, daysAgo: 0.5)
        fyi.bodyText = TextCompression.compress("Til orientering: referatet ligger på drevet.")
        var cc = message(3, thread: "cc", from: "cy@firma.dk", to: "a@x.dk, b@x.dk, c@x.dk, \(me)", daysAgo: 0.5)
        cc.bodyText = ask.bodyText
        var old = message(4, thread: "old", from: "di@firma.dk", to: me, daysAgo: 5)
        old.bodyText = ask.bodyText
        var bulk = message(5, thread: "bulk", from: "news@firma.dk", to: me, daysAgo: 0.5)
        bulk.bodyText = ask.bodyText
        bulk.category = .newsletters
        try s.upsert([ask, fyi, cc, old, bulk].map { ($0, $0.plainText ?? "") })
        #expect(try s.replyCandidates(accountID: "a", ownAddresses: [me]).map(\.threadID) == ["ask"])
        try s.saveAutoDraft(AutoDraft(threadID: "ask", accountID: "a", outboxID: nil, messageID: 1, kind: .reply))
        #expect(try s.replyCandidates(accountID: "a", ownAddresses: [me]).isEmpty)
        #expect(try s.autoDraft(threadID: "ask")?.kind == .reply)
    }
}

@Suite struct NotificationQueryTests {
    @Test func topCorrespondentsAndNewInbox() throws {
        let s = try store()
        var items: [(StoredMessage, String)] = []
        for i in 0..<3 { items.append((message(UInt32(10 + i), thread: "a\(i)", from: me, to: "Anna Holm <anna@firma.dk>", daysAgo: Double(i)), "x")) }
        for i in 0..<2 { items.append((message(UInt32(20 + i), thread: "b\(i)", from: me, to: "bo@firma.dk, noreply@x.dk", daysAgo: Double(i)), "x")) }
        items.append((message(30, thread: "c", from: me, to: "cy@firma.dk", daysAgo: 1), "x"))
        try s.upsert(items)
        let top = try s.topCorrespondents(ownAddresses: [me])
        #expect(top.map(\.address) == ["anna@firma.dk", "bo@firma.dk"], "twice or more, robots excluded")
        #expect(top.first?.name == "Anna Holm")
        let newest = try s.maxMessageID()
        try s.upsert([(message(40, thread: "n", from: "x@y.dk", to: me, daysAgo: 0), "new")])
        #expect(try s.inboxMessages(after: newest).map(\.uid) == [40])
    }
}
