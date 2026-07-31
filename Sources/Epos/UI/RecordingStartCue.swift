import AppKit

/// Audible "mic is hot" cue at recording start: a low E-minor bell — an FM
/// bell on E4 (the tonic of the user's reference track) with the minor third
/// glowing inside the strike. Synthesized at first use from the formula below
/// (chosen by ear across several audition rounds), so there is no bundled
/// asset. Fire and forget: a failed synthesis just means silence, never a
/// failed start.
@MainActor
enum RecordingStartCue {
    private static let sampleRate = 48_000.0
    private static let duration = 0.28
    /// E4 — the tonic, an octave below the melody register so the cue sits
    /// under whatever else is playing.
    private static let fundamental = 329.63
    /// Peak sample amplitude; the audible level is baked into the waveform.
    private static let amplitude = 0.38

    private static let sound: NSSound? = makeSound()

    static func play() {
        guard let sound else { return }
        // A restart beats a dropped cue when recordings come back-to-back.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// Internal so a test can pin that the synthesized WAV actually parses.
    static func makeSound() -> NSSound? {
        NSSound(data: wavData(samples: bellSamples()))
    }

    /// FM bell: carrier phase bent by its own octave (2:1 ratio → bell
    /// overtones), 4ms attack, exponential decay, with the minor third
    /// (E×1.2 ≈ G) as a quiet inner partial for the E-minor color.
    private static func bellSamples() -> [Int16] {
        let minorThird = fundamental * 1.2
        let count = Int(duration * sampleRate)
        var samples = [Int16]()
        samples.reserveCapacity(count)
        for i in 0..<count {
            let t = Double(i) / Double(count)
            let attack = min(1.0, Double(i) / (0.004 * sampleRate))
            let envelope = attack * pow(1 - t, 3.5)
            let phase = 2 * Double.pi * fundamental * Double(i) / sampleRate
            var s = sin(phase + 0.5 * sin(2 * phase))
            s += 0.20 * sin(2 * Double.pi * minorThird * Double(i) / sampleRate)
            samples.append(Int16(max(-32767, min(32767, amplitude * envelope * s * 32767))))
        }
        return samples
    }

    /// Canonical 16-bit mono PCM WAV.
    private static func wavData(samples: [Int16]) -> Data {
        var data = Data()
        func le16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func le32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        le32(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        le32(16)
        le16(1)  // PCM
        le16(1)  // mono
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate) * 2)
        le16(2)
        le16(16)
        data.append(contentsOf: Array("data".utf8))
        le32(UInt32(byteCount))
        for sample in samples { le16(UInt16(bitPattern: sample)) }
        return data
    }
}
