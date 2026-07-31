@testable import Epos

/// Fake backend recording every insert/delete so tests can assert exactly
/// what would have been typed into the focused field.
final class RecordingTextInsertionBackend: TextInsertionBackend {
    enum Operation: Equatable {
        case insert(String)
        case delete(Int)
    }

    private(set) var operations: [Operation] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    /// Inserted strings, in order — convenience for tests that only care about
    /// what was typed.
    var insertedTexts: [String] {
        operations.compactMap { if case .insert(let text) = $0 { text } else { nil } }
    }

    /// Replays the recorded inserts/deletes to reconstruct the focused field's
    /// contents — the assertion that matters for self-correction.
    var fieldText: String {
        operations.reduce(into: "") { field, operation in
            switch operation {
            case .insert(let text): field += text
            case .delete(let count): field.removeLast(min(count, field.count))
            }
        }
    }

    func startInsertionSession() -> any TextInsertionSession {
        RecordingTextInsertionSession(backend: self)
    }

    fileprivate func record(_ operation: Operation) {
        operations.append(operation)
    }

    private func finishSession() {
        finishCount += 1
    }

    private func cancelSession() {
        cancelCount += 1
    }

    private final class RecordingTextInsertionSession: TextInsertionSession {
        private let backend: RecordingTextInsertionBackend

        init(backend: RecordingTextInsertionBackend) {
            self.backend = backend
        }

        func insert(_ text: String) -> Bool {
            backend.record(.insert(text))
            return true
        }

        func finish() {
            backend.finishSession()
        }

        func cancel() {
            backend.cancelSession()
        }
    }
}
