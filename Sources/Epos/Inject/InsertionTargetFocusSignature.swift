import CoreGraphics
import Foundation

struct InsertionTargetFocusFrame: Equatable {
    private static let sameTargetOriginTolerance = 24

    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// AX is a system boundary: a transitioning AX server can hand back
    /// non-finite frame components, and `Int(_: Double)` traps on NaN/±inf.
    /// Fail soft to nil — "frame unreadable" — like every other AX read here.
    init?(position: CGPoint, size: CGSize) {
        guard let x = Int(exactly: position.x.rounded()),
              let y = Int(exactly: position.y.rounded()),
              let width = Int(exactly: size.width.rounded()),
              let height = Int(exactly: size.height.rounded()) else {
            return nil
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    func hasSameApproximateOrigin(as other: InsertionTargetFocusFrame) -> Bool {
        abs(x - other.x) <= Self.sameTargetOriginTolerance
            && abs(y - other.y) <= Self.sameTargetOriginTolerance
    }
}

struct InsertionTargetFocusSignature: Equatable {
    let role: String?
    let subrole: String?
    let identifier: String?
    let frame: InsertionTargetFocusFrame?

    var isInformative: Bool {
        role != nil || subrole != nil || identifier != nil || frame != nil
    }

    /// Signature reads run under a short messaging timeout, so any attribute can
    /// read nil on one side just because the target's AX server was momentarily
    /// slow. A one-sided nil is therefore "unknown", never a change — only two
    /// successful, differing reads count. A false abort mid-dictation is worse
    /// than a missed same-app move (the value guard still bounds deletes there).
    static func changedWithinSameProcess(
        from baseline: InsertionTargetFocusSignature?,
        to current: InsertionTargetFocusSignature?
    ) -> Bool {
        guard let baseline, let current else { return false }
        if let baselineIdentifier = baseline.identifier, let currentIdentifier = current.identifier {
            if baselineIdentifier != currentIdentifier { return true }
            // A matching identifier is authoritative same-element; skip the frame
            // check so the field stays free to move, scroll, or resize.
            return bothReadAndDiffer(baseline.role, current.role)
                || bothReadAndDiffer(baseline.subrole, current.subrole)
        }
        if bothReadAndDiffer(baseline.role, current.role)
            || bothReadAndDiffer(baseline.subrole, current.subrole) {
            return true
        }
        guard let baselineFrame = baseline.frame, let currentFrame = current.frame else {
            return false
        }
        return !baselineFrame.hasSameApproximateOrigin(as: currentFrame)
    }

    private static func bothReadAndDiffer(_ baseline: String?, _ current: String?) -> Bool {
        guard let baseline, let current else { return false }
        return baseline != current
    }
}
