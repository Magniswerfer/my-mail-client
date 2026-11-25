import Foundation
import MailEngine
import SwiftUI

/// Snippets (`;keyword` expands as you type, SPEC §9).
struct Snippet: Codable, Hashable, Identifiable {
    var id = UUID()
    var keyword: String
    var text: String
}

enum SnippetStore {
    static let key = "compose.snippets"

    static var all: [Snippet] {
        get { (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// Variables filled in at expansion.
    static func expand(_ snippet: Snippet, context: SnippetContext) -> String {
        snippet.text
            .replacingOccurrences(of: "{first}", with: context.firstName)
            .replacingOccurrences(of: "{name}", with: context.fullName)
            .replacingOccurrences(of: "{me}", with: context.myName)
            .replacingOccurrences(of: "{date}", with: Date().formatted(date: .long, time: .omitted))
    }
}

/// Who the open draft is to and from (set by the composer, read by the editor).
struct SnippetContext {
    var firstName = ""
    var fullName = ""
    var myName = ""
    @MainActor static var current = SnippetContext()
}

extension AppModel {
    /// The composer calls this with who the message is to and from.
    func setSnippetContext(to: [MailAddress], from identity: Identity) {
        let first = to.first
        SnippetContext.current = SnippetContext(firstName: first.map(IntroReply.firstName) ?? "",
                                                fullName: first?.name ?? first?.address ?? "",
                                                myName: identity.name)
    }
}
