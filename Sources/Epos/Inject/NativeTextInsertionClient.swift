import Carbon
import Darwin
import Foundation

public final class NativeTextInsertionClient: FallibleTextInsertionBackend, LiveTextInsertionBackend {
    public static let diagnosticInputSourceID = "com.steez.inputmethod.Epos.Diagnostic"

    private let currentInputSourceID: () -> String?
    private let sendRequest: (NativeTextInsertionRequest) -> Bool
    private let log = EposLogger(category: "inject")

    public convenience init() {
        self.init(
            currentInputSourceID: NativeTextInsertionClient.currentKeyboardInputSourceID,
            sendRequest: { request in
                guard let socketPath = NativeTextInsertionClient.defaultSocketPath() else { return false }
                return NativeTextInsertionSocketClient.send(request, to: socketPath)
            }
        )
    }

    init(
        currentInputSourceID: @escaping () -> String?,
        sendRequest: @escaping (NativeTextInsertionRequest) -> Bool
    ) {
        self.currentInputSourceID = currentInputSourceID
        self.sendRequest = sendRequest
    }

    public var isHealthy: Bool {
        currentInputSourceID() == Self.diagnosticInputSourceID && send(.ping)
    }

    public var supportsMarkedText: Bool {
        isHealthy
    }

    public func insert(_ text: String) {
        _ = tryInsert(text)
    }

    public func tryInsert(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let chars = text.utf16.count
        guard currentInputSourceID() == Self.diagnosticInputSourceID else {
            log.info("native insert skipped reason=inputSource chars=\(chars)")
            return false
        }
        let didSend = send(.insert(text))
        log.info("native insert sent chars=\(chars) success=\(didSend)")
        return didSend
    }

    public func updateMarkedText(_ text: String) {
        guard !text.isEmpty else {
            cancelMarkedText()
            return
        }
        let chars = text.utf16.count
        guard currentInputSourceID() == Self.diagnosticInputSourceID else {
            log.info("native marked text skipped reason=inputSource chars=\(chars)")
            return
        }
        let didSend = send(.mark(text))
        log.info("native marked text sent chars=\(chars) success=\(didSend)")
    }

    public func cancelMarkedText() {
        guard currentInputSourceID() == Self.diagnosticInputSourceID else {
            log.info("native marked text cancel skipped reason=inputSource")
            return
        }
        let didSend = send(.cancel)
        log.info("native marked text cancel sent success=\(didSend)")
    }

    private func send(_ request: NativeTextInsertionRequest) -> Bool {
        sendRequest(request)
    }

    private static func currentKeyboardInputSourceID() -> String? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let rawInputSourceID = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID) else {
            return nil
        }

        return Unmanaged<CFString>.fromOpaque(rawInputSourceID).takeUnretainedValue() as String
    }

    static func defaultSocketPath() -> String? {
        guard let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }

        return cachesDirectory
            .appendingPathComponent("Epos", isDirectory: true)
            .appendingPathComponent("native-input.sock", isDirectory: false)
            .path
    }
}

enum NativeTextInsertionRequest: Equatable {
    case ping
    case insert(String)
    case mark(String)
    case cancel

    var payload: [String: String] {
        switch self {
        case .ping:
            ["operation": "ping"]
        case .insert(let text):
            ["operation": "insert", "text": text]
        case .mark(let text):
            ["operation": "mark", "text": text]
        case .cancel:
            ["operation": "cancel"]
        }
    }
}

private enum NativeTextInsertionSocketClient {
    private static let maxResponseBytes = 256

    static func send(_ request: NativeTextInsertionRequest, to socketPath: String) -> Bool {
        guard let requestData = try? JSONSerialization.data(withJSONObject: request.payload) else {
            return false
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        guard connect(descriptor, to: socketPath) else { return false }
        guard write(requestData + Data([0x0A]), to: descriptor) else { return false }

        var buffer = [UInt8](repeating: 0, count: maxResponseBytes)
        let bytesRead = Darwin.read(descriptor, &buffer, buffer.count)
        guard bytesRead > 0 else { return false }

        let response = String(decoding: buffer.prefix(bytesRead), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return response == "ok"
    }

    private static func connect(_ descriptor: Int32, to socketPath: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString.map { UInt8(bitPattern: $0) }
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.copyBytes(from: pathBytes)
        }

        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        return status == 0
    }

    private static func write(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }

            var bytesWritten = 0
            while bytesWritten < data.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: bytesWritten),
                    data.count - bytesWritten
                )
                guard result > 0 else { return false }
                bytesWritten += result
            }

            return true
        }
    }
}
