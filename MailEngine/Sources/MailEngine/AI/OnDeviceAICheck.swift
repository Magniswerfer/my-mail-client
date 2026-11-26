import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

/// M0 check: is the on-device AI stack usable on this Mac, in Danish and English? (SPEC §5)
public enum OnDeviceAICheck {
    public struct Report: Sendable, Codable {
        public var systemLanguages: [String]
        public var foundationModelsAvailability: String
        public var foundationModelsSupportsDanish: Bool?
        public var foundationModelsSupportsEnglish: Bool?
        public var contextualEmbeddingDanish: String
        public var contextualEmbeddingEnglish: String
        public var sentenceEmbeddingDanish: Bool
        public var classificationSamples: [Sample] = []
    }

    public struct Sample: Sendable, Codable {
        public var language: String
        public var subject: String
        public var expected: String
        public var predicted: String?
        public var reason: String?
        public var milliseconds: Int?
        public var error: String?
    }

    public static func run(generate: Bool) async -> Report {
        var report = Report(
            systemLanguages: Locale.preferredLanguages,
            foundationModelsAvailability: "FoundationModels not importable",
            contextualEmbeddingDanish: embeddingStatus("da"),
            contextualEmbeddingEnglish: embeddingStatus("en"),
            sentenceEmbeddingDanish: sentenceEmbeddingDanish
        )
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: report.foundationModelsAvailability = "available"
        case .unavailable(let reason): report.foundationModelsAvailability = "unavailable: \(reason)"
        }
        report.foundationModelsSupportsDanish = model.supportsLocale(Locale(identifier: "da_DK"))
        report.foundationModelsSupportsEnglish = model.supportsLocale(Locale(identifier: "en_US"))
        if generate, case .available = model.availability {
            for sample in samples {
                report.classificationSamples.append(await classify(sample))
            }
        }
        #endif
        return report
    }

    static func embeddingStatus(_ language: String) -> String {
        #if canImport(NaturalLanguage)
        guard let embedding = NLContextualEmbedding(language: NLLanguage(rawValue: language)) else { return "no model for language" }
        return embedding.hasAvailableAssets ? "assets installed (dim \(embedding.dimension))" : "model exists, assets not downloaded"
        #else
        return "NaturalLanguage not available on this platform"
        #endif
    }

    static var sentenceEmbeddingDanish: Bool {
        #if canImport(NaturalLanguage)
        return NLEmbedding.sentenceEmbedding(for: .danish) != nil
        #else
        return false
        #endif
    }

    static let samples: [Sample] = [
        Sample(language: "da", subject: "Din ordre #48213 er afsendt — forventet levering torsdag", expected: "transactions"),
        Sample(language: "da", subject: "Ugens nyhedsbrev: 5 tips til en bedre have", expected: "newsletters"),
        Sample(language: "da", subject: "Black Friday: -40% på alle sko kun i dag!", expected: "advertising"),
        Sample(language: "da", subject: "Hej Magnus, har du tid til et møde om projektet i morgen?", expected: "primary"),
        Sample(language: "en", subject: "Your password was changed", expected: "updates"),
        Sample(language: "en", subject: "Anna commented on your photo", expected: "social"),
    ]

    #if canImport(FoundationModels)
    @Generable
    struct CategoryGuess {
        @Guide(description: "The inbox category of the email", .anyOf(["primary", "transactions", "updates", "newsletters", "advertising", "social"]))
        var category: String
        @Guide(description: "A short reason, at most 12 words, in English")
        var reason: String
    }

    static func classify(_ sample: Sample) async -> Sample {
        var result = sample
        let session = LanguageModelSession(instructions: """
            You sort emails into exactly one inbox category. Emails can be in Danish or English.
            primary: personal or work mail from a real person that expects attention.
            transactions: orders, receipts, invoices, shipping, bookings, payments.
            updates: account notices, security alerts, service notifications.
            newsletters: editorial content the user subscribed to.
            advertising: promotions, sales, marketing offers.
            social: notifications from social networks and community platforms.
            """)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let response = try await session.respond(
                to: "Subject: \(sample.subject)", generating: CategoryGuess.self
            )
            result.predicted = response.content.category
            result.reason = response.content.reason
        } catch {
            result.error = String(describing: error)
        }
        result.milliseconds = Int((clock.now - start).components.seconds * 1000)
            + Int((clock.now - start).components.attoseconds / 1_000_000_000_000_000)
        return result
    }
    #endif
}
