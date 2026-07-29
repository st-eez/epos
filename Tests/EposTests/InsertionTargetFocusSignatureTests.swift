import XCTest
@testable import Epos

final class InsertionTargetFocusSignatureTests: XCTestCase {
    func testOpaqueSignatureProvesSameIdentifier() {
        let baseline = signature(identifier: "terminal-input")
        let sameTarget = signature(identifier: "terminal-input")
        let differentTarget = signature(identifier: "terminal-search")

        XCTAssertTrue(InsertionTargetFocusSignature.provesSameTarget(
            from: baseline,
            to: sameTarget
        ))
        XCTAssertFalse(InsertionTargetFocusSignature.provesSameTarget(
            from: baseline,
            to: differentTarget
        ))
    }

    func testOpaqueSignatureRefusesOneSidedReadFailure() {
        let baseline = signature(identifier: "terminal-input")
        let identifierTimedOut = signature(identifier: nil)

        XCTAssertFalse(InsertionTargetFocusSignature.provesSameTarget(
            from: baseline,
            to: identifierTimedOut
        ))
        XCTAssertFalse(InsertionTargetFocusSignature.provesSameTarget(
            from: baseline,
            to: nil
        ))
    }

    func testOpaqueSignatureRefusesIdentifierlessTargets() {
        let baseline = signature(identifier: nil)
        let indistinguishableOtherTarget = signature(identifier: nil)

        XCTAssertFalse(InsertionTargetFocusSignature.provesSameTarget(
            from: baseline,
            to: indistinguishableOtherTarget
        ))
    }

    private func signature(identifier: String?) -> InsertionTargetFocusSignature {
        InsertionTargetFocusSignature(
            role: "AXTextArea",
            subrole: nil,
            identifier: identifier
        )
    }
}
