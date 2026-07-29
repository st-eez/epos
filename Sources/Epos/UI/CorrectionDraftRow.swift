import SwiftUI

struct CorrectionDraftRow: View {
    @Binding var row: CorrectionDraft

    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            orderControls
                .frame(width: 56)
            heardPhrasesFields
                .frame(minWidth: 330, maxWidth: .infinity)
            correctionField("replacement", text: $row.canonical, isInvalid: row.trimmedCanonical.isEmpty)
                .frame(width: 170)
            matchStrategyPicker
                .frame(width: 116)
            correctionField("optional", text: $row.contextsText, isInvalid: false)
                .frame(width: 170)
            Button(role: .destructive, action: remove) {
                Image(systemName: "trash")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Delete")
            .frame(width: 32)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var heardPhrasesFields: some View {
        if row.matchStrategy == .personNameSlot {
            VStack(spacing: 4) {
                correctionField(
                    "name-context phrase, another phrase",
                    text: $row.aliasesText,
                    isInvalid: row.aliases.isEmpty
                )
                correctionField(
                    "always-safe phrase (optional)",
                    text: $row.safeAliasesText,
                    isInvalid: false
                )
            }
        } else {
            correctionField(
                "spoken phrase, another phrase",
                text: $row.aliasesText,
                isInvalid: row.aliases.isEmpty
            )
        }
    }

    private var orderControls: some View {
        HStack(spacing: 2) {
            Button(action: moveUp) {
                Image(systemName: "chevron.up")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveUp)
            .help("Move up")

            Button(action: moveDown) {
                Image(systemName: "chevron.down")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveDown)
            .help("Move down")
        }
    }

    private var matchStrategyPicker: some View {
        Picker("", selection: $row.matchStrategy) {
            Text("Literal").tag(TranscriptCanonicalizer.Rule.MatchStrategy.literal)
            Text("Name").tag(TranscriptCanonicalizer.Rule.MatchStrategy.personNameSlot)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .help("Match mode")
    }

    private func correctionField(_ placeholder: String, text: Binding<String>, isInvalid: Bool) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isInvalid ? Color.orange.opacity(0.85) : Color.gray.opacity(0.24), lineWidth: 1)
            )
    }
}
