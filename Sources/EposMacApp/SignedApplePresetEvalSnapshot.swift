#if DEBUG
import CryptoKit
import Epos
import Foundation

/// One dictionary snapshot supplies both recognition vocabulary and final cleanup.
struct ApplePresetEvalSnapshot {
    typealias Recognize = @Sendable (URL, Locale, ApplePresetArm, [String]) async throws -> ApplePresetTranscription

    let canonicalizer: TranscriptCanonicalizer
    let dictionaryFingerprint: String
    let dictionaryRecords: [CorrectionRecord]
    let contextualStrings: [String]

    init(dictionary: CorrectionDictionary) throws {
        dictionaryRecords = dictionary.records
        canonicalizer = TranscriptCanonicalizer(rules: CorrectionRuleCompiler.compile(records: dictionary.records))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        dictionaryFingerprint = SHA256.hash(data: try encoder.encode(dictionary.records))
            .map { String(format: "%02x", $0) }.joined()
        contextualStrings = Transcriber.analysisContext(
            contextualStrings: ["Epos"] + canonicalizer.speechContextualStrings
        )?.contextualStrings[.general] ?? []
    }

    func context(for arm: ApplePresetArm) -> [String] {
        arm == .baseline ? contextualStrings : []
    }

    func transcribe(
        recording: URL,
        locale: Locale,
        arm: ApplePresetArm,
        recognize: Recognize = { recording, locale, arm, context in
            try await ApplePresetTranscriber.transcribe(
                recording: recording, locale: locale, arm: arm, contextualStrings: context
            )
        }
    ) async throws -> ApplePresetTranscription {
        let expected = context(for: arm)
        let result = try await recognize(recording, locale, arm, expected)
        guard result.contextReadback == expected else {
            throw ApplePresetContextError.readbackMismatch
        }
        return result
    }
}

enum ApplePresetContextError: Error {
    case readbackMismatch
}

struct ApplePresetEvalProvenance: Codable {
    let corpusSHA256: String
    let sourceRevision: String?
    let sourceTreeDirty: Bool?
    let buildConfiguration: String?
    let compilerOptimization: String?
    let sdk: String?
    let osVersion: String
    let architecture: String
    let bundleIdentifier: String?
    let bundleVersion: String?
    let executableSHA256: String
    let startedAt: String

    init(corpusURL: URL, bundle: Bundle = .main) throws {
        corpusSHA256 = try Self.fileSHA256(corpusURL)
        let info = bundle.infoDictionary ?? [:]
        sourceRevision = info["EposSourceRevision"] as? String
        sourceTreeDirty = (info["EposSourceTreeDirty"] as? String).flatMap {
            switch $0 {
            case "0": false
            case "1": true
            default: nil
            }
        }
        buildConfiguration = info["EposBuildConfiguration"] as? String
        compilerOptimization = info["EposCompilerOptimization"] as? String
        sdk = info["DTSDKName"] as? String
        osVersion = ProcessInfo.processInfo.operatingSystemVersionString
#if arch(arm64)
        architecture = "arm64"
#else
        architecture = "x86_64"
#endif
        bundleIdentifier = bundle.bundleIdentifier
        bundleVersion = info["CFBundleVersion"] as? String
        guard let executableURL = bundle.executableURL else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        executableSHA256 = try Self.fileSHA256(executableURL)
        startedAt = ISO8601DateFormatter().string(from: Date())
    }

    static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif
