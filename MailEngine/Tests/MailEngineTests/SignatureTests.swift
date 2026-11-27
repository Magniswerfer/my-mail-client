import Foundation
import Testing
@testable import MailEngine

@Suite struct SignatureTests {
    /// The Creative Oak signature as its owners use it (hosted images).
    static let creativeOak = """
        <div>
        <table style="font-family:Poppins,Arial,Helvetica,sans-serif;color:#333740">
        <tbody><tr>
        <td style="padding:0">
        <p style="margin:0;font-size:24px;font-weight:700;color:#333740">Heine Volder Rødder<span style="color:#FF7247;font-size:32px">.</span></p>
        <p style="font-size:13px;color:#333740">Partner &amp; udvikler hos Creative Oak</p>
        </td>
        </tr>
        <tr>
        <td>
        <p style="margin:0 0 4px;font-size:16px;font-weight:700;color:#333740">Come say hej.</p>
        <table>
        <tbody><tr>
        <td><img src="https://creativeoak.io/email/co-dot-orange.png" width="12" height="12" alt=""></td>
        <td style="font-size:13px"><a href="mailto:heine@creativeoak.dk" style="color:#333740;text-decoration:none" target="_blank" rel="noopener noreferrer nofollow">heine@creativeoak.dk</a></td>
        </tr>
        <tr>
        <td><img src="https://creativeoak.io/email/co-dot-gul.png" width="12" height="12" alt=""></td>
        <td style="font-size:13px"><a style="color:#333740;text-decoration:none" target="_blank" rel="noopener noreferrer nofollow">+45 43 16 19 69</a></td>
        </tr>
        <tr>
        <td><img src="https://creativeoak.io/email/co-dot-bla.png" width="12" height="12" alt=""></td>
        <td style="font-size:13px"><a href="https://creativeoak.io" style="color:#333740;text-decoration:none;font-weight:700" target="_blank" rel="noopener noreferrer nofollow">creativeoak.io</a></td>
        </tr>
        </tbody></table>
        </td>
        </tr>
        <tr>
        <td>
        <a href="https://creativeoak.io" style="text-decoration:none" target="_blank" rel="noopener noreferrer nofollow"><img src="https://creativeoak.io/email/co-logo-card.png" width="240" height="96" alt="Creative Oak"></a>
        </td>
        </tr>
        </tbody></table>
        </div>
        """

    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
    let me = MailAddress(name: "Heine Volder Rødder", address: "heine@creativeoak.dk")

    // MARK: HTML

