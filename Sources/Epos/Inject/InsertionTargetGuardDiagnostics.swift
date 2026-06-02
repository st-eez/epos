import Foundation

struct InsertionGuardEvaluation: Equatable {
    let decision: InsertionGuardDecision
    let reason: String
    let expectedChars: Int
    let observedChars: Int?
    let contextAvailable: Bool
    let baselinePrefixChars: Int?
    let baselineSuffixChars: Int?
    let caretAvailable: Bool
    let caretMatches: Bool?
    let textMatches: Bool?
    let suffixMatches: Bool?

    var logFields: String {
        [
            "decision=\(decision.diagnosticName)",
            "reason=\(reason)",
            "expectedChars=\(expectedChars)",
            "observedChars=\(Self.optional(observedChars))",
            "contextAvailable=\(contextAvailable)",
            "baselinePrefixChars=\(Self.optional(baselinePrefixChars))",
            "baselineSuffixChars=\(Self.optional(baselineSuffixChars))",
            "caretAvailable=\(caretAvailable)",
            "caretMatches=\(Self.optional(caretMatches))",
            "textMatches=\(Self.optional(textMatches))",
            "suffixMatches=\(Self.optional(suffixMatches))"
        ].joined(separator: " ")
    }

    private static func optional(_ value: Int?) -> String {
        value.map(String.init) ?? "nil"
    }

    private static func optional(_ value: Bool?) -> String {
        value.map(String.init) ?? "nil"
    }
}

extension InsertionGuardDecision {
    var diagnosticName: String {
        switch self {
        case .proceed:
            return "proceed"
        case .stopAppendOnly:
            return "stopAppendOnly"
        case .abort:
            return "abort"
        }
    }
}

extension InsertionTargetGuard {
    static func evaluate(expected: String, observed: InsertionTargetObservation) -> InsertionGuardEvaluation {
        switch observed {
        case .focusChanged:
            return evaluation(
                decision: .abort,
                reason: "focusChanged",
                expected: expected
            )
        case .notRead:
            return evaluation(
                decision: .proceed,
                reason: "notRead",
                expected: expected
            )
        case .emptyExposed:
            return evaluation(
                decision: expected.isEmpty ? .proceed : .stopAppendOnly,
                reason: expected.isEmpty ? "emptyExpected" : "emptyExposed",
                expected: expected,
                observedChars: 0
            )
        case .value(let onScreen):
            guard !expected.isEmpty else {
                return evaluation(
                    decision: .proceed,
                    reason: "emptyExpected",
                    expected: expected,
                    observedChars: onScreen.utf16.count
                )
            }
            let suffixMatches = onScreen.hasSuffix(expected)
            return evaluation(
                decision: suffixMatches ? .proceed : .stopAppendOnly,
                reason: suffixMatches ? "suffixMatch" : "suffixMismatch",
                expected: expected,
                observedChars: onScreen.utf16.count,
                suffixMatches: suffixMatches
            )
        case .positionedValue(let onScreen, let context, let selectedRange):
            let caretMatches = context.caretMatches(expected: expected, selectedRange: selectedRange)
            let textMatches = onScreen == context.prefix + expected + context.suffix
            guard !expected.isEmpty else {
                return evaluation(
                    decision: .proceed,
                    reason: "emptyExpected",
                    expected: expected,
                    observedChars: onScreen.utf16.count,
                    context: context,
                    caretAvailable: selectedRange != nil,
                    caretMatches: caretMatches,
                    textMatches: textMatches
                )
            }
            if textMatches && caretMatches {
                return evaluation(
                    decision: .proceed,
                    reason: "positionedMatch",
                    expected: expected,
                    observedChars: onScreen.utf16.count,
                    context: context,
                    caretAvailable: selectedRange != nil,
                    caretMatches: caretMatches,
                    textMatches: textMatches
                )
            }
            if selectedRange != nil, !caretMatches {
                return evaluation(
                    decision: .abort,
                    reason: "caretMismatch",
                    expected: expected,
                    observedChars: onScreen.utf16.count,
                    context: context,
                    caretAvailable: true,
                    caretMatches: false,
                    textMatches: textMatches
                )
            }
            return evaluation(
                decision: .stopAppendOnly,
                reason: "positionedTextMismatch",
                expected: expected,
                observedChars: onScreen.utf16.count,
                context: context,
                caretAvailable: selectedRange != nil,
                caretMatches: selectedRange == nil ? nil : caretMatches,
                textMatches: textMatches
            )
        }
    }

    private static func evaluation(
        decision: InsertionGuardDecision,
        reason: String,
        expected: String,
        observedChars: Int? = nil,
        context: InsertionTargetContext? = nil,
        caretAvailable: Bool = false,
        caretMatches: Bool? = nil,
        textMatches: Bool? = nil,
        suffixMatches: Bool? = nil
    ) -> InsertionGuardEvaluation {
        InsertionGuardEvaluation(
            decision: decision,
            reason: reason,
            expectedChars: expected.utf16.count,
            observedChars: observedChars,
            contextAvailable: context != nil,
            baselinePrefixChars: context?.prefix.utf16.count,
            baselineSuffixChars: context?.suffix.utf16.count,
            caretAvailable: caretAvailable,
            caretMatches: caretMatches,
            textMatches: textMatches,
            suffixMatches: suffixMatches
        )
    }
}
