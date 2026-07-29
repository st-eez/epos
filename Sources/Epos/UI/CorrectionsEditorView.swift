import SwiftUI

struct CorrectionsEditorView: View {
    static let windowID = "corrections"

    @ObservedObject var store: CorrectionStore
    let evidenceStore: CorrectionEvidenceStore
    @State private var rows: [CorrectionDraft] = []
    @State private var savedRows: [CorrectionDraft] = []
    @State private var suggestionItems: [CorrectionSuggestionReviewItem] = []

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
            suggestionsSection
            tableHeader
            rulesList
            Divider()
            footer
        }
        .frame(minWidth: 980, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(store.isReadOnly)
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Corrections", systemImage: "text.badge.checkmark")
                .font(.system(size: 16, weight: .semibold))
            Spacer(minLength: 12)
            if !suggestionItems.isEmpty {
                Text("\(suggestionItems.count) suggestions")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
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

    @ViewBuilder
    private var suggestionsSection: some View {
        if !suggestionItems.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Label("Suggestions", systemImage: "wand.and.stars")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                ForEach(suggestionItems) { item in
                    CorrectionSuggestionRow(
                        item: item,
                        accept: { acceptSuggestion(item) },
                        reject: { rejectSuggestion(item) }
                    )
                    Divider()
                        .padding(.leading, 18)
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 10) {
            headerLabel("")
                .frame(width: 56)
            headerLabel("Heard phrases")
                .frame(minWidth: 330, maxWidth: .infinity, alignment: .leading)
            headerLabel("Use")
                .frame(width: 170, alignment: .leading)
            headerLabel("Mode")
                .frame(width: 116, alignment: .leading)
            headerLabel("Context")
                .frame(width: 170, alignment: .leading)
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
        if store.isReadOnly {
            Label("Read-only: contains unsupported correction data", systemImage: "lock.fill")
                .foregroundStyle(.secondary)
        } else if hasInvalidRows {
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
        rows = CorrectionDraft.fromRecords(CorrectionDictionary.defaultRecords)
    }

    private func reload() {
        let loadedRows = CorrectionDraft.fromRecords(store.dictionary.records)
        rows = loadedRows
        savedRows = loadedRows
        reloadSuggestions()
    }

    private func saveRules() {
        guard !hasInvalidRows else { return }
        let loadedRows = saveCorrectionDrafts(rows, to: store)
        rows = loadedRows
        savedRows = loadedRows
        reloadSuggestions()
    }

    private func reloadSuggestions() {
        suggestionItems = CorrectionSuggestionReviewItem.items(
            evidenceStore: evidenceStore,
            store: store
        )
    }

    private func acceptSuggestion(_ item: CorrectionSuggestionReviewItem) {
        guard store.acceptPromotion(item.assessment) else { return }
        guard hasUnsavedChanges else {
            reload()
            return
        }
        // Mid-edit a full reload() would clobber the user's unsaved rows and
        // reorders (rule precedence is order-dependent). Merge just the accepted
        // rule into both lists so the unsaved diff stays exactly the user's edits.
        let accepted = CorrectionDraft.newDrafts(
            in: CorrectionDraft.fromRecords(store.dictionary.records),
            notIn: savedRows
        )
        // A user may have already typed the same correction as an unsaved row —
        // appending it again would show (and later persist) a duplicate. The row
        // still joins savedRows: the store now owns that rule, so the matching
        // unsaved row correctly stops counting as an edit.
        for acceptedDraft in accepted {
            if let matchingIndex = rows.firstIndex(of: acceptedDraft) {
                rows[matchingIndex] = rows[matchingIndex].adoptingRecordIdentity(from: acceptedDraft)
            } else {
                rows.append(acceptedDraft)
            }
        }
        savedRows.append(contentsOf: accepted)
        reloadSuggestions()
    }

    private func rejectSuggestion(_ item: CorrectionSuggestionReviewItem) {
        guard store.rejectSuggestion(item.assessment) else { return }
        reloadSuggestions()
    }
}

@MainActor
func saveCorrectionDrafts(
    _ drafts: [CorrectionDraft],
    to store: CorrectionStore
) -> [CorrectionDraft] {
    store.saveEditorRecords(drafts.map(\.record))
    return CorrectionDraft.fromRecords(store.dictionary.records)
}
