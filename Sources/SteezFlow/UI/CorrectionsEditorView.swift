import SwiftUI

struct CorrectionsEditorView: View {
    @State private var rules: [TranscriptCanonicalizer.Rule] = TranscriptCanonicalizer.rules()
    @State private var newAlias = ""
    @State private var newCanonical = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            addRow
            rulesList
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { rules = TranscriptCanonicalizer.rules() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Corrections", systemImage: "text.badge.checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Spacer(minLength: 8)
            Text("\(rules.count) corrections")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var addRow: some View {
        HStack(spacing: 6) {
            correctionField("Heard", text: $newAlias)
            correctionField("Use", text: $newCanonical)
            Button { addCorrection() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(PlainIconButtonStyle())
            .disabled(!canAddCorrection)
            .help("Add correction")
        }
    }

    private var rulesList: some View {
        ScrollView {
            VStack(spacing: 7) {
                if rules.isEmpty {
                    Text("No corrections")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.46))
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                } else {
                    ForEach(rules.indices, id: \.self) { index in
                        correctionRow(rule: rules[index]) {
                            removeCorrection(at: index)
                        }
                    }
                }
            }
        }
        .frame(height: 156)
    }

    private func correctionField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private func correctionRow(
        rule: TranscriptCanonicalizer.Rule,
        remove: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.canonical)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
                Text(ruleDetail(rule))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.56))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { remove() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(PlainIconButtonStyle())
            .help("Remove correction")
        }
        .padding(8)
        .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var canAddCorrection: Bool {
        !newAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !newCanonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addCorrection() {
        let alias = newAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = newCanonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty, !canonical.isEmpty else { return }

        rules.insert(.init(canonical: canonical, aliases: [alias]), at: 0)
        TranscriptCanonicalizer.saveRules(rules)
        newAlias = ""
        newCanonical = ""
    }

    private func removeCorrection(at index: Int) {
        guard rules.indices.contains(index) else { return }
        rules.remove(at: index)
        TranscriptCanonicalizer.saveRules(rules)
    }

    private func ruleDetail(_ rule: TranscriptCanonicalizer.Rule) -> String {
        let aliases = rule.aliases.isEmpty ? [rule.canonical] : rule.aliases
        let aliasText = aliases.joined(separator: ", ")
        guard !rule.contexts.isEmpty else { return aliasText }
        return "\(aliasText) | context: \(rule.contexts.joined(separator: ", "))"
    }
}

private struct PlainIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(!isEnabled ? 0.28 : configuration.isPressed ? 0.52 : 0.72))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.1 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
    }
}
