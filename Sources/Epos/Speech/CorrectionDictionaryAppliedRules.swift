import Foundation

public extension CorrectionDictionary {
    func appliedRecordIDs(in text: String) -> [String] {
        TranscriptCanonicalizer(records: records).canonicalizeWithProvenance(text).appliedRecordIDs
    }
}
