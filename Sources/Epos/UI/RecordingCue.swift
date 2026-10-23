import AVFoundation

enum RecordingCue {
    private static let sampleRate = 48_000.0
    @MainActor private static let playback = Playback()

    @MainActor
    static func playStart() {
        guard IndicatorWindowPolicy.canPresentWindows else { return }
        playback.playStart()
    }

    @MainActor
    static func playEnd() {
        guard IndicatorWindowPolicy.canPresentWindows else { return }
        playback.playEnd()
    }

    @MainActor
    static func captureStopped() {
        guard IndicatorWindowPolicy.canPresentWindows else { return }
        playback.captureStopped()
    }

    @MainActor
    final class Playback {
        private enum Bell { case start, end }
        private struct PreparedSound: @unchecked Sendable {
            let player: AVAudioPlayer
        }
        private let queue = DispatchQueue(label: "epos.recording-cues", qos: .userInitiated)
        private var generation: UInt64 = 0
        private var capturing = false
        private var startSound: AVAudioPlayer?
        private var endSound: AVAudioPlayer?
        private let makeStart: @Sendable () -> AVAudioPlayer?
        private let makeEnd: @Sendable () -> AVAudioPlayer?

        init(
            makeStart: @escaping @Sendable () -> AVAudioPlayer? = { makeStartSound() },
            makeEnd: @escaping @Sendable () -> AVAudioPlayer? = { makeEndSound() }
        ) {
            self.makeStart = makeStart
            self.makeEnd = makeEnd
        }

        func playStart() {
            capturing = true
            generation &+= 1
            discard(endSound)
            endSound = nil
            enqueue(.start)
        }

        func captureStopped() {
            guard capturing else { return }
            capturing = false
            generation &+= 1
            discard(startSound)
            startSound = nil
        }

        func playEnd() {
            enqueue(.end)
        }

        private func enqueue(_ bell: Bell) {
            let token = generation
            let makeSound = bell == .start ? makeStart : makeEnd
            queue.async { [weak self] in
                guard let sound = makeSound(), sound.prepareToPlay() else { return }
                let prepared = PreparedSound(player: sound)
                Task { @MainActor in self?.playPrepared(prepared, bell: bell, token: token) }
            }
        }

        private func playPrepared(_ sound: PreparedSound, bell: Bell, token: UInt64) {
            guard generation == token else {
                discard(sound.player)
                return
            }
            switch bell {
            case .start:
                discard(startSound)
                startSound = sound.player
            case .end:
                discard(endSound)
                endSound = sound.player
            }
            sound.player.play()
        }

        private func discard(_ player: AVAudioPlayer?) {
            guard let player else { return }
            let sound = PreparedSound(player: player)
            queue.async { sound.player.stop() }
        }
    }

    /// Internal so tests can pin that the synthesized WAVs actually parse.
    static func makeStartSound() -> AVAudioPlayer? {
        try? AVAudioPlayer(data: wavData(samples: bellSamples(
            fundamental: 329.63,  // E4
            duration: 0.28,
            amplitude: 0.38,
            partials: [(329.63 * 1.2, 0.20)]  // ~G4: the E-minor color
        )))
    }

    static func makeEndSound() -> AVAudioPlayer? {
        try? AVAudioPlayer(data: wavData(samples: bellSamples(
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
