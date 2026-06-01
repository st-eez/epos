import Foundation

/// The single source of the filler vocabulary the polish stage reasons about.
/// Both the content-retention guard (`TranscriptPolisher`) and the engine prompt
/// (`FoundationModelsPolishEngine`) consume it, so the two can never disagree
/// about what counts as a filler the model may remove.
///
/// Spoken-symbol conversion ("dash dash" → "--", "slash" → "/") is deliberately
/// NOT here: it is owned solely by `TranscriptCanonicalizer`, which runs on both
/// the raw and polished text. The model is told to leave such words alone and the
/// guard treats them as content, so the only symbol conversions that reach the
/// user are the canonicalizer's deterministic, both-sides rules — never a model
/// guess the guard cannot safely police.
public enum PolishVocabulary {
    /// Single-token disfluencies the model is allowed to drop. Deliberately MINIMAL:
    /// only the pure non-words with no content sense. `so` is handled separately
    /// (only droppable sentence-initially) and is intentionally absent; `like` is
    /// handled by its own `isDroppableLike` arm in the guard, so it is absent here
    /// too (it would be dead — the explicit `if raw == "like"` reject arm shadows
    /// this set). "basically" is omitted on purpose: it is a content-bearing degree
    /// adverb ("basically identical" ≠ "identical"), not a removable disfluency.
    /// Multi-token phrases ("you know", "kind of", …) are likewise NOT droppable:
    /// each has a common content use ("what kind of car", "explain what I mean") the
    /// guard cannot distinguish from a verbal tic, so it keeps them.
    public static let singleFillers: Set<String> = ["um", "uh", "er", "hmm"]

    /// Multi-token disfluency phrases. The guard does NOT drop these and the prompt
    /// does NOT name them: each has a common content use ("what kind of car",
    /// "explain what I mean", "sort of works") the guard cannot tell from a verbal
    /// tic, so it keeps them (a false reject is harmless; a false drop alters
    /// meaning). Retained only as the residual-filler signal for the offline polish
    /// quality eval (`PolishEvalTests`); do NOT re-wire it into the guard's
    /// drop-on-mismatch arm — that reopens the meaning-change hole this set used to
    /// have.
    public static let fillerPhrases: [[String]] = [
        ["you", "know"],
        ["i", "mean"],
        ["sort", "of"],
        ["kind", "of"],
    ]

    /// Words that, immediately before a "like", mark it as a content verb/subject
    /// ("seems like", "I like") rather than filler — so that "like" must survive.
    public static let semanticLikePrevious: Set<String> = [
        "i", "we", "you", "they", "he", "she", "it",
        "seem", "seems", "seemed",
        "look", "looks", "looked",
        "sound", "sounds", "sounded",
        "feel", "feels", "felt",
    ]

    /// Words that, immediately after a "like", mark it as a content verb
    /// ("like it", "like that") rather than filler.
    public static let semanticLikeNext: Set<String> = [
        "to", "it", "this", "that", "these", "those",
        "me", "us", "you", "him", "her", "them",
    ]
}
