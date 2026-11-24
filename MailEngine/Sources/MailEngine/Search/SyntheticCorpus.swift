import Foundation

/// Deterministic fake mailbox for search benchmarks and tests (SPEC §15: 250k messages).
/// Mixed Danish/English so tokenization and prefix matching are exercised realistically.
public struct SyntheticCorpus: Sendable {
    public var seed: UInt64

    public init(seed: UInt64 = 42) { self.seed = seed }

    struct Sender { let name: String; let address: String; let category: MailCategory }

    static let senders: [Sender] = [
        Sender(name: "Anna Jensen", address: "anna@example.dk", category: .primary),
        Sender(name: "Peter Nielsen", address: "peter.nielsen@firma.dk", category: .primary),
        Sender(name: "Sofie Hansen", address: "sofie@example.com", category: .primary),
        Sender(name: "Lars Møller", address: "lars@moeller.dk", category: .primary),
        Sender(name: "PostNord", address: "noreply@postnord.dk", category: .transactions),
        Sender(name: "MobilePay", address: "kvittering@mobilepay.dk", category: .transactions),
        Sender(name: "Zalando", address: "orders@zalando.dk", category: .transactions),
        Sender(name: "SAS", address: "booking@flysas.com", category: .transactions),
        Sender(name: "Apple", address: "no_reply@email.apple.com", category: .updates),
        Sender(name: "GitHub", address: "noreply@github.com", category: .updates),
        Sender(name: "e-Boks", address: "notifikation@e-boks.dk", category: .updates),
        Sender(name: "Politiken", address: "nyhedsbrev@pol.dk", category: .newsletters),
        Sender(name: "Stratechery", address: "email@stratechery.com", category: .newsletters),
        Sender(name: "Matas", address: "tilbud@matas.dk", category: .advertising),
        Sender(name: "Nike", address: "news@nike.com", category: .advertising),
        Sender(name: "Elgiganten", address: "kampagne@elgiganten.dk", category: .advertising),
        Sender(name: "LinkedIn", address: "messages-noreply@linkedin.com", category: .social),
        Sender(name: "Facebook", address: "notification@facebookmail.com", category: .social),
    ]

    static let subjects: [MailCategory: [String]] = [
        .primary: ["Møde i morgen?", "Re: projektplan for Q1", "Middag på lørdag", "Quick question about the contract",
                   "Billeder fra turen", "Re: tilbud på hjemmeside", "Can we move our call?", "Fødselsdag for mor"],
        .transactions: ["Din faktura fra %s", "Kvittering for dit køb", "Din pakke er på vej", "Ordrebekræftelse #%d",
                        "Your booking confirmation", "Betalingspåmindelse", "Your receipt from %s"],
        .updates: ["Din adgangskode er ændret", "New sign-in to your account", "Ny post i e-Boks",
                   "Security alert", "Your subscription renews soon", "[repo] CI failed on main"],
        .newsletters: ["Ugens vigtigste nyheder", "The weekly update", "Morgenbrief: det skal du vide i dag",
                       "Issue #%d: on aggregation theory"],
        .advertising: ["Black Friday: -40%% på alt", "Nye sko er landet", "Kun i dag: gratis fragt",
                       "Your exclusive offer inside", "Sidste chance for udsalg"],
        .social: ["Anna kommenterede dit opslag", "You have 3 new connection requests", "Peter har tagget dig"],
    ]

    static let words = """
        faktura fakturaer betaling kvittering ordre levering pakke sko jakke tilbud udsalg møde projekt kontrakt \
        hjemmeside design budget rapport invoice receipt shipping delivery order meeting project contract website \
        budget report weekend middag ferie fly hotel booking billet København Aarhus Odense vejret kaffe kontor \
        deadline præsentation feedback udkast draft review release version opdatering update sikkerhed security \
        adgangskode password abonnement subscription fornyelse renewal nyheder news artikel article podcast
        """.split(separator: " ").map(String.init)

    /// A Zipf-distributed vocabulary of pronounceable pseudo-words, so match-set sizes look like
    /// real mail (a few very common words, a long tail of rare ones) rather than every word
    /// appearing in every message.
    static let vocabulary: [String] = {
        var rng = SplitMix64(seed: 7)
        let onsets = ["b", "d", "f", "g", "h", "j", "k", "l", "m", "n", "p", "r", "s", "t", "v", "st", "sk", "br", "kr", "tr", "fl", "gr", ""]
        let vowels = ["a", "e", "i", "o", "u", "y", "æ", "ø", "å", "ei", "ou"]
        let codas = ["", "n", "r", "l", "s", "t", "nd", "ng", "rt", "st", "k"]
        var words = Set<String>()
        while words.count < 40_000 {
            var w = ""
            for _ in 0..<(1 + Int(rng.next() % 3)) {
                w += onsets[Int(rng.next() % UInt64(onsets.count))]
                w += vowels[Int(rng.next() % UInt64(vowels.count))]
                w += codas[Int(rng.next() % UInt64(codas.count))]
            }
            if w.count >= 3 { words.insert(w) }
        }
        return words.sorted()
    }()

    /// Cumulative Zipf weights (s = 1.07) for `vocabulary`.
    static let zipfCumulative: [Double] = {
        var total = 0.0
        return vocabulary.indices.map { rank in
            total += 1 / pow(Double(rank + 1), 1.07)
            return total
        }
    }()

    static func zipfWord(_ rng: inout SplitMix64) -> String {
        let target = Double(rng.next() % 1_000_000_000) / 1_000_000_000 * zipfCumulative.last!
        var lo = 0, hi = zipfCumulative.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if zipfCumulative[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return vocabulary[lo]
    }

    /// Generates `count` messages spread over the last `years` years.
    public func messages(count: Int, accountID: String = "synthetic", years: Int = 8) -> [(message: StoredMessage, plainText: String)] {
        var rng = SplitMix64(seed: seed)
        let now = Date()
        let span = Double(years) * 365 * 86_400
        var result: [(StoredMessage, String)] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let sender = Self.senders[Int(rng.next() % UInt64(Self.senders.count))]
            let templates = Self.subjects[sender.category]!
            var subject = templates[Int(rng.next() % UInt64(templates.count))]
            subject = subject.replacingOccurrences(of: "%s", with: sender.name)
                .replacingOccurrences(of: "%d", with: String(10_000 + i))
                .replacingOccurrences(of: "%%", with: "%")
            let wordCount = 40 + Int(rng.next() % 260)
            var body: [String] = []
            body.reserveCapacity(wordCount)
            for _ in 0..<wordCount {
                // ~3% topical real words (so "faktura", "sko", "møde" have realistic, modest hit counts).
                if rng.next() % 33 == 0 {
                    body.append(Self.words[Int(rng.next() % UInt64(Self.words.count))])
                } else {
                    body.append(Self.zipfWord(&rng))
                }
            }
            let text = body.joined(separator: " ")
            let date = now.addingTimeInterval(-Double(rng.next() % UInt64(span)))
            let message = StoredMessage(
                accountID: accountID, mailbox: "INBOX", uid: UInt32(i + 1),
                messageID: "<\(i)@synthetic.invalid>", subject: subject,
                fromName: sender.name, fromAddress: sender.address, recipients: "magnus@example.dk",
                date: date, flags: rng.next() % 5 == 0 ? "" : "\\Seen", size: text.utf8.count + 2_000,
                hasAttachments: rng.next() % 9 == 0, category: sender.category
            )
            result.append((message, text))
        }
        return result
    }
}

/// Small deterministic RNG so benchmarks are reproducible.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
