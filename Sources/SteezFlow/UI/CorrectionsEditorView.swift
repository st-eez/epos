import SwiftUI

struct CorrectionsEditorView: View {
    @State private var customRules: [TranscriptCanonicalizer.Rule] = TranscriptCanonicalizer.customRules()
    @State private var newAlias = ""
    @State private var newCanonical = ""

    private let defaultRules = TranscriptCanonicalizer.defaultRules

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            addRow
            rulesList
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { customRules = TranscriptCanonicalizer.customRules() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Corrections", systemImage: "text.badge.checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Spacer(minLength: 8)
            Text("\(customRules.count) custom / \(defaultRules.count) built-in")
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
                if !customRules.isEmpty {
                    sectionLabel("Custom")
                    ForEach(customRules.indices, id: \.self) { index in
                        correctionRow(rule: customRules[index], badge: "Custom") {
                            removeCorrection(at: index)
                        }
                    }
                }

                sectionLabel("Built-in")
                ForEach(defaultRules.indices, id: \.self) { index in
                    correctionRow(rule: defaultRules[index], badge: "Built-in", remove: nil)
                }
            }
        }
        .frame(height: 156)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.42))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
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
        badge: String,
        remove: (() -> Void)?
    ) -> some View {
        HStack(spacing: 6) {
            Text(aliasSummary(rule))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.64))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.34))
            Text(rule.canonical)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(badge)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
            if let remove {
                Button { remove() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(PlainIconButtonStyle())
                .help("Remove correction")
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 22, height: 22)
                    .help("Built-in correction")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
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

        customRules.append(.init(canonical: canonical, aliases: [alias]))
        TranscriptCanonicalizer.saveCustomRules(customRules)
        newAlias = ""
        newCanonical = ""
    }

    private func removeCorrection(at index: Int) {
        guard customRules.indices.contains(index) else { return }
        customRules.remove(at: index)
        TranscriptCanonicalizer.saveCustomRules(customRules)
    }

    private func aliasSummary(_ rule: TranscriptCanonicalizer.Rule) -> String {
        let aliases = rule.aliases.isEmpty ? [rule.canonical] : rule.aliases
        let head = aliases.prefix(2).joined(separator: ", ")
        let extra = aliases.count > 2 ? " +\(aliases.count - 2)" : ""
        return head + extra
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
