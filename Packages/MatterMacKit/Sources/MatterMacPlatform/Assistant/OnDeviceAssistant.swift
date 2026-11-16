import Foundation
public import MatterMacCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device language model (macOS 26 and later, with Apple Intelligence on).
/// Nothing leaves the Mac. Its context is small, so long conversations are condensed
/// in several requests (`AssistantSummarizer`).
public struct OnDeviceAssistant: AssistantProvider {
    public enum Availability: Hashable, Sendable {
        case available
        /// macOS before 26, or built without the framework.
        case needsNewerSystem
        case deviceNotEligible
        case appleIntelligenceOff
        /// Still downloading or preparing.
        case modelNotReady
    }

    /// The model holds about 4,000 tokens of instructions, input and answer together.
    public let maximumInputCharacters = 6_000

    public init() {}

    public static var availability: Availability {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .needsNewerSystem }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable: return .modelNotReady
        }
        #else
        return .needsNewerSystem
        #endif
    }

    /// Names of the languages the model handles, in the user's language, sorted. In any
    /// other language (Czech, for example) its answers are poor.
    public static var supportedLanguageNames: [String] {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return [] }
        let codes = Set(SystemLanguageModel.default.supportedLanguages.compactMap { $0.languageCode?.identifier })
        return codes.compactMap { Locale.current.localizedString(forLanguageCode: $0) }.sorted()
        #else
        return []
        #endif
    }

    public func respond(to request: AssistantRequest) async throws(AssistantError) -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), Self.availability == .available else { throw .unavailable }
        do {
            let session = LanguageModelSession(instructions: request.instructions)
            let options = GenerationOptions(maximumResponseTokens: request.task == .reply ? 200 : 600)
            return try await session.respond(to: request.input, options: options).content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw .inputTooLong
            case .guardrailViolation, .refusal: throw .refused
            case .rateLimited, .concurrentRequests: throw .rateLimited
            case .assetsUnavailable: throw .unavailable
            default: throw .failed(code: 0)
            }
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .failed(code: 0)
        }
        #else
        throw .unavailable
        #endif
    }
}
