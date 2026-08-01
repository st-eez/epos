import Foundation
import ServiceManagement

/// The coordinator's settings facade: every persisted user setting the menu binds
/// to, each read live and each write saved immediately.
///
/// An extension rather than a collaborator on purpose — `settings` is `@Published`
/// on `AppCoordinator`, and that publisher is what redraws the menu when one of
/// these setters runs. Moving the storage behind another object would move the
/// publisher with it and leave the menu observing nothing.
extension AppCoordinator {
    /// Identifier of the locale this coordinator was configured with. Read-only —
    /// changing locales mid-session is post-baseline.
    public var localeIdentifier: String { settings.localeIdentifier }

    public var saveAudioSamples: Bool { settings.saveAudioSamples }

    public func setSaveAudioSamples(_ enabled: Bool) {
        guard settings.saveAudioSamples != enabled else { return }
        updateSettings { $0.saveAudioSamples = enabled }
        log.info("audio sample capture \(enabled ? "enabled" : "disabled")")
    }

    public var saveCorrectionEvidence: Bool { settings.saveCorrectionEvidence }

    public func setSaveCorrectionEvidence(_ enabled: Bool) {
        guard settings.saveCorrectionEvidence != enabled else { return }
        updateSettings { $0.saveCorrectionEvidence = enabled }
        log.info("correction evidence capture \(enabled ? "enabled" : "disabled")")
    }

    public var echoCancellation: Bool { settings.echoCancellation }

    /// Takes effect on the next fn press: the mode can only be changed while the
    /// audio engine is stopped, so the capture reads it at each start.
    public func setEchoCancellation(_ enabled: Bool) {
        guard settings.echoCancellation != enabled else { return }
        updateSettings { $0.echoCancellation = enabled }
        log.info("echo cancellation \(enabled ? "enabled" : "disabled")")
    }

    public var inlinePreviewSetting: Bool { settings.inlinePreview }

    public func setInlinePreview(_ enabled: Bool) {
        guard settings.inlinePreview != enabled else { return }
        updateSettings { $0.inlinePreview = enabled }
    }

    public var edgeGlowStyle: EdgeGlowSettings { settings.edgeGlow }

    public func setEdgeGlowStyle(_ style: EdgeGlowSettings) {
        guard settings.edgeGlow != style else { return }
        updateSettings { $0.edgeGlow = style }
        applyEdgeGlowStyleToCurrentRecording(style)
    }

    /// Live launch-at-login state from the system — the source of truth, which the user
    /// can also change in System Settings — not the cached `settings` copy.
    public var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// Applies the login-item change and returns the state that actually holds
    /// afterwards, which is what the caller's toggle must show. A failed register
    /// leaves the app unregistered; a toggle that kept the user's chosen value
    /// would go on claiming a login item that does not exist.
    @discardableResult
    public func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            updateSettings { $0.launchAtLogin = enabled }
            log.info("launch-at-login \(enabled ? "enabled" : "disabled")")
            return enabled
        } catch {
            log.error("launch-at-login toggle failed: \(String(describing: error))")
            // The live system status, not the requested value: the request failed,
            // and on failure that status is the only thing that knows the truth.
            return launchAtLogin
        }
    }
}
