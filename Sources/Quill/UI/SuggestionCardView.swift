import SwiftUI

struct SuggestionCardModel {
    let title: String
    let corrected: AttributedString
    let correctedText: String
    let engineLabel: String
    let onAccept: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void
    let onRephrase: () -> Void
    let onImprove: () -> Void
}

struct SuggestionCardView: View {
    let model: SuggestionCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(model.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: model.onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(model.corrected)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Accept", action: model.onAccept)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Copy", action: model.onCopy)
                    .controlSize(.small)
                Divider()
                    .frame(height: 14)
                Button("Rephrase", action: model.onRephrase)
                    .controlSize(.small)
                Button("Improve", action: model.onImprove)
                    .controlSize(.small)
                Spacer()
                Text(model.engineLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}
