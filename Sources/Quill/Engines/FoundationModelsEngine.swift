import Foundation
import FoundationModels

@Generable
struct RewriteOutput {
    @Guide(description: "The resulting text after applying the requested edit to the user's text, and nothing else. Identical to the input if no changes are needed.")
    var text: String
}

/// On-device engine. Powers the automatic selection check and all explicit
/// actions (Rephrase/Improve) — never cloud.
@MainActor
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

    /// Paragraph-level results for proofreading, so retyping one paragraph
    /// doesn't re-check the others. Bounded; oldest entries evicted.
    private var proofreadCache: [String: String] = [:]
    private var proofreadOrder: [String] = []

    /// The small model flattens multi-paragraph input into one block, which
    /// then shows up as bogus "corrections". Process paragraph by paragraph
    /// and reassemble with the original line breaks untouched.
    func perform(_ action: WritingAction, on text: String) async throws -> String {
        var output = ""
        for piece in Self.splitParagraphs(text) {
            if piece.isBreak || piece.text.trimmingCharacters(in: .whitespaces).isEmpty {
                output += piece.text
                continue
            }
            let leading = String(piece.text.prefix(while: { $0 == " " || $0 == "\t" }))
            let trailing = String(piece.text.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
            let core = String(piece.text.dropFirst(leading.count).dropLast(trailing.count))
            output += leading + (try await performParagraph(action, on: core)) + trailing
        }
        return output
    }

    private func performParagraph(_ action: WritingAction, on text: String) async throws -> String {
        if action == .proofread, let cached = proofreadCache[text] { return cached }
        let result = try await performSingle(action, on: text)
        if action == .proofread {
            proofreadCache[text] = result
            proofreadOrder.append(text)
            if proofreadOrder.count > 300 {
                proofreadCache.removeValue(forKey: proofreadOrder.removeFirst())
            }
        }
        return result
    }

    struct Piece { let text: String; let isBreak: Bool }

    /// Splits into alternating paragraph and line-break runs, lossless.
    static func splitParagraphs(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var current = ""
        var currentIsBreak = false
        for ch in text {
            let isBreak = ch == "\n" || ch == "\r" || ch == "\u{2029}" || ch == "\u{2028}"
            if !current.isEmpty && isBreak != currentIsBreak {
                pieces.append(Piece(text: current, isBreak: currentIsBreak))
                current = ""
            }
            current.append(ch)
            currentIsBreak = isBreak
        }
        if !current.isEmpty { pieces.append(Piece(text: current, isBreak: currentIsBreak)) }
        return pieces
    }

    private func performSingle(_ action: WritingAction, on text: String) async throws -> String {
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
