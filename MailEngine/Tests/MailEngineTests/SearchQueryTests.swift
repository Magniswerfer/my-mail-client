import Foundation
import Testing
@testable import MailEngine

@Suite struct SearchQueryTests {
    @Test func parsesOperatorsAndFreeText() {
        let q = SearchQuery(parsing: #"faktura from:zalando has:attachment category:ads after:2024-01-01 larger:5M -spam "din pakke""#)
        #expect(q.terms == ["faktura"])
        #expect(q.from == ["zalando"])
        #expect(q.hasAttachment == true)
        #expect(q.categories == [.advertising])
        #expect(q.after != nil)
        #expect(q.largerThan == 5 * 1_048_576)
        #expect(q.excluded == ["spam"])
        #expect(q.phrases == ["din pakke"])
    }

    @Test func quotedOperatorValues() {
        let q = SearchQuery(parsing: #"from:"Anna Jensen" in:Archive"#)
        #expect(q.from == ["Anna Jensen"])
        #expect(q.mailbox == "Archive")
    }

    @Test func termsBecomePrefixMatches() {
        #expect(SearchQuery(parsing: "fak").ftsExpression == #""fak"*"#)
        #expect(SearchQuery(parsing: "sko -nike").ftsExpression == #""sko"* NOT "nike"*"#)
        #expect(SearchQuery(parsing: "from:anna").ftsExpression == #"sender : "anna"*"#)
        #expect(SearchQuery(parsing: "has:attachment").ftsExpression == nil)
    }

    @Test func facetsWaitForTwoCharacters() {
        #expect(!SearchQuery(parsing: "f").wantsFacets)
        #expect(SearchQuery(parsing: "fa").wantsFacets)
        #expect(SearchQuery(parsing: "f has:attachment").wantsFacets)
    }

    @Test func unknownOperatorIsJustText() {
        let q = SearchQuery(parsing: "re:hello category:nonsense")
        #expect(q.terms == ["re:hello", "category:nonsense"])
    }

    @Test func danishCategoryAliases() {
        #expect(SearchQuery(parsing: "category:nyhedsbreve").categories == [.newsletters])
    }
}

@Suite struct MailboxRoleTests {
    @Test func iCloudNamesWithoutSpecialUse() {
        let boxes = ["INBOX", "Sent Messages", "Deleted Messages", "Junk", "Archive", "Drafts", "Clients/Archive"]
            .map { MailboxListing(path: $0, separator: "/", attributes: []) }
        let roles = MailboxRoleResolver.resolve(boxes)
        #expect(roles[.inbox] == "INBOX")
        #expect(roles[.sent] == "Sent Messages")
        #expect(roles[.trash] == "Deleted Messages")
        #expect(roles[.junk] == "Junk")
        #expect(roles[.archive] == "Archive")
        #expect(roles[.drafts] == "Drafts")
    }

    @Test func localizedDanishNames() {
        let boxes = ["Sendt", "Papirkurv", "Uønsket post", "Arkiv"].map { MailboxListing(path: $0, separator: "/", attributes: []) }
        let roles = MailboxRoleResolver.resolve(boxes)
        #expect(roles[.sent] == "Sendt")
        #expect(roles[.trash] == "Papirkurv")
        #expect(roles[.junk] == "Uønsket post")
        #expect(roles[.archive] == "Arkiv")
    }

    @Test func specialUseWinsOverNames() {
        let boxes = [
            MailboxListing(path: "Sent", separator: "/", attributes: []),
            MailboxListing(path: "Outbox Copies", separator: "/", attributes: ["\\Sent"]),
        ]
        #expect(MailboxRoleResolver.resolve(boxes)[.sent] == "Outbox Copies")
    }
}

@Suite struct TestFenceTests {
    @Test func onlyFencedMailboxesAreMutable() {
        #expect(TestFence.isInsideFence("Tidings-Test"))
        #expect(TestFence.isInsideFence("Tidings-Test/Moved"))
        #expect(!TestFence.isInsideFence("INBOX"))
        #expect(!TestFence.isInsideFence("Junk"))
        #expect(!TestFence.isInsideFence("Tidings-Testing"))
        #expect(!TestFence.isInsideFence("Archive/Tidings-Test"))
    }
}
