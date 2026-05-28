import Foundation

/// Single in-memory source of truth for correction rules, shared by the coordinator
/// (which canonicalizes each final transcript) and the Corrections editor (which mutates
/// the rules). Backed by `UserDefaults` but loaded once — replacing the prior design where
/// the coordinator re-decoded rules from defaults on every insertion and the editor reached it
/// only through that global side channel.
@MainActor
public final class CorrectionStore: ObservableObject {
    @Published public private(set) var canonicalizer: TranscriptCanonicalizer
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.canonicalizer = .load(from: defaults)
    }

    public var rules: [TranscriptCanonicalizer.Rule] { canonicalizer.rules }

    public func canonicalize(_ text: String) -> String {
        canonicalizer.canonicalize(text)
    }

    /// Persist `rules` and refresh the live canonicalizer so the next insertion uses them.
    public func save(_ rules: [TranscriptCanonicalizer.Rule]) {
        TranscriptCanonicalizer.saveRules(rules, to: defaults)
        canonicalizer = TranscriptCanonicalizer(rules: rules)
    }
}
