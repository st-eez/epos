import AVFoundation
import Synchronization

final class AudioInputRing: @unchecked Sendable {
    enum Failure: Int {
        case none, overflow, invalidBuffer
    }

    private let format: AVAudioFormat
    private let capacity: Int
    private let mask: UInt64
    private let bufferCount: Int
    private let channelsPerBuffer: UInt32
    private let bytesPerFrame: Int
    private let storage: UnsafeMutableRawPointer
    private let readCursor = Atomic<UInt64>(0)
    private let writeCursor = Atomic<UInt64>(0)
    private let failureCode = Atomic<Int>(Failure.none.rawValue)

    init?(format: AVAudioFormat, capacity: Int = 65_536) {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let bufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        guard capacity > 0, capacity.nonzeroBitCount == 1,
              bytesPerFrame > 0, bufferCount > 0 else { return nil }
        let (planeBytes, planeOverflow) = capacity.multipliedReportingOverflow(by: bytesPerFrame)
        let (totalBytes, totalOverflow) = planeBytes.multipliedReportingOverflow(by: bufferCount)
        guard !planeOverflow, !totalOverflow else { return nil }
        self.format = format
        self.capacity = capacity
        self.mask = UInt64(capacity - 1)
        self.bufferCount = bufferCount
        self.channelsPerBuffer = format.isInterleaved ? format.channelCount : 1
        self.bytesPerFrame = bytesPerFrame
        self.storage = .allocate(byteCount: totalBytes, alignment: 16)
    }

    deinit { storage.deallocate() }

    var failure: Failure { Failure(rawValue: failureCode.load(ordering: .acquiring))! }

    /// Render-thread entry point: only bounded copies and lock-free atomic loads/stores.
    func write(_ input: UnsafePointer<AudioBufferList>, frames: UInt32) {
        guard frames > 0, failureCode.load(ordering: .relaxed) == Failure.none.rawValue else { return }
        let written = writeCursor.load(ordering: .relaxed)
        let read = readCursor.load(ordering: .acquiring)
        let queued = written &- read
        guard queued <= UInt64(capacity), UInt64(frames) <= UInt64(capacity) - queued else {
            failureCode.store(Failure.overflow.rawValue, ordering: .releasing)
            return
        }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let byteCount = Int(frames) * bytesPerFrame
        guard buffers.count == bufferCount else {
            failureCode.store(Failure.invalidBuffer.rawValue, ordering: .releasing)
            return
        }
        for buffer in buffers {
            guard buffer.mNumberChannels == channelsPerBuffer, buffer.mData != nil,
                  Int(buffer.mDataByteSize) >= byteCount else {
                failureCode.store(Failure.invalidBuffer.rawValue, ordering: .releasing)
                return
            }
        }
        let offset = Int(written & mask)
        let firstBytes = min(Int(frames), capacity - offset) * bytesPerFrame
        for index in 0..<bufferCount {
            let source = buffers[index].mData!
            let plane = storage.advanced(by: index * capacity * bytesPerFrame)
            memcpy(plane.advanced(by: offset * bytesPerFrame), source, firstBytes)
            if byteCount > firstBytes {
                memcpy(plane, source.advanced(by: firstBytes), byteCount - firstBytes)
            }
        }
        writeCursor.store(written &+ UInt64(frames), ordering: .releasing)
    }

    func read(minimumFrames: Int = 1, maximumFrames: Int = 4_096) throws -> AVAudioPCMBuffer? {
        let read = readCursor.load(ordering: .relaxed)
        let written = writeCursor.load(ordering: .acquiring)
        let available = Int(written &- read)
        guard available >= minimumFrames, maximumFrames > 0 else { return nil }
        let count = min(available, maximumFrames)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count)) else {
            throw AudioCaptureError.bufferAllocationFailed
        }
        output.frameLength = UInt32(count)
        let buffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        let offset = Int(read & mask)
        let firstBytes = min(count, capacity - offset) * bytesPerFrame
        let byteCount = count * bytesPerFrame
        for index in 0..<bufferCount {
            let destination = buffers[index].mData!
            let plane = storage.advanced(by: index * capacity * bytesPerFrame)
            memcpy(destination, plane.advanced(by: offset * bytesPerFrame), firstBytes)
            if byteCount > firstBytes {
                memcpy(destination.advanced(by: firstBytes), plane, byteCount - firstBytes)
            }
        }
        readCursor.store(read &+ UInt64(count), ordering: .releasing)
        return output
    }
}
