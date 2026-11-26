import Foundation

/// Realistic raw messages for seeding the local test server. Never used against real accounts.
public enum TestMailFactory {
    public struct Seed: Sendable {
        public var mailbox: String
        public var raw: Data
        public var flags: [String]
    }

    public static let me = MailAddress(name: "Magnus Kaspersen", address: "magnus@tidings.test")

    public static func mailbox(now: Date = Date()) -> [Seed] {
        var seeds: [Seed] = []
        var n = 0
        func id() -> String { n += 1; return "seed-\(n)@tidings.test" }
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

        // A real conversation, with my replies in Sent.
        let anna = MailAddress(name: "Anna Jensen", address: "anna@example.dk")
        let t1 = id(), t2 = id(), t3 = id()
        seeds.append(Seed(mailbox: "INBOX", raw: text(from: anna, to: [me], subject: "Middag på lørdag?", date: ago(50), id: t1,
            body: "Hej Magnus,\n\nSkal vi lave middag på lørdag? Jeg kan tage desserten med.\n\nKh Anna"), flags: ["\\Seen"]))
        seeds.append(Seed(mailbox: "Sent", raw: text(from: me, to: [anna], subject: "Re: Middag på lørdag?", date: ago(48), id: t2,
            body: "Hej Anna,\n\nGerne! Kl. 18? Jeg laver lasagne.\n\nMagnus\n\n> Skal vi lave middag på lørdag?", replyTo: [t1]), flags: ["\\Seen"]))
        seeds.append(Seed(mailbox: "INBOX", raw: text(from: anna, to: [me], subject: "Re: Middag på lørdag?", date: ago(3), id: t3,
            body: "Perfekt, kl. 18 passer. Skal jeg tage vin med også?\n\nAnna", replyTo: [t1, t2]), flags: []))

        // Work thread with an attachment.
        let peter = MailAddress(name: "Peter Nielsen", address: "peter.nielsen@firma.dk")
        let w1 = id()
        seeds.append(Seed(mailbox: "INBOX", raw: withAttachment(from: peter, to: [me], subject: "Kontrakt til gennemsyn",
            date: ago(26), id: w1, body: "Hej Magnus,\n\nHer er udkastet til kontrakten. Kan du kigge på punkt 4 inden fredag?\n\nVh Peter",
            filename: "Kontrakt udkast æøå.pdf"), flags: ["\\Seen", "\\Flagged"]))
        seeds.append(Seed(mailbox: "INBOX", raw: text(from: MailAddress(name: "Sofie Hansen", address: "sofie@example.com"), to: [me],
            subject: "Quick question about the website", date: ago(1.5), id: id(),
            body: "Hi Magnus,\n\nDo you have time for a 15 minute call tomorrow about the new website design? I have some feedback on the navigation.\n\nBest,\nSofie"), flags: []))

        // Transactions.
        seeds.append(Seed(mailbox: "INBOX", raw: html(from: MailAddress(name: "Zalando", address: "noreply@zalando.dk"), subject: "Din ordre #48213 er afsendt",
            date: ago(20), id: id(), html: "<h2>Din pakke er på vej</h2><p>Ordre <b>#48213</b>: Nike Air Max 90, str. 44 — <b>899,00 kr</b>.</p><p>Forventet levering: torsdag.</p>",
            bulk: false), flags: ["\\Seen"]))
        seeds.append(Seed(mailbox: "INBOX", raw: html(from: MailAddress(name: "MobilePay", address: "kvittering@mobilepay.dk"), subject: "Kvittering for dit køb hos Lagkagehuset",
            date: ago(30), id: id(), html: "<p>Du har betalt <b>87,50 kr</b> til Lagkagehuset.</p>", bulk: false), flags: ["\\Seen"]))
        seeds.append(Seed(mailbox: "INBOX", raw: html(from: MailAddress(name: "SAS", address: "no-reply@flysas.com"), subject: "Your booking confirmation CPH → OSL",
            date: ago(70), id: id(), html: "<p>Booking reference <b>K7XQ2P</b>. SK1456 Copenhagen 08:05 → Oslo 09:15, 12 December.</p>", bulk: false), flags: ["\\Seen"]))

        // Updates.
        seeds.append(Seed(mailbox: "INBOX", raw: text(from: MailAddress(name: "Apple", address: "no_reply@email.apple.com"), to: [me],
            subject: "Your Apple Account password was changed", date: ago(6), id: id(),
            body: "The password for your Apple Account was changed. If you didn't do this, reset your password."), flags: []))
        seeds.append(Seed(mailbox: "INBOX", raw: text(from: MailAddress(name: "GitHub", address: "notifications@github.com"), to: [me],
            subject: "[tidings] CI failed on main", date: ago(4), id: id(), body: "Run #142 failed: swift test (3 failures)."), flags: []))

        // Newsletters and ads (bulk with List-Unsubscribe).
        for (i, (name, address, subject, body)) in [
            ("Politiken", "nyhedsbrev@pol.dk", "Morgenbrief: det skal du vide i dag", "<h1>Godmorgen</h1><p>Her er dagens vigtigste historier…</p>"),
            ("Stratechery", "email@stratechery.com", "The Aggregator's Dilemma", "<p>This week: why platforms bundle, and what it means for mail.</p>"),
            ("Swift Weekly", "hello@swiftweekly.dev", "Issue #312: strict concurrency in practice", "<p>Five articles on Sendable and region isolation.</p>"),
        ].enumerated() {
            seeds.append(Seed(mailbox: "INBOX", raw: html(from: MailAddress(name: name, address: address), subject: subject,
                date: ago(Double(8 + i * 22)), id: id(), html: body, bulk: true), flags: i == 0 ? [] : ["\\Seen"]))
        }
        for (i, (name, address, subject)) in [
            ("Nike", "news@nike.com", "Black Friday: -40% på alle sko"),
            ("Matas", "tilbud@matas.dk", "Kun i dag: gratis fragt på alt"),
            ("Elgiganten", "kampagne@elgiganten.dk", "Sidste chance: udsalg på hørebøffer"),
        ].enumerated() {
            seeds.append(Seed(mailbox: "INBOX", raw: html(from: MailAddress(name: name, address: address), subject: subject,
                date: ago(Double(5 + i * 17)), id: id(), html: "<p>\(subject)</p><img src=\"https://tracker.example/pixel.gif\" width=1 height=1>", bulk: true), flags: []))
        }

        // A phishing attempt: brand in the display name, look-alike domain, a link that lies.
        seeds.append(Seed(mailbox: "INBOX", raw: html(from: MailAddress(name: "Apple Support", address: "security@app1e-id.com"),
            subject: "Din Apple-konto er låst", date: ago(2), id: id(),
            html: "<p>Vi har registreret usædvanlig aktivitet. Bekræft din identitet inden 24 timer:</p><p><a href=\"https://app1e-id.com/verify\">https://appleid.apple.com/verify</a></p>",
            bulk: false), flags: []))

        // Social.
        seeds.append(Seed(mailbox: "INBOX", raw: text(from: MailAddress(name: "LinkedIn", address: "messages-noreply@linkedin.com"), to: [me],
            subject: "You have 3 new connection requests", date: ago(12), id: id(), body: "Lars, Mette and Jonas want to connect."), flags: []))

        // Archive: older mail that should still be searchable.
        for i in 0..<12 {
            seeds.append(Seed(mailbox: "Archive", raw: text(from: MailAddress(name: "Bogholderiet", address: "bogholderi@firma.dk"), to: [me],
                subject: "Faktura \(2026_100 + i)", date: ago(Double(24 * (30 + i * 20))), id: id(),
                body: "Vedlagt faktura nr. \(2026_100 + i). Betalingsfrist 14 dage."), flags: ["\\Seen"]))
        }
        return seeds
    }

