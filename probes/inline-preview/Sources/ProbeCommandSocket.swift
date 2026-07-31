import AppKit
import Foundation

/// Line-oriented AF_UNIX command channel. One connection at a time is enough for
/// a probe; each command is answered with a single line.
final class ProbeCommandSocket {
    static let shared = ProbeCommandSocket()

    private var listenerDescriptor: Int32 = -1

    func start() {
        let path = ProbePaths.socketPath
        unlink(path)

        listenerDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerDescriptor >= 0 else {
            ProbeLog.write("socket() failed errno=\(errno)")
            return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            ProbeLog.write("socket path too long: \(path)")
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(listenerDescriptor, sockaddrPointer, addressLength)
            }
        }
        guard bindResult == 0 else {
            ProbeLog.write("bind() failed errno=\(errno) path=\(path)")
            return
        }
        chmod(path, 0o600)

        guard listen(listenerDescriptor, 4) == 0 else {
            ProbeLog.write("listen() failed errno=\(errno)")
            return
        }

        ProbeLog.write("listening on \(path)")
        Thread.detachNewThread { [listenerDescriptor] in
            while true {
                let connection = accept(listenerDescriptor, nil, nil)
                if connection < 0 {
                    if errno == EINTR { continue }
                    ProbeLog.write("accept() failed errno=\(errno)")
                    return
                }
                ProbeCommandSocket.serve(connection)
            }
        }
    }

    private static func serve(_ descriptor: Int32) {
        defer { close(descriptor) }
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { return }
            pending.append(contentsOf: buffer[0..<count])

            while let newlineIndex = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[0..<newlineIndex], as: UTF8.self)
                pending.removeSubrange(0...newlineIndex)
                let response = handle(line) + "\n"
                _ = response.withCString { pointer in
                    write(descriptor, pointer, strlen(pointer))
                }
            }
        }
    }

    private static func handle(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        let (verb, argument) = split(trimmed)

        switch verb {
        case "ping":
            return "pong"
        case "status":
            return runOnMain { EposProbeInputController.status() }
        case "begin":
            return runOnMain { EposProbeInputController.begin(expected: argument.isEmpty ? "any" : argument) }
        case "end":
            return runOnMain { EposProbeInputController.end() }
        case "mark":
            return runOnMain { EposProbeInputController.mark(argument, styled: true) }
        case "markplain":
            return runOnMain { EposProbeInputController.mark(argument, styled: false) }
        case "commit":
            return runOnMain { EposProbeInputController.commit(argument.isEmpty ? nil : argument) }
        case "cancel":
            return runOnMain { EposProbeInputController.cancel() }
        case "rect":
            return runOnMain { EposProbeInputController.rect() }
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return "ok quitting"
        default:
            return "err unknown command: \(verb)"
        }
    }

    private static func split(_ line: String) -> (String, String) {
        guard let spaceIndex = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[line.startIndex..<spaceIndex]), String(line[line.index(after: spaceIndex)...]))
    }

    private static func runOnMain(_ body: @escaping () -> String) -> String {
        if Thread.isMainThread { return body() }
        var response = ""
        DispatchQueue.main.sync { response = body() }
        return response
    }
}
