import SwiftUI

struct CorrectionsEditorView: View {
    @ObservedObject var store: CorrectionStore
    @State private var rows: [CorrectionDraft] = []
    @State private var savedRows: [CorrectionDraft] = []

    private var hasInvalidRows: Bool {
        rows.contains { !$0.isValid }
    }

    private var hasUnsavedChanges: Bool {
        rows != savedRows
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tableHeader
            rulesList
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Corrections", systemImage: "text.badge.checkmark")
                .font(.system(size: 16, weight: .semibold))
            Spacer(minLength: 12)
            Text("\(rows.count) entries")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Button { addCorrection() } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var tableHeader: some View {
        HStack(spacing: 10) {
            headerLabel("")
                .frame(width: 56)
            headerLabel("Heard phrases")
                .frame(minWidth: 330, maxWidth: .infinity, alignment: .leading)
            headerLabel("Use")
                .frame(width: 190, alignment: .leading)
            headerLabel("Context")
                .frame(width: 190, alignment: .leading)
            headerLabel("")
                .frame(width: 32)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var rulesList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if rows.isEmpty {
                    emptyState
                } else {
                    ForEach(rows.indices, id: \.self) { index in
                        CorrectionDraftRow(
                            row: $rows[index],
                            canMoveUp: index > 0,
                            canMoveDown: index < rows.count - 1,
                            moveUp: { moveCorrection(from: index, to: index - 1) },
                            moveDown: { moveCorrection(from: index, to: index + 1) },
                            remove: { removeCorrection(at: index) }
                        )
                        Divider()
                            .padding(.leading, 80)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.badge.xmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("No corrections")
                .font(.system(size: 14, weight: .semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            statusLabel
            Spacer(minLength: 12)
            Button("Restore Defaults") { restoreDefaults() }
            Button("Revert") { reload() }
                .disabled(!hasUnsavedChanges)
            Button("Save Changes") { saveRules() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!hasUnsavedChanges || hasInvalidRows)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if hasInvalidRows {
            Label("Complete highlighted entries", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if hasUnsavedChanges {
            Label("Unsaved changes", systemImage: "circle.fill")
                .foregroundStyle(.secondary)
        } else {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    private func headerLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func addCorrection() {
        rows.insert(.empty(), at: 0)
    }

    private func removeCorrection(at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.remove(at: index)
    }

    private func moveCorrection(from source: Int, to destination: Int) {
        guard rows.indices.contains(source), rows.indices.contains(destination) else { return }
        let row = rows.remove(at: source)
        rows.insert(row, at: destination)
    }

    private func restoreDefaults() {
        rows = CorrectionDraft.fromRules(TranscriptCanonicalizer.defaultRules)
    }

    private func reload() {
        let loadedRows = CorrectionDraft.fromRules(store.rules)
        rows = loadedRows
        savedRows = loadedRows
    }

    private func saveRules() {
        guard !hasInvalidRows else { return }
        store.save(rows.map(\.rule))
        savedRows = rows
    }
}