    /// The second test account's address (`workMailbox`).
    public static let work = MailAddress(name: "Magnus Kaspersen", address: "magnus@work.test")

    /// A second account's mail, for trying more than one account on the local server: its own
    /// conversations (distinct Message-IDs), plus Anna's latest dinner reply, which she sent to
    /// both addresses, so one conversation lives in both accounts' Inboxes.
    public static func workMailbox(now: Date = Date()) -> [Seed] {
        var seeds: [Seed] = []
        var n = 0
        func id() -> String { n += 1; return "work-\(n)@work.test" }
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        let lene = MailAddress(name: "Lene Vestergaard", address: "lene@work.test")
        let w1 = id(), w2 = id()
        seeds.append(Seed(mailbox: "INBOX", raw: text(from: lene, to: [work], subject: "Kvartalsplan til mandag", date: ago(30), id: w1,
            body: "Hej Magnus,\n\nKan du sende dine punkter til kvartalsplanen inden mandag?\n\nLene"), flags: ["\\Seen"]))
        seeds.append(Seed(mailbox: "Sent", raw: text(from: work, to: [lene], subject: "Re: Kvartalsplan til mandag", date: ago(28), id: w2,
            body: "Hej Lene,\n\nJa, de kommer i morgen.\n\nMagnus", replyTo: [w1]), flags: ["\\Seen"]))
        seeds.append(Seed(mailbox: "INBOX", raw: text(from: lene, to: [work], subject: "Re: Kvartalsplan til mandag", date: ago(1), id: id(),
            body: "Super, tak!\n\nLene", replyTo: [w1, w2]), flags: []))
        seeds.append(Seed(mailbox: "INBOX", raw: text(from: MailAddress(name: "Jonas Berg", address: "jonas@client.example"), to: [work],
            subject: "Tilbud på nyt website", date: ago(5), id: id(),
            body: "Hej Magnus,\n\nVi vil gerne have et tilbud på det nye website. Har du tid til et møde i næste uge?\n\nJonas"), flags: []))
        seeds.append(Seed(mailbox: "INBOX", raw: text(from: MailAddress(name: "Jira", address: "jira@work.test"), to: [work],
            subject: "[TID-42] Status changed to In Review", date: ago(7), id: id(), body: "Lene moved TID-42 to In Review."), flags: []))
        seeds.append(Seed(mailbox: "Archive", raw: text(from: MailAddress(name: "Lønservice", address: "loen@work.test"), to: [work],
            subject: "Lønseddel for oktober", date: ago(24 * 26), id: id(), body: "Din lønseddel for oktober er klar."), flags: ["\\Seen"]))
        // Sent to both addresses: the same message (Message-ID) in both accounts.
        if let shared = mailbox(now: now).first(where: { String(decoding: $0.raw, as: UTF8.self).contains("<seed-3@tidings.test>") }) {
            seeds.append(shared)
        }
        return seeds
    }

