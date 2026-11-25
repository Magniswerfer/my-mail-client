import Testing
@testable import MailEngine

@Suite struct MailWriterSignOffTests {
    @Test func aClosingAndNameAreDropped() {
        // Found in the click-through: the draft said "Best,\nMagnus" above the "-- Magnus" signature.
        let text = "Hi Sofie,\n\nYes, I'm available for a 15 minute call tomorrow. What time suits you?\n\nBest,\nMagnus"
        #expect(FoundationModelsWriter.stripSignOff(text)
                == "Hi Sofie,\n\nYes, I'm available for a 15 minute call tomorrow. What time suits you?")
        #expect(FoundationModelsWriter.stripSignOff("Hej Anna,\n\nDet lyder godt.\n\nMvh\nMagnus") == "Hej Anna,\n\nDet lyder godt.")
        #expect(FoundationModelsWriter.stripSignOff("Hej Anna,\n\nDet lyder godt.\n\nMed venlig hilsen,") == "Hej Anna,\n\nDet lyder godt.")
    }

    @Test func contentThatLooksLikeAClosingIsKept() {
        let thanks = "Hi Peter,\n\nGot the contract, I'll read it tonight. Thanks!"
        #expect(FoundationModelsWriter.stripSignOff(thanks) == thanks)
        let finalThanks = "Hi Peter,\n\nI'll read it tonight.\n\nThanks!"
        #expect(FoundationModelsWriter.stripSignOff(finalThanks) == finalThanks)
        #expect(FoundationModelsWriter.stripSignOff("Best,") == "Best,")   // nothing would be left
    }
}
