import AVFoundation
import ApplicationServices
import Foundation
import Speech
import os

public enum PermissionStatus: Equatable {
    case notDetermined
    case denied
    case granted
}

public struct PermissionsSnapshot: Equatable {
    public let microphone: PermissionStatus
    public let speech: PermissionStatus
    public let accessibility: PermissionStatus
}

public struct PermissionsGate: Sendable {
    private let log = Logger(subsystem: "com.steez.SteezFlow", category: "permissions")

    public init() {}

    public func snapshot() -> PermissionsSnapshot {
        PermissionsSnapshot(
            microphone: micStatus(),
            speech: speechStatus(),
            accessibility: accessibilityStatus()
        )
    }

    public func requestAll() async -> PermissionsSnapshot {
        log.info("requestAll: begin")

        _ = await AVCaptureDevice.requestAccess(for: .audio)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in
                continuation.resume()
            }
        }

        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        let result = snapshot()
        log.info("requestAll: end")
        return result
    }

    private func micStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    private func speechStatus() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    private func accessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }
}