    @Test func plainTextOfTheCreativeOakSignatureIsOneLinePerLine() {
        #expect(SignatureHTML.plainText(Self.creativeOak) == """
            Heine Volder Rødder.
            Partner & udvikler hos Creative Oak
            Come say hej.
            heine@creativeoak.dk
            +45 43 16 19 69
            creativeoak.io
            """)
    }

    @Test func plainTextWritesOutLinksWhoseTextDoesntSayWhere() {
        let text = SignatureHTML.plainText(#"<p><a href="https://www.linkedin.com/in/magnus/">LinkedIn</a> · <a href="https://tidings.app/">tidings.app</a></p>"#)
        #expect(text == "LinkedIn <https://www.linkedin.com/in/magnus/> · tidings.app")
    }

    @Test func sanitizeKeepsTheBodyAndDropsWhatCouldRun() {
        let pasted = """
            <html><head><title>x</title><style>p{color:red}</style><script>alert(1)</script></head>
            <body onload="evil()"><!-- comment --><p onclick="x()" style="color:#333">Hej <a href="javascript:alert(1)">klik</a></p>
            <form><input value="a"></form><img src="cid:sig-1@tidings" onerror='bad()'><div contenteditable="true">x</div></body></html>
            """
        let clean = SignatureHTML.sanitize(pasted)
        #expect(!clean.lowercased().contains("script"))
        #expect(!clean.contains("onclick") && !clean.contains("onerror") && !clean.contains("onload"))
        #expect(!clean.contains("javascript:"))
        #expect(!clean.contains("<form") && !clean.contains("<input") && !clean.contains("<style") && !clean.contains("<title"))
        #expect(!clean.contains("contenteditable") && !clean.contains("<!--"))
        #expect(clean.contains(##"<p style="color:#333">Hej <a href="#">klik</a></p>"##))
        #expect(clean.contains(#"<img src="cid:sig-1@tidings">"#))
    }

    @Test func sanitizeLeavesTheCreativeOakSignatureAsItIs() {
        #expect(SignatureHTML.sanitize(Self.creativeOak) == Self.creativeOak.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func dataImagesBecomeEmbeddedImagesAndBack() {
        let uri = "data:image/png;base64,\(Self.png.base64EncodedString())"
        let html = #"<p>Logo <img src="\#(uri)" width="20"> and again <img src="\#(uri)"></p>"#
        let (out, images) = SignatureHTML.extractingImages(html)
        #expect(images.count == 1, "the same bytes are one image")
        let image = try! #require(images.first)
        #expect(image.contentID.hasPrefix(SignatureImage.contentIDPrefix))
        #expect(image.mimeType == "image/png" && image.data == Self.png && image.filename == "signature-1.png")
        #expect(out == #"<p>Logo <img src="cid:\#(image.contentID)" width="20"> and again <img src="cid:\#(image.contentID)"></p>"#)
        #expect(SignatureHTML.inliningImages(out, images) == html)

        // Editing again keeps the image's Content-ID, and drops images no longer used.
        let unused = SignatureImage(filename: "old.png", mimeType: "image/png", data: Data([1]))
        let again = SignatureHTML.extractingImages(html, existing: [image, unused])
        #expect(again.images == [image])
        #expect(again.html == out)
    }

    @Test func findsRemoteImagesAndEmbedsOne() {
        let urls = SignatureHTML.remoteImageURLs(in: Self.creativeOak)
        #expect(urls == ["https://creativeoak.io/email/co-dot-orange.png", "https://creativeoak.io/email/co-dot-gul.png",
                         "https://creativeoak.io/email/co-dot-bla.png", "https://creativeoak.io/email/co-logo-card.png"])
        let logo = SignatureImage(filename: "co-logo-card.png", mimeType: "image/png", data: Self.png)
        let embedded = SignatureHTML.embedding(urls[3], as: logo, in: Self.creativeOak)
        #expect(embedded.contains(#"<img src="cid:\#(logo.contentID)" width="240" height="96" alt="Creative Oak">"#))
        #expect(SignatureHTML.remoteImageURLs(in: embedded).count == 3)
    }

    @Test func plainTextSignaturesConvertWithAStableID() {
        let a = Signature.fromPlainText("Magnus <m@gnus.hk>\nTidings\n", name: "Magnus")
        let b = Signature.fromPlainText("Magnus <m@gnus.hk>\nTidings", name: "Other name")
        #expect(a.id == b.id)
        #expect(a.html == "<div>Magnus &lt;m@gnus.hk&gt;<br>Tidings</div>")
        #expect(a.plainText == "Magnus <m@gnus.hk>\nTidings")
        #expect(a.textBlock == "-- \nMagnus <m@gnus.hk>\nTidings")
    }

    // MARK: The message

    @Test func embeddedImagesGoOutAsRelatedPartsTheHTMLReferences() throws {
        let logo = SignatureImage(filename: "logo.png", mimeType: "image/png", data: Self.png)
        let unused = SignatureImage(filename: "unused.png", mimeType: "image/png", data: Data([9, 9]))
        let signature = Signature(name: "Work", html: #"<p><b>Heine</b></p><img src="cid:\#(logo.contentID)" width="240">"#,
                                  images: [logo, unused])
        var message = OutgoingMessage(
            from: me, to: [MailAddress(name: nil, address: "kunde@example.dk")], subject: "Tilbud",
            text: "Hej\n\n" + signature.textBlock,
            html: "<div><p>Hej</p>\(signature.htmlBlock)</div>",
            attachments: [OutgoingAttachment(filename: "tilbud.pdf", mimeType: "application/pdf", data: Data(repeating: 1, count: 40))])
        message.addSignatureImages([signature])
        // Built twice (a draft saved, then sent): still one part.
        message.addSignatureImages([signature])
        #expect(message.attachments.filter { $0.contentID != nil }.count == 1)

        let raw = MIMEBuilder.build(message)
        let source = String(decoding: raw, as: UTF8.self)
        #expect(source.contains("multipart/mixed"))
        #expect(source.contains("multipart/related"))
        #expect(source.contains("Content-ID: <\(logo.contentID)>"))
        #expect(!source.contains("unused.png"))

        let parsed = MIMEParser.parse(raw)
        #expect(parsed.html?.contains(#"src="cid:\#(logo.contentID)""#) == true)
        #expect(parsed.html?.contains(#"<div class="tidings-signature">"#) == true)
        #expect(parsed.plainText.hasSuffix("-- \nHeine"))
        // The PDF is an attachment you see; the logo is part of the body.
        #expect(parsed.attachments.filter { !$0.isInline }.map(\.filename) == ["tilbud.pdf"])
        #expect(parsed.attachments.filter(\.isInline).map(\.contentID) == [logo.contentID])
        let inline = MIMEParser.attachments(in: raw).first { $0.contentID == logo.contentID }
        #expect(inline?.data == Self.png)
    }

    @Test func hostedImagesStayLinksAndAddNoParts() {
        let signature = Signature(name: "Creative Oak", html: Self.creativeOak)
        var message = OutgoingMessage(from: me, to: [MailAddress(name: nil, address: "a@b.dk")], subject: "Hej",
                                      text: "Hej\n\n" + signature.textBlock, html: "<div><p>Hej</p>\(signature.htmlBlock)</div>")
        message.addSignatureImages([signature])
        #expect(message.attachments.isEmpty)
        let source = String(decoding: MIMEBuilder.build(message), as: UTF8.self)
        #expect(!source.contains("multipart/related"))
        let parsed = MIMEParser.parse(MIMEBuilder.build(message))
        #expect(parsed.html?.contains("https://creativeoak.io/email/co-logo-card.png") == true)
        #expect(parsed.plainText.contains("-- \nHeine Volder Rødder.\nPartner & udvikler hos Creative Oak"))
    }

    // MARK: Choosing

    @Test func defaultsPerAddressForNewMailAndReplies() {
        var settings = SignatureSettings()
        settings.setDefaults(SignatureDefaults(newMail: .signature("full"), replies: .signature("short")), for: "Heine@CreativeOak.dk")
        settings.setDefaults(SignatureDefaults(newMail: .signature("private")), for: "heine@icloud.com")
        let to = ["kunde@example.dk"]
        #expect(settings.choose(from: "heine@creativeoak.dk", kind: .new, recipients: to) == "full")
        #expect(settings.choose(from: "heine@creativeoak.dk", kind: .reply, recipients: to) == "short")
        #expect(settings.choose(from: "heine@creativeoak.dk", kind: .forward, recipients: to) == "short")
        // Replies use new mail's when not set.
        #expect(settings.choose(from: "heine@icloud.com", kind: .replyAll, recipients: to) == "private")
        #expect(settings.choose(from: "other@x.dk", kind: .new, recipients: to) == nil)
        settings.setDefaults(SignatureDefaults(newMail: .signature("private"), replies: SignatureChoice.none), for: "heine@icloud.com")
        #expect(settings.choose(from: "heine@icloud.com", kind: .reply, recipients: to) == nil)
    }

    @Test func rulesByRecipientDomainComeFirst() {
        var settings = SignatureSettings(rules: [
            SignatureRule(fromAddress: "heine@creativeoak.dk", match: .everyRecipientIn, domains: ["@CreativeOak.dk "], use: .signature("internal")),
            SignatureRule(context: .replies, match: .anyRecipientIn, domains: ["bank.dk"], use: SignatureChoice.none),
        ])
        settings.setDefaults(SignatureDefaults(newMail: .signature("full")), for: "heine@creativeoak.dk")
        let from = "heine@creativeoak.dk"
        #expect(settings.choose(from: from, kind: .new, recipients: ["magnus@creativeoak.dk", "x@mail.creativeoak.dk"]) == "internal")
        #expect(settings.choose(from: from, kind: .new, recipients: ["magnus@creativeoak.dk", "kunde@example.dk"]) == "full")
        #expect(settings.choose(from: from, kind: .new, recipients: []) == "full", "no recipients yet: the default")
        #expect(settings.choose(from: "heine@icloud.com", kind: .new, recipients: ["magnus@creativeoak.dk"]) == nil, "the rule is for one address")
        #expect(settings.choose(from: from, kind: .reply, recipients: ["a@bank.dk", "b@example.dk"]) == nil)
        #expect(settings.choose(from: from, kind: .new, recipients: ["a@bank.dk"]) == "full", "that rule is for replies")

        let external = SignatureRule(match: .anyRecipientOutside, domains: ["creativeoak.dk"], use: .signature("external"))
        let rules = SignatureSettings(rules: [external])
        #expect(rules.choose(from: from, kind: .new, recipients: ["a@creativeoak.dk", "b@example.dk"]) == "external")
        #expect(rules.choose(from: from, kind: .new, recipients: ["a@creativeoak.dk"]) == nil)
    }

    @Test func forgettingASignatureClearsWhatPointsAtIt() {
        var settings = SignatureSettings(rules: [SignatureRule(domains: ["a.dk"], use: .signature("x"))])
        settings.setDefaults(SignatureDefaults(newMail: .signature("x"), replies: .signature("y")), for: "me@a.dk")
        settings.forget(signatureID: "x")
        #expect(settings.rules.isEmpty)
        #expect(settings.defaults(for: "me@a.dk") == SignatureDefaults(newMail: nil, replies: .signature("y")))
    }

    // MARK: Storage and sync

    func store() throws -> MailStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidings-sig-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MailStore(path: dir.appendingPathComponent("mail.sqlite").path)
    }

    @Test func storesSignaturesInOrderAndAdoptsPlainTextOnes() throws {
        let store = try store()
        let logo = SignatureImage(filename: "logo.png", mimeType: "image/png", data: Self.png)
        let a = Signature(name: "Full", html: Self.creativeOak)
        let b = Signature(name: "Short", html: #"<p>Heine</p><img src="cid:\#(logo.contentID)">"#, images: [logo], customPlainText: "Heine")
        try store.saveSignatures([b, a])
        #expect(try store.signatures() == [b, a])

        let identities = [Identity(address: "Heine@CreativeOak.dk", name: "Heine", signature: "Heine\nCreative Oak"),
                          Identity(address: "heine@icloud.com", name: "Heine", signature: "")]
        #expect(try store.adoptPlainTextSignatures(identities))
        #expect(try !store.adoptPlainTextSignatures(identities), "only once")
        let all = try store.signatures()
        #expect(all.count == 3 && all.last?.plainText == "Heine\nCreative Oak")
        #expect(try store.signatureSettings().defaults(for: "heine@creativeoak.dk").newMail == .signature(all[2].id))
        #expect(try store.signatureSettings().defaults["heine@icloud.com"] == nil)
    }

    @Test func signaturesAndTheirRulesSyncToAnotherDevice() throws {
        let cloud = CloudStateTests.FakeCloud()
        let mac = try CloudStateTests.Device("mac")
        let phone = try CloudStateTests.Device("phone")
        let logo = SignatureImage(filename: "logo.png", mimeType: "image/png", data: Self.png)
        let full = Signature(name: "Full", html: #"<p>Heine</p><img src="cid:\#(logo.contentID)">"#, images: [logo])
        let short = Signature(name: "Short", html: "<p>H</p>")
        var settings = SignatureSettings(rules: [SignatureRule(domains: ["creativeoak.dk"], use: .signature(short.id))])
        settings.setDefaults(SignatureDefaults(newMail: .signature(full.id), replies: .signature(short.id)), for: "heine@creativeoak.dk")
        try mac.store.saveSignatures([full, short])
        try mac.store.saveSignatureSettings(settings)

        try mac.store.collectCloudChanges(accounts: mac.accounts)
        try cloud.push(mac.store)
        let report = try cloud.pull(into: phone.store, accounts: phone.accounts)
        #expect(report.changedTypes.isSuperset(of: [StateRecordType.signature.rawValue, StateRecordType.signatureSettings.rawValue]))
        #expect(try phone.store.signatures() == [full, short])
        #expect(try phone.store.signatureSettings() == settings)

        // Deleted on the Mac: gone on the phone.
        try mac.store.saveSignatures([full])
        try mac.store.collectCloudChanges(accounts: mac.accounts)
        let deletions = try mac.store.pendingCloudChanges().compactMap { change -> (String, String)? in
            if case .delete(let type, let key) = change { return (type, key) } else { return nil }
        }
        #expect(deletions.map(\.1) == [short.id])
        try cloud.push(mac.store)
        _ = try cloud.pull(into: phone.store, accounts: phone.accounts, deleted: deletions)
        #expect(try phone.store.signatures() == [full])
    }
}
