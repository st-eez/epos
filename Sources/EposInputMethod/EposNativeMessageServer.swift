import Darwin
import Foundation

final class EposNativeMessageServer: @unchecked Sendable {
    private static let maxRequestBytes = 64 * 1024
    private let commitText: @Sendable (String) -> Bool
    private let queue = DispatchQueue(label: "com.steez.EposInputMethod.native-message-server")

    init(commitText: @escaping @Sendable (String) -> Bool) {
        self.commitText = commitText
    }

    func start() {
        queue.async { self.run() }
    }

    private func run() {
        guard let socketPath = Self.defaultSocketPath() else { return }

        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }

        Darwin.unlink(socketPath)
        guard bind(descriptor, to: socketPath), Darwin.listen(descriptor, 8) == 0 else {
            Darwin.unlink(socketPath)
            return
        }
        defer { Darwin.unlink(socketPath) }

        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { continue }
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        guard let requestData = readRequest(from: client),
              let request = try? JSONDecoder().decode(NativeTextInsertionRequest.self, from: requestData) else {
            write("error\n", to: client)
            return
        }

        switch request.operation {
        case "ping":
            write("ok\n", to: client)
        case "insert":
            guard let text = request.text else {
                write("error\n", to: client)
                return
            }
            let didCommit = DispatchQueue.main.sync {
                commitText(text)
            }
            write(didCommit ? "ok\n" : "error\n", to: client)
        default:
            write("error\n", to: client)
        }
    }

    private func readRequest(from client: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0

        while data.count < Self.maxRequestBytes {
            let count = Darwin.read(client, &byte, 1)
            guard count > 0 else { break }
            if byte == 0x0A { break }
            data.append(byte)
        }

        return data.isEmpty ? nil : data
    }

    private func write(_ string: String, to client: Int32) {
        guard let data = string.data(using: .utf8) else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }

            var bytesWritten = 0
            while bytesWritten < data.count {
                let result = Darwin.write(
                    client,
                    baseAddress.advanced(by: bytesWritten),
                    data.count - bytesWritten
                )
                guard result > 0 else { return }
                bytesWritten += result
            }
        }
    }

    private func bind(_ descriptor: Int32, to socketPath: String) -> Bool {
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
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        return status == 0
    }

    private static func defaultSocketPath() -> String? {
        guard let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }

        return cachesDirectory
            .appendingPathComponent("Epos", isDirectory: true)
            .appendingPathComponent("native-input.sock", isDirectory: false)
            .path
    }
}

private struct NativeTextInsertionRequest: Decodable {
    let operation: String
    let text: String?
}
