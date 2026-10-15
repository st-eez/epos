import Darwin
import Foundation

enum ProcessMemorySample: Equatable, Sendable {
    case available(residentBytes: UInt64, physicalFootprintBytes: UInt64)
    case unavailable(kernelReturn: kern_return_t)

    static func read() -> Self {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return .unavailable(kernelReturn: status) }
        // Swift cannot import TASK_VM_INFO_REV1_COUNT. Check the last field we read instead.
        guard let footprintOffset = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint) else {
            return .unavailable(kernelReturn: KERN_FAILURE)
        }
        let requiredBytes = footprintOffset + MemoryLayout.size(ofValue: info.phys_footprint)
        guard Int(count) * MemoryLayout<integer_t>.size >= requiredBytes else {
            return .unavailable(kernelReturn: KERN_FAILURE)
        }
        return .available(residentBytes: info.resident_size, physicalFootprintBytes: info.phys_footprint)
    }
}

/// Samples the current process while the app is running, including idle time.
/// The owner cancels its sleeper on teardown; the task never retains the owner across a wait.
@MainActor
final class MemoryDiagnostics {
    enum Trigger: String {
        case launch
        case readiness
        case recordingComplete = "recording-complete"
        case periodic
    }

    private var task: Task<Void, Never>?
    private let sample: @Sendable () -> ProcessMemorySample
    private let state: @MainActor () -> CoordinatorState?
    private let emit: @MainActor (String, String?) -> Void
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        sample: @escaping @Sendable () -> ProcessMemorySample = ProcessMemorySample.read,
        state: @escaping @MainActor () -> CoordinatorState?,
        emit: @escaping @MainActor (String, String?) -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.sample = sample
        self.state = state
        self.emit = emit
        self.sleep = sleep
    }

    deinit { task?.cancel() }

    static func shouldRun(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isTestProcess: Bool = NSClassFromString("XCTestCase") != nil
    ) -> Bool {
        DiagnosticLogConfiguration.load(from: environment).enabled && !isTestProcess
            && !environment.contains { $0.key.hasPrefix("EPOS_RUN_") && $0.value == "1" }
    }

    func start() {
        guard task == nil else { return }
        record(.launch)
        let sleep = sleep
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(.seconds(60)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.record(.periodic)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func record(_ trigger: Trigger, recordingID: String? = nil) {
        guard let state = state() else { return }
        let prefix = "memory sample schema=1 trigger=\(trigger.rawValue) state=\(state)"
        switch sample() {
        case .available(let residentBytes, let physicalFootprintBytes):
            emit(
                "\(prefix) outcome=available residentBytes=\(residentBytes) physicalFootprintBytes=\(physicalFootprintBytes)",
                recordingID
            )
        case .unavailable(let status):
            emit("\(prefix) outcome=unavailable kernelReturn=\(status)", recordingID)
        }
    }
}
