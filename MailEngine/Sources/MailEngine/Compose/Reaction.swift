import Foundation

/// The reaction parts of an outgoing reaction mail.
public struct OutgoingReaction: Codable, Sendable, Hashable {
    /// The emoji; empty takes an earlier reaction back (RFC 9078).
    public var emoji: String
    /// Also carry Gmail's `text/vnd.google.email-reaction+json` part.
    public var includesGmailPart: Bool
    /// The human-readable alternative for clients that know neither format.
    public var html: String

    public init(emoji: String, includesGmailPart: Bool, html: String) {
        self.emoji = emoji
        self.includesGmailPart = includesGmailPart
        self.html = html
    }
}

extension OutgoingMessage {
    /// Gmail ignores reactions to mail with more To/Cc recipients than this.
    public static let gmailReactionRecipientLimit = 20

    /// "Re: …" unless the subject already is a reply (Re:, Sv:, Aw:).
    public static func replySubject(_ subject: String) -> String {
        let lower = subject.lowercased()
        return ["re:", "sv:", "aw:"].contains(where: { lower.hasPrefix($0) }) ? subject : "Re: \(subject)"
    }

    /// A reaction mail to `original`, ready to queue like any other message
    /// (`AccountSync.queue(_:kind: .new)`). nil when the original has no Message-ID or sender,
    /// or `emoji` isn't one. An empty `emoji` takes your reaction back. `caption` is the
    /// human-readable line after the emoji (default "<name> reacted to your message"); pass
    /// a localized one if you like.
    public static func reaction(_ emoji: String, from identity: MailAddress, to original: ParsedMessage,
                                caption: String? = nil, date: Date = Date()) -> OutgoingMessage? {
        guard let messageID = original.messageID, let sender = original.from.first else { return nil }
        var references = original.references
        if !references.contains(messageID) { references.append(messageID) }
        return reaction(emoji, from: identity, toSender: sender, subject: original.subject, messageID: messageID,
                        references: references, recipientCount: original.to.count + original.cc.count,
                        caption: caption, date: date)
    }

    /// The same from a stored message (its References are approximated by the thread root and
    /// the message it answered).
    public static func reaction(_ emoji: String, from identity: MailAddress, to original: StoredMessage,
                                caption: String? = nil, date: Date = Date()) -> OutgoingMessage? {
        guard let messageID = original.messageID, !original.fromAddress.isEmpty else { return nil }
        var references: [String] = []
        // A thread id is the root Message-ID, or a local fallback key ("account/mailbox/…").
        if let root = original.threadID, root.contains("@"), !root.contains("/") { references.append(root) }
        if let parent = original.inReplyTo, !references.contains(parent) { references.append(parent) }
        if !references.contains(messageID) { references.append(messageID) }
        return reaction(emoji, from: identity,
                        toSender: MailAddress(name: original.fromName, address: original.fromAddress),
                        subject: original.subject, messageID: messageID, references: references,
                        recipientCount: AddressParser.parse(original.recipients).count, caption: caption, date: date)
    }

    /// The general form: everything the reaction needs from the original, spelled out.
    public static func reaction(_ emoji: String, from identity: MailAddress, toSender sender: MailAddress, subject: String,
                                messageID: String, references: [String], recipientCount: Int,
                                caption: String? = nil, date: Date = Date()) -> OutgoingMessage? {
        let emoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard emoji.isEmpty || ReactionDetector.isEmojiText(emoji) else { return nil }
        let name = identity.name.flatMap { $0.isEmpty ? nil : $0 } ?? identity.address
        let line = caption ?? (emoji.isEmpty ? "\(name) removed their reaction" : "\(name) reacted to your message")
        let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body><p>"
            + (emoji.isEmpty ? "" : "\(emoji) ") + escapeHTML(line) + "</p></body></html>"
        var message = OutgoingMessage(from: identity, to: [sender], subject: replySubject(subject), text: emoji,
                                      inReplyTo: messageID, references: references, date: date)
        message.reaction = OutgoingReaction(
            emoji: emoji, includesGmailPart: !emoji.isEmpty && recipientCount <= gmailReactionRecipientLimit, html: html)
        return message
    }

    static func escapeHTML(_ s: String) -> String {
        SignatureHTML.escape(s).replacingOccurrences(of: "'", with: "&#39;")
    }
}

extension MIMEBuilder {
    /// `multipart/alternative` of, in order: the RFC 9078 reaction part (text/plain with
    /// `Content-Disposition: reaction`), Gmail's JSON part, and an HTML line for everyone else.
    static func reactionPart(_ r: OutgoingReaction) -> Part {
        var parts = [Part.quotedPrintableText(r.emoji, contentType: "text/plain; charset=utf-8",
                                              extraHeaders: ["Content-Disposition: reaction"])]
        if r.includesGmailPart {
            let escaped = r.emoji.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            parts.append(.quotedPrintableText("{\"version\":1,\"emoji\":\"\(escaped)\"}",
                                              contentType: "\(ReactionParts.gmailType); charset=utf-8"))
        }
        parts.append(.quotedPrintableText(r.html, contentType: "text/html; charset=utf-8"))
        return multipart("alternative", parts)
    }
}
