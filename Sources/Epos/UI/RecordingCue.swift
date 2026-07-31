import AppKit

/// The dictation's audio protocol, two synthesized bells chosen by ear:
/// START — E4 (the tonic of the user's reference track) with the minor third
/// glowing inside the strike: "mic is hot".
/// END — B3, the fifth below, shorter and quieter, with the E above as a
/// faint partial: "recording closed", played at fn release — symmetric and
/// immediate. Delivery failures stay visual (the red notice).
/// Both are synthesized at first use into in-memory WAVs (no bundled asset).
/// Fire and forget: a failed synthesis means silence, never a failed start.
@MainActor
enum RecordingCue {
    private static let sampleRate = 48_000.0

    private static let startSound = makeStartSound()
    private static let endSound = makeEndSound()

    static func playStart() {
        play(startSound)
    }

    static func playEnd() {
        play(endSound)
    }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        // A restart beats a dropped cue when recordings come back-to-back.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// Internal so tests can pin that the synthesized WAVs actually parse.
    static func makeStartSound() -> NSSound? {
        NSSound(data: wavData(samples: bellSamples(
            fundamental: 329.63,  // E4
            duration: 0.28,
            amplitude: 0.38,
            partials: [(329.63 * 1.2, 0.20)]  // ~G4: the E-minor color
        )))
    }

    static func makeEndSound() -> NSSound? {
        NSSound(data: wavData(samples: bellSamples(
            fundamental: 246.94,  // B3 — settling a fifth below home
            duration: 0.22,
            amplitude: 0.30,
            partials: [(329.63, 0.15)]  // the E above ties the pair together
        )))
    }

    /// FM bell: carrier phase bent by its own octave (2:1 ratio → bell
    /// overtones), 4ms attack, exponential decay, with quiet inner partials
    /// for color. The audible level is baked into the waveform.
    private static func bellSamples(
        fundamental: Double,
        duration: Double,
        amplitude: Double,
        partials: [(frequency: Double, level: Double)]
    ) -> [Int16] {
        let count = Int(duration * sampleRate)
        var samples = [Int16]()
        samples.reserveCapacity(count)
        for i in 0..<count {
            let t = Double(i) / Double(count)
            let attack = min(1.0, Double(i) / (0.004 * sampleRate))
            let envelope = attack * pow(1 - t, 3.5)
            let phase = 2 * Double.pi * fundamental * Double(i) / sampleRate
            var s = sin(phase + 0.5 * sin(2 * phase))
            for partial in partials {
                s += partial.level * sin(2 * Double.pi * partial.frequency * Double(i) / sampleRate)
            }
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
