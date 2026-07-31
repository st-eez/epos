import Foundation

/// Socket path shared by the input method and the driver CLI. Derived from the
/// Darwin per-user temp dir rather than $TMPDIR so both processes agree even
/// when the input method is launched by the system input daemon.
enum ProbePaths {
    static let socketPath: String = {
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let directory = length > 0 ? String(cString: buffer) : NSTemporaryDirectory()
        return (directory as NSString).appendingPathComponent("epos-probe-im.sock")
    }()

    static let logPath: String = {
        let caches = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches/EposProbe")
        try? FileManager.default.createDirectory(atPath: caches, withIntermediateDirectories: true)
        return (caches as NSString).appendingPathComponent("probe.log")
    }()
}

enum ProbeLog {
    private static let queue = DispatchQueue(label: "com.steez.inputmethod.EposProbe.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        queue.async {
            let line = "\(formatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: ProbePaths.logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: ProbePaths.logPath))
            }
        }
    }
}
