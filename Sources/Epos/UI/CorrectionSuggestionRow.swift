import SwiftUI

struct CorrectionSuggestionRow: View {
    let item: CorrectionSuggestionReviewItem
    let accept: () -> Void
    let reject: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.heardPhrase)
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(item.replacementText)
                        .font(.system(size: 13, weight: .semibold))
                }
                HStack(spacing: 10) {
                    Text("\(item.positiveEvidenceCount) matches")
                    Text("phrase \(item.phraseRiskName)")
                    Text("scope \(item.scopeRiskName)")
                    if !item.blockerNames.isEmpty {
                        Text(item.blockerNames.joined(separator: ", "))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                if let evidenceExampleText = item.evidenceExampleText {
                    HStack(spacing: 8) {
                        Text(evidenceExampleText)
                            .lineLimit(1)
                        if let evidenceContextText = item.evidenceContextText {
                            Text(evidenceContextText)
                                .lineLimit(1)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            Button(action: accept) {
                Image(systemName: "checkmark")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!item.canAccept)
            .help("Accept")

            Button(role: .destructive, action: reject) {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Reject")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }
}
