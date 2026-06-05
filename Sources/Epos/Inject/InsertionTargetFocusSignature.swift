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

    init(position: CGPoint, size: CGSize) {
        x = Int(position.x.rounded())
        y = Int(position.y.rounded())
        width = Int(size.width.rounded())
        height = Int(size.height.rounded())
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

    static func changedWithinSameProcess(
        from baseline: InsertionTargetFocusSignature?,
        to current: InsertionTargetFocusSignature?
    ) -> Bool {
        guard let baseline, let current else { return false }
        if baseline.identifier != nil || current.identifier != nil {
            return baseline.role != current.role
                || baseline.subrole != current.subrole
                || baseline.identifier != current.identifier
        }
        if baseline.role != current.role || baseline.subrole != current.subrole {
            return true
        }
        guard let baselineFrame = baseline.frame, let currentFrame = current.frame else {
            return false
        }
        return !baselineFrame.hasSameApproximateOrigin(as: currentFrame)
    }
}
