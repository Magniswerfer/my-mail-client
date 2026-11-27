import Foundation
import Testing
@testable import MailEngine

/// Email reactions: detecting Gmail, RFC 9078 and Outlook reactions, keeping them out of lists,
/// and building our own.
@Suite struct ReactionTests {
    static func parse(_ raw: String) -> ParsedMessage {
        MIMEParser.parse(Data(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }

    static let replyHeaders = """
        From: Houda CHIHI <houda@contoso.com>
        To: Magnus <magnus@example.dk>
        Subject: Re: Kvartalsplan
        Date: Tue, 24 Nov 2026 10:15:00 +0100
        Message-ID: <reaction-1@contoso.com>
        In-Reply-To: <original-1@example.dk>
        References: <original-1@example.dk>
        MIME-Version: 1.0
        """

    // MARK: Gmail

    @Test func gmailJSONPart() throws {
        let m = Self.parse(Self.replyHeaders + """

            Content-Type: multipart/alternative; boundary="g"

            --g
            Content-Type: text/plain; charset=UTF-8

            Houda reacted via Gmail
            --g
            Content-Type: text/vnd.google.email-reaction+json; charset=UTF-8

            {"version":1,"emoji":"👍"}
            --g
            Content-Type: text/html; charset=UTF-8

            <p>Houda reacted via Gmail</p>
            --g--
            """)
        #expect(m.reaction == ReactionMark(target: "original-1@example.dk", emoji: "👍"))
        #expect(m.attachments.isEmpty, "the JSON part isn't a file")
    }

    @Test func gmailPartWithUnknownVersionIsIgnored() {
        let m = Self.parse(Self.replyHeaders + """

            Content-Type: multipart/alternative; boundary="g"

            --g
            Content-Type: text/plain; charset=UTF-8

            Hello
            --g
            Content-Type: text/vnd.google.email-reaction+json; charset=UTF-8

            {"version":2,"emoji":"👍"}
            --g--
            """)
        #expect(m.reaction == nil)
    }

    // MARK: RFC 9078

    @Test func rfc9078ReactionPart() {
        let m = Self.parse(Self.replyHeaders + """

            Content-Type: multipart/alternative; boundary="r"

            --r
            Content-Type: text/plain; charset=utf-8
            Content-Disposition: reaction
            Content-Transfer-Encoding: quoted-printable

            =F0=9F=8E=89
            --r
            Content-Type: text/html; charset=utf-8

            <p>🎉 Houda reacted to your message</p>
            --r--
            """)
        #expect(m.reaction == ReactionMark(target: "original-1@example.dk", emoji: "🎉"))
    }

    @Test func rfc9078EmptyBodyRemovesTheReaction() throws {
        let m = Self.parse(Self.replyHeaders + """

            Content-Type: text/plain; charset=utf-8
            Content-Disposition: reaction


            """)
        let reaction = try #require(m.reaction)
        #expect(reaction.isRemoval)
    }

    @Test func rfc9078PartWithTextIsNotAReaction() {
        let m = Self.parse(Self.replyHeaders + """

            Content-Type: text/plain; charset=utf-8
            Content-Disposition: reaction

            Thanks, that works for me 👍
            """)
        #expect(m.reaction == nil)
    }

    @Test func reactionNeedsInReplyTo() {
        let m = Self.parse("""
            From: houda@contoso.com
            Subject: Hi
            Message-ID: <x@contoso.com>
            Content-Type: text/plain; charset=utf-8
            Content-Disposition: reaction

            👍
            """)
        #expect(m.reaction == nil)
    }

    // MARK: Outlook

    static func outlook(name: String, wording: String, alt: String, src: String, headers: String = replyHeaders) -> String {
        headers + """

            x-ms-reactions: disallow
            Content-Type: multipart/alternative; boundary="o"

            --o
            Content-Type: text/plain; charset="utf-8"
            Content-Transfer-Encoding: quoted-printable

            [\(name)]     Houda CHIHI \(wording):
            ________________________________
            From: Magnus <magnus@example.dk>
            Sent: Monday, November 23, 2026 9:00 AM
            To: Houda CHIHI <houda@contoso.com>
            Subject: Kvartalsplan

            Here is the plan for Q1.
            --o
            Content-Type: text/html; charset="utf-8"

            <html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"><style>p{margin:0}</style></head>
            <body><table><tr><td><img alt="\(alt)" src="\(src)" width="20" height="20"></td>
            <td><span>Houda CHIHI</span> <span>\(wording):</span></td></tr></table>
            <hr style="display:inline-block;width:98%">
            <div id="x_divRplyFwdMsg" dir="ltr"><b>From:</b> Magnus<br><b>Subject:</b> Kvartalsplan</div>
            <div>Here is the plan for Q1.<img alt="like" src="https://outlook-1.cdn.office.net/assets/reaction/like.png"></div>
            </body></html>
            --o--
            """
    }

    @Test func outlookFallbackMail() throws {
        let m = Self.parse(Self.outlook(name: "celebrate", wording: "reacted to your message", alt: "celebrate",
                                        src: "https://outlook-1.cdn.office.net/assets/reaction/celebrate.png"))
        #expect(m.reaction == ReactionMark(target: "original-1@example.dk", emoji: "🎉"))
        #expect(m.reactionsDisallowed)
    }

    @Test func outlookInDanishIsRecognizedWithoutTheWording() throws {
        let m = Self.parse(Self.outlook(name: "heart", wording: "reagerede på din meddelelse", alt: "heart",
                                        src: "https://outlook-1.cdn.office.net/assets/reaction/heart.png"))
        #expect(m.reaction?.emoji == "❤️")
    }

    @Test func outlookRemoval() throws {
        let m = Self.parse(Self.outlook(name: "0", wording: "reacted to your message", alt: "0", src: ""))
        let reaction = try #require(m.reaction)
        #expect(reaction.isRemoval)
        #expect(reaction.target == "original-1@example.dk")
    }

    @Test func outlookPlainTextOnly() throws {
        let m = Self.parse(Self.replyHeaders + """

            Content-Type: text/plain; charset=utf-8

            [laugh]     Houda CHIHI hat auf Ihre Nachricht reagiert:
            ________________________________
            Von: Magnus
            Betreff: Kvartalsplan

            Here is the plan.
            """)
        #expect(m.reaction?.emoji == "😆")
    }

    @Test func eachOutlookNameMapsToItsEmoji() {
        let expected = ["like": "👍", "heart": "❤️", "celebrate": "🎉", "laugh": "😆", "surprised": "😮", "sad": "😢"]
        for (name, emoji) in expected {
            let m = Self.parse(Self.outlook(name: name, wording: "reacted to your message", alt: name,
                                            src: "https://outlook-1.cdn.office.net/assets/reaction/\(name).png"))
            #expect(m.reaction?.emoji == emoji, "\(name)")
        }
    }

    @Test func aReplyQuotingAnOutlookReactionIsMail() {
        // Someone answers the reaction mail: the reaction image is only in the quoted part.
        let m = Self.parse(Self.replyHeaders + """

            Content-Type: multipart/alternative; boundary="q"

            --q
            Content-Type: text/plain; charset=utf-8

            Glad you like it! Let's meet on Monday to go through the details.

            ________________________________
            [like]     Houda CHIHI reacted to your message:
            --q
            Content-Type: text/html; charset=utf-8

            <html><body><p>Glad you like it! Let's meet on Monday to go through the details.</p>
            <hr><div id="divRplyFwdMsg"><img alt="like" src="https://outlook-1.cdn.office.net/assets/reaction/like.png"></div>
            </body></html>
            --q--
            """)
        #expect(m.reaction == nil)
    }

    @Test func ordinaryRepliesAreNotReactions() {
        let m = Self.parse(Self.replyHeaders + """

            Content-Type: text/plain; charset=utf-8

            [like] this idea: let's do it:
            Sounds good.
            """)
        #expect(m.reaction == nil)
        #expect(!m.reactionsDisallowed)
    }

    @Test func imageFromAnotherHostIsNotAReaction() {
        let m = Self.parse(Self.replyHeaders + """

            Content-Type: text/html; charset=utf-8

            <html><body><img alt="like" src="https://evil.example.com/assets/reaction/like.png"> Nice</body></html>
            """)
        #expect(m.reaction == nil)
    }

    // MARK: Building

    static let me = MailAddress(name: "Magnus <Kaspersen> & Co", address: "magnus@example.dk")

    static var original: ParsedMessage {
        parse("""
            From: Anna Jensen <anna@example.com>
            To: Magnus <magnus@example.dk>
            Subject: Middag på lørdag?
            Message-ID: <dinner-2@example.com>
            In-Reply-To: <dinner-1@example.dk>
            References: <dinner-1@example.dk>
            Content-Type: text/plain; charset=utf-8

            Skal vi spise kl. 19?
            """)
    }

    @Test func builderMakesTheThreePartsInOrder() throws {
        let message = try #require(OutgoingMessage.reaction("👍", from: Self.me, to: Self.original))
        #expect(message.to == [MailAddress(name: "Anna Jensen", address: "anna@example.com")])
        #expect(message.subject == "Re: Middag på lørdag?")
        #expect(message.inReplyTo == "dinner-2@example.com")
        #expect(message.references == ["dinner-1@example.dk", "dinner-2@example.com"])

        let raw = MIMEBuilder.build(message)
        let entity = Entity.parse([UInt8](raw)[...])
        #expect(entity.contentType.full == "multipart/alternative")
        #expect(entity.children.map(\.contentType.full) == ["text/plain", "text/vnd.google.email-reaction+json", "text/html"])
        let plain = entity.children[0]
        #expect(plain.disposition == "reaction")
        #expect(plain.contentType.parameters["charset"] == "utf-8")
        #expect(plain.decodedText == "👍")
        #expect(entity.children[1].decodedText == #"{"version":1,"emoji":"👍"}"#)
        let html = entity.children[2].decodedText
        #expect(html.contains("👍 Magnus &lt;Kaspersen&gt; &amp; Co reacted to your message"))
        #expect(raw.allSatisfy { $0 < 128 }, "7-bit clean")
    }

    @Test func builderSkipsGmailPartForBigRecipientLists() throws {
        let many = (1...21).map { "p\($0)@example.com" }.joined(separator: ", ")
        let original = Self.parse("""
            From: anna@example.com
            To: \(many)
            Subject: All hands
            Message-ID: <all@example.com>
            Content-Type: text/plain

            Hi all
            """)
        let message = try #require(OutgoingMessage.reaction("🎉", from: Self.me, to: original))
        let entity = Entity.parse([UInt8](MIMEBuilder.build(message))[...])
        #expect(entity.children.map(\.contentType.full) == ["text/plain", "text/html"])
    }

    @Test func builderKeepsAnExistingReplyPrefixAndRefusesText() throws {
        #expect(OutgoingMessage.replySubject("SV: Møde") == "SV: Møde")
        #expect(OutgoingMessage.replySubject("Møde") == "Re: Møde")
        #expect(OutgoingMessage.reaction("ok", from: Self.me, to: Self.original) == nil)
    }

    @Test func roundTripIsDetectedAsOurReaction() throws {
        let message = try #require(OutgoingMessage.reaction("❤️", from: Self.me, to: Self.original))
        let parsed = MIMEParser.parse(MIMEBuilder.build(message))
        #expect(parsed.reaction == ReactionMark(target: "dinner-2@example.com", emoji: "❤️"))
        #expect(parsed.from.first?.address == "magnus@example.dk")

        let removal = try #require(OutgoingMessage.reaction("", from: Self.me, to: Self.original))
        let removed = MIMEParser.parse(MIMEBuilder.build(removal))
        #expect(removed.reaction == ReactionMark(target: "dinner-2@example.com", emoji: ""))
    }

    @Test func builderFromAStoredMessage() throws {
        var stored = StoredMessage(accountID: "a", mailbox: "INBOX", uid: 1, messageID: "dinner-2@example.com",
                                   threadID: "dinner-1@example.dk", subject: "Re: Middag", fromName: "Anna",
                                   fromAddress: "anna@example.com", recipients: "magnus@example.dk", date: Date())
        stored.inReplyTo = "dinner-1@example.dk"
        let message = try #require(OutgoingMessage.reaction("👍", from: Self.me, to: stored))
        #expect(message.subject == "Re: Middag")
        #expect(message.references == ["dinner-1@example.dk", "dinner-2@example.com"])
        #expect(message.reaction?.includesGmailPart == true)
    }

    // MARK: Store

    static func makeStore() throws -> MailStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-reactions-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
    }

    static func stored(uid: UInt32, mailbox: String = "INBOX", from: String, name: String? = nil, messageID: String,
                       minutesAgo: Double, reactionTo: String? = nil, emoji: String? = nil, flags: String = "") -> StoredMessage {
        var m = StoredMessage(accountID: "a", mailbox: mailbox, uid: uid, messageID: messageID, threadID: "t1",
                              subject: "Plan", fromName: name, fromAddress: from, recipients: "me@example.dk",
                              date: Date().addingTimeInterval(-minutesAgo * 60), flags: flags)
        m.reactionTo = reactionTo
        m.reactionEmoji = emoji
        return m
    }

    @Test func latestReactionPerSenderWinsAndRemovalsDrop() throws {
        let store = try Self.makeStore()
        try store.upsert([
            (Self.stored(uid: 1, from: "me@example.dk", messageID: "orig@x", minutesAgo: 60, flags: "\\Seen"), "The plan"),
            (Self.stored(uid: 2, from: "anna@example.com", name: "Anna", messageID: "r1@x", minutesAgo: 50, reactionTo: "orig@x", emoji: "👍"), "👍"),
            (Self.stored(uid: 3, from: "Anna@Example.com", name: "Anna", messageID: "r2@x", minutesAgo: 40, reactionTo: "orig@x", emoji: "❤️"), "❤️"),
            (Self.stored(uid: 4, from: "bo@example.com", messageID: "r3@x", minutesAgo: 30, reactionTo: "orig@x", emoji: "🎉"), "🎉"),
            (Self.stored(uid: 5, from: "bo@example.com", messageID: "r4@x", minutesAgo: 20, reactionTo: "orig@x", emoji: ""), ""),
            (Self.stored(uid: 6, mailbox: "Sent", from: "me@example.dk", messageID: "r5@x", minutesAgo: 10, reactionTo: "orig@x", emoji: "😆"), "😆"),
            // The same reaction filed twice (Sent and Archive) counts once.
            (Self.stored(uid: 7, mailbox: "Archive", from: "me@example.dk", messageID: "r5@x", minutesAgo: 10, reactionTo: "orig@x", emoji: "😆"), "😆"),
        ])
        let reactions = try store.reactions(toMessageIDs: ["<orig@x>", "other@x"], ownAddresses: ["Me@example.dk"])
        #expect(reactions.keys.sorted() == ["orig@x"])
        let list = try #require(reactions["orig@x"])
        #expect(list.map(\.emoji) == ["❤️", "😆"], "Anna's latest wins, Bo took his back")
        #expect(list.map(\.isMine) == [false, true])
        #expect(list[0].fromName == "Anna")
        #expect(list[1].fromName == "me@example.dk", "no name: the address")
    }

    @Test func reactionsStayOutOfListsCountsAndRules() throws {
        let store = try Self.makeStore()
        try store.upsert([
            (Self.stored(uid: 1, from: "anna@example.com", messageID: "orig@x", minutesAgo: 60, flags: "\\Seen"), "The plan"),
            (Self.stored(uid: 2, from: "bo@example.com", messageID: "r1@x", minutesAgo: 10, reactionTo: "orig@x", emoji: "👍"),
             "👍 Bo reacted to your message"),
        ])
        let threads = try store.threads(mailbox: "INBOX")
        #expect(threads.count == 1)
        #expect(threads.first?.latest.messageID == "orig@x", "the reaction isn't the newest message")
        #expect(threads.first?.unreadCount == 0, "an unread reaction doesn't count")
        #expect(threads.first?.messageCount == 1)
        #expect(try store.messages(inThread: "t1").map(\.messageID) == ["orig@x"])
        #expect(try store.ruleCandidates(accountID: "a").messages.map(\.messageID) == ["orig@x"])
        #expect(try store.inboxMessages().map(\.messageID) == ["orig@x"])
        let hits = try SearchEngine(store: store).hits(SearchQuery(parsing: "reacted"))
        #expect(hits.hits.isEmpty)

        // A reaction alone in a mailbox makes no thread there.
        try store.upsert([(Self.stored(uid: 3, mailbox: "Archive", from: "bo@example.com", messageID: "r9@x",
                                       minutesAgo: 5, reactionTo: "orig@x", emoji: "😮"), "😮")])
        #expect(try store.threads(mailbox: "Archive").isEmpty)

        let reaction = try #require(try store.message(messageID: "r1@x"))
        let quiet = NotificationPolicy().notifications(for: [reaction], ruleRuns: [], ownAddresses: [], store: store)
        #expect(quiet.isEmpty)
    }
}

/// Against the local Dovecot: an Outlook-style reaction syncs as a reaction, not a thread row.
@Suite(.serialized) struct ReactionIntegrationTests {
    @Test func outlookReactionSyncsAsReaction() async throws {
        let probe = IMAPEndpoint(host: "127.0.0.1", port: 31143, useTLS: false, username: "")
        guard (try? await MailSession.probeGreeting(endpoint: probe)) != nil else { return }
        let endpoint = IMAPEndpoint(host: "127.0.0.1", port: 31143, useTLS: false, username: "react-\(UUID().uuidString.prefix(8))")
        let original = """
            From: Magnus <magnus@example.dk>
            To: Houda CHIHI <houda@contoso.com>
            Subject: Kvartalsplan
            Date: Mon, 23 Nov 2026 09:00:00 +0100
            Message-ID: <original-1@example.dk>
            Content-Type: text/plain; charset=utf-8

            Here is the plan for Q1.

            """
        let reaction = ReactionTests.outlook(name: "like", wording: "reacted to your message", alt: "like",
                                             src: "https://outlook-1.cdn.office.net/assets/reaction/like.png") + "\n"
        try await MailSession.open(endpoint: endpoint, password: "tidings-test", profile: .generic) { session in
            for raw in [original, reaction] {
                _ = try await session.append(to: "INBOX", message: Data(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8))
            }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-react-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
        let account = AccountConfig(id: "r", displayName: "R", endpoint: endpoint, addresses: ["magnus@example.dk"])
        let sync = AccountSync(account: account, password: "tidings-test", store: store,
                               cache: MessageCache(directory: dir.appendingPathComponent("cache")), profile: .generic)
        try await sync.syncOnce()

        #expect(try store.count() == 2)
        let threads = try store.threads(mailbox: "INBOX")
        #expect(threads.map(\.latest.messageID) == ["original-1@example.dk"])
        #expect(threads.first?.messageCount == 1)
        let reactions = try store.reactions(toMessageIDs: ["original-1@example.dk"], ownAddresses: ["magnus@example.dk"])
        let like = try #require(reactions["original-1@example.dk"]?.first)
        #expect(like.emoji == "👍")
        #expect(like.fromAddress == "houda@contoso.com")
        #expect(like.fromName == "Houda CHIHI")
        #expect(!like.isMine)
        let stored = try #require(try store.message(messageID: "reaction-1@contoso.com"))
        #expect(stored.isReaction)
        #expect(stored.reactionsDisallowed)
    }
}
