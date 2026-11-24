import Foundation
import Testing
@testable import MailEngine

@Suite struct PhishingCheckTests {
    func check(_ headers: String, html: String? = nil, trusted: Set<String> = []) -> RiskAssessment {
        var raw = headers.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
        if let html { raw += "Content-Type: text/html; charset=utf-8\r\n\r\n\(html)" } else { raw += "\r\nbody" }
        return PhishingCheck.evaluate(MIMEParser.parse(Data(raw.utf8)), trustedDomains: trusted)
    }

    // MARK: Real attacks are flagged

    @Test func brandSpoofInDisplayName() {
        let r = check("From: Apple Support <security@account-verify.ru>\nSubject: Your Apple ID is locked")
        #expect(r.level == .caution, "one strong signal warns; it takes two to call it dangerous")
        #expect(check("From: Apple Support <security@account-verify.ru>\nAuthentication-Results: mx; dmarc=fail").level == .danger)
        #expect(check("From: Appleby Bakery <hej@appleby.dk>").level == .none, "brand names match whole words only")
        #expect(r.reasons.contains(.brandInDisplayName(brand: "apple", domain: "account-verify.ru")))
    }

    @Test func lookalikeDomains() {
        #expect(check("From: Konto <no-reply@app1e.com>").reasons.contains { if case .lookalikeDomain = $0 { true } else { false } })
        #expect(check("From: Kundeservice <info@mobi1epay.dk>").level == .danger)
        #expect(check("From: x <a@paypal-secure.net>").reasons.contains {
            if case .lookalikeDomain("paypal-secure.net", let target) = $0 { target.hasPrefix("paypal.") } else { false }
        })
        #expect(check("From: x <a@app1e-id.com>").reasons.contains { if case .lookalikeDomain = $0 { true } else { false } },
                "brand hidden behind a digit swap plus decoration")
        #expect(check("From: x <a@xn--pple-43d.com>").reasons.contains(.punycodeDomain(domain: "xn--pple-43d.com")))
    }

    @Test func lookalikeOfSomeoneYouWriteTo() {
        let r = check("From: Peter <peter@flrma.dk>", trusted: ["firma.dk"])
        #expect(r.reasons.contains(.lookalikeDomain(domain: "flrma.dk", resembles: "firma.dk")))
    }

    @Test func addressInDisplayNameAndFailedDMARC() {
        let r = check("From: \"service@danskebank.dk\" <x@mailer.example>\nAuthentication-Results: mx.icloud.com; dmarc=fail header.from=example")
        #expect(r.reasons.contains(.addressInDisplayName(shown: "service@danskebank.dk")))
        #expect(r.reasons.contains(.dmarcFailed))
        #expect(r.level == .danger)
    }

    @Test func linkTextShowsAnotherDomain() {
        let r = check("From: Bank <info@nyhedsbrev.dk>", html: #"<a href="https://login-check.example/x">https://www.danskebank.dk/log-ind</a>"#)
        #expect(r.reasons.contains(.linkMismatch(shown: "www.danskebank.dk", actual: "login-check.example")))
        #expect(r.level >= .caution)
    }

    // MARK: Ordinary mail is left alone

    @Test func genuineBrandMailIsNotFlagged() {
        #expect(check("From: Apple <no_reply@email.apple.com>\nAuthentication-Results: mx; dkim=pass; spf=pass; dmarc=pass").level == .none)
        #expect(check("From: Danske Bank <kundeservice@danskebank.dk>").level == .none)
        #expect(check("From: MobilePay <kvittering@mobilepay.dk>").level == .none)
    }

    @Test func trackingRedirectsWithNormalTextAreFine() {
        let html = #"<a href="https://click.mailchimp.com/track?u=1">Læs mere</a> <a href="https://shop.dk/x">shop.dk</a>"#
        #expect(check("From: Shop <news@shop.dk>", html: html).level == .none)
    }

    @Test func peopleAndShortDomainsAreFine() {
        #expect(check("From: Anna Jensen <anna@example.dk>").level == .none)
        #expect(check("From: Lars <lars@moeller.dk>").level == .none)
        #expect(check("From: GitHub <notifications@github.com>").level == .none)
    }

    @Test func reasonsRoundTrip() {
        let all: [RiskReason] = [.dmarcFailed, .brandInDisplayName(brand: "apple", domain: "x.ru"), .addressInDisplayName(shown: "a@b.dk"),
                                 .lookalikeDomain(domain: "app1e.com", resembles: "apple.com"), .punycodeDomain(domain: "xn--a.com"),
                                 .linkMismatch(shown: "a.dk", actual: "b.dk"), .replyToElsewhere(domain: "c.dk")]
        let encoded = RiskAssessment(level: .danger, reasons: all).encodedReasons
        #expect(RiskAssessment.decode(encoded) == all)
    }
}
