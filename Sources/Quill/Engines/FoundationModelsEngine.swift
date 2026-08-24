import Foundation
import FoundationModels

@Generable
struct RewriteOutput {
    @Guide(description: "The resulting text after applying the requested edit to the user's text, and nothing else. Identical to the input if no changes are needed.")
    var text: String
}

/// On-device engine. Powers the automatic selection check and all explicit
/// actions (Rephrase/Improve) — never cloud.
final class FoundationModelsEngine: WritingEngine {
    let id = "apple-fm"
    let displayName = "Apple Intelligence (on-device)"

    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var statusDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Apple Intelligence: ready"
        case .unavailable(let reason):
            return "Apple Intelligence unavailable (\(reason))"
        @unknown default:
            return "Apple Intelligence: unknown state"
        }
    }

    func prewarm() {
        guard isAvailable else { return }
        let session = LanguageModelSession(instructions: WritingAction.proofread.instructions)
        session.prewarm()
    }

    func perform(_ action: WritingAction, on text: String) async throws -> String {
        let session = LanguageModelSession(instructions: action.instructions)
        let response = try await session.respond(
            to: "\(action.userPrefix)\n\n\(text)",
            generating: RewriteOutput.self,
            options: GenerationOptions(temperature: action == .proofread ? 0.1 : 0.6)
        )
        return sanitizeModelText(response.content.text)
    }

    func proofread(_ text: String) async throws -> String {
        try await perform(.proofread, on: text)
    }
}