    /// Mail that mentions plans, for trying calendar suggestions: a sentence, a webinar written
    /// in another zone, a booking in schema.org JSON-LD. Not part of `mailbox()` (its tests count those).
    public static func datePlans(now: Date = Date()) -> [Seed] {
        var seeds: [Seed] = []
        var n = 0
        func id() -> String { n += 1; return "plan-\(n)-\(Int(now.timeIntervalSince1970))@tidings.test" }
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        let mette = MailAddress(name: "Mette Holm", address: "mette@example.dk")
        seeds.append(Seed(mailbox: "INBOX", raw: text(from: mette, to: [me], subject: "Middag hos os", date: ago(2), id: id(),
            body: "Hej Magnus,\n\nVil I komme til middag hos os i morgen kl. 19? Vi laver risotto.\nSted: Vesterbrogade 12, 1620 København V\n\nKh Mette"), flags: []))
        seeds.append(Seed(mailbox: "INBOX", raw: text(from: MailAddress(name: "Swift Weekly", address: "events@swiftweekly.dev"), to: [me],
            subject: "Reminder: Swift Concurrency webinar", date: ago(7), id: id(),
            body: "Hi Magnus,\n\nOur webinar on strict concurrency is next Thursday at 16:00 GMT. Join here: https://zoom.us/j/1234567\n\nSee you there!"), flags: []))
        let dinner = Calendar(identifier: .gregorian).date(byAdding: .day, value: 6, to: now) ?? now
        let dinnerDay = dinner.formatted(.iso8601.year().month().day())
        let booking = """
            <script type="application/ld+json">{"@context":"http://schema.org","@type":"FoodEstablishmentReservation",
            "reservationNumber":"TBL-4821","reservationStatus":"http://schema.org/ReservationConfirmed","partySize":2,
            "startTime":"\(dinnerDay)T19:30:00","reservationFor":{"@type":"FoodEstablishment","name":"Restaurant Barr",
            "address":{"@type":"PostalAddress","streetAddress":"Strandgade 93","postalCode":"1401","addressLocality":"København K"}}}</script>
            <p>Tak for din reservation til 2 personer. Vi glæder os til at se dig.</p>
            """
        seeds.append(Seed(mailbox: "INBOX", raw: html(from: MailAddress(name: "Restaurant Barr", address: "booking@restaurantbarr.example"),
            subject: "Din bordreservation er bekræftet", date: ago(9), id: id(), html: booking, bulk: false), flags: []))

        return seeds
    }

    // MARK: Builders

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    static func headers(from: MailAddress, to: [MailAddress], subject: String, date: Date, id: String, replyTo: [String] = []) -> [String] {
        var h = [
            "From: \(encodeAddress(from))",
            "To: \(to.map(encodeAddress).joined(separator: ", "))",
            "Subject: \(encodeWord(subject))",
            "Date: \(dateFormatter.string(from: date))",
            "Message-ID: <\(id)>",
            "MIME-Version: 1.0",
        ]
        if let parent = replyTo.last {
            h.append("In-Reply-To: <\(parent)>")
            h.append("References: \(replyTo.map { "<\($0)>" }.joined(separator: " "))")
        }
        return h
    }

