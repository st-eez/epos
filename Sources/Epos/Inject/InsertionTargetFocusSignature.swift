import Foundation

struct InsertionTargetFocusSignature: Equatable {
    let role: String?
    let subrole: String?
    let identifier: String?

    var isInformative: Bool {
        role != nil || subrole != nil || identifier != nil
    }

    /// Proves that two regenerated opaque AX elements identify the same target.
    /// A matching identifier is required because role and frame alone cannot
    /// distinguish same-size tabs or compose surfaces. Unknown is a refusal:
    /// final-only delivery has not typed anything yet, so failing closed loses no
    /// already-inserted text and cannot corrupt another target.
    static func provesSameTarget(
        from baseline: InsertionTargetFocusSignature?,
        to current: InsertionTargetFocusSignature?
    ) -> Bool {
        guard let baseline, let current else { return false }
        guard let baselineIdentifier = baseline.identifier,
              let currentIdentifier = current.identifier,
              baselineIdentifier == currentIdentifier else {
            return false
        }
        return !bothReadAndDiffer(baseline.role, current.role)
            && !bothReadAndDiffer(baseline.subrole, current.subrole)
    }

    private static func bothReadAndDiffer(_ baseline: String?, _ current: String?) -> Bool {
        guard let baseline, let current else { return false }
        return baseline != current
    }
}