    static func text(from: MailAddress, to: [MailAddress], subject: String, date: Date, id: String, body: String, replyTo: [String] = []) -> Data {
        let h = headers(from: from, to: to, subject: subject, date: date, id: id, replyTo: replyTo) + [
            "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: quoted-printable",
        ]
        return crlf(h.joined(separator: "\n") + "\n\n" + quotedPrintable(body))
    }

    static func html(from: MailAddress, subject: String, date: Date, id: String, html: String, bulk: Bool) -> Data {
        var h = headers(from: from, to: [me], subject: subject, date: date, id: id)
        if bulk {
            h.append("List-Unsubscribe: <https://\(from.address.split(separator: "@").last ?? "example.com")/unsub?u=1>, <mailto:unsub@\(from.address.split(separator: "@").last ?? "example.com")>")
            h.append("List-Unsubscribe-Post: List-Unsubscribe=One-Click")
            h.append("Precedence: bulk")
        }
        h.append("Content-Type: multipart/alternative; boundary=\"alt\"")
        let plain = HTMLText.toPlainText(html)
        let body = """
            --alt
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: quoted-printable

            \(quotedPrintable(plain))
            --alt
            Content-Type: text/html; charset=utf-8
            Content-Transfer-Encoding: base64

            \(Data("<html><body style=\"font-family:-apple-system\">\(html)</body></html>".utf8).base64EncodedString(options: .lineLength76Characters))
            --alt--
            """
        return crlf(h.joined(separator: "\n") + "\n\n" + body)
    }

    static func withAttachment(from: MailAddress, to: [MailAddress], subject: String, date: Date, id: String, body: String, filename: String) -> Data {
        var h = headers(from: from, to: to, subject: subject, date: date, id: id)
        h.append("Content-Type: multipart/mixed; boundary=\"mix\"")
        let encodedName = filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) ?? "file.pdf"
        let pdf = Data("%PDF-1.4\n% fake pdf for tests\n".utf8).base64EncodedString()
        let parts = """
            --mix
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: quoted-printable

            \(quotedPrintable(body))
            --mix
            Content-Type: application/pdf
            Content-Disposition: attachment; filename*=utf-8''\(encodedName)
            Content-Transfer-Encoding: base64

            \(pdf)
            --mix--
            """
        return crlf(h.joined(separator: "\n") + "\n\n" + parts)
    }

    static func encodeAddress(_ a: MailAddress) -> String {
        guard let name = a.name else { return a.address }
        return "\(encodeWord(name)) <\(a.address)>"
    }

    static func encodeWord(_ s: String) -> String {
        s.allSatisfy(\.isASCII) ? s : "=?utf-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    static func quotedPrintable(_ s: String) -> String {
        var out = ""
        var lineLength = 0
        for byte in Array(s.utf8) {
            var piece: String
            if byte == 10 { out += "\n"; lineLength = 0; continue }
            if (byte >= 33 && byte <= 126 && byte != 61) || byte == 32 { piece = String(UnicodeScalar(byte)) }
            else { piece = String(format: "=%02X", byte) }
            if lineLength + piece.count > 75 { out += "=\n"; lineLength = 0 }
            out += piece
            lineLength += piece.count
        }
        return out
    }

    static func crlf(_ s: String) -> Data {
        Data(s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }
}

/// Seeds the local test server. Hard-refuses anything but localhost.
public enum TestServerSeeder {
    public static func seed(endpoint: IMAPEndpoint, password: String, now: Date = Date(), datePlans: Bool = false,
                            work: Bool = false) async throws -> Int {
        guard endpoint.host == "127.0.0.1" || endpoint.host == "localhost" else {
            throw MailSessionError.commandFailed(command: "seed", detail: "seeding is only allowed against localhost")
        }
        let seeds = (work ? TestMailFactory.workMailbox(now: now) : TestMailFactory.mailbox(now: now))
            + (datePlans ? TestMailFactory.datePlans(now: now) : [])
        return try await MailSession.open(endpoint: endpoint, password: password) { session in
            for box in Set(seeds.map(\.mailbox)) where box != "INBOX" {
                try await session.ensureMailbox(box)
            }
            for seed in seeds {
                _ = try await session.append(to: seed.mailbox, message: seed.raw, flags: seed.flags)
            }
            return seeds.count
        }
    }
}
