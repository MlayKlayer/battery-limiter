import AppKit
import BatteryLimiterShared
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var batteryPercent: Int = 0
    @Published var pluggedIn: Bool = false
    @Published private(set) var enabled: Bool
    @Published private(set) var targetPercent: Int
    @Published private(set) var resumePercent: Int
    @Published private(set) var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private var timer: Timer?
    private var notifiedThisCycle = false

    init() {
        let config = ConfigStore.read()
        enabled = config.enabled
        targetPercent = config.targetPercent
        resumePercent = config.resumePercent
        NotificationManager.requestAuthorizationIfNeeded()
        refreshBattery()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshBattery() }
        }
    }

    var menuBarTitle: String {
        "\(batteryPercent)%"
    }

    var statusText: String {
        guard enabled else { return "Not limiting" }
        guard pluggedIn else { return "On battery" }
        if batteryPercent >= targetPercent { return "Charging paused at \(targetPercent)%" }
        // Inside the deadband either state is legitimate depending on which
        // way the charge is moving, and only the daemon knows which. Describe
        // the band instead of guessing at it.
        if batteryPercent > resumePercent { return "Holding \(resumePercent)–\(targetPercent)%" }
        return "Charging to \(targetPercent)%"
    }

    func setEnabled(_ newValue: Bool) {
        guard newValue != enabled else { return }
        if newValue, !HelperInstaller.isInstalled {
            do {
                try HelperInstaller.install()
            } catch {
                presentError("Couldn't install the helper: \(error.localizedDescription)")
                return
            }
        }
        enabled = newValue
        persistConfig()
    }

    func setTargetPercent(_ newValue: Int) {
        guard newValue != targetPercent else { return }
        targetPercent = newValue
        notifiedThisCycle = false
        persistConfig()
    }

    func setResumePercent(_ newValue: Int) {
        guard newValue != resumePercent else { return }
        resumePercent = newValue
        persistConfig()
    }

    func setLaunchAtLogin(_ newValue: Bool) {
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = newValue
        } catch {
            presentError("Couldn't change login item: \(error.localizedDescription)")
        }
    }

    func uninstallHelper() {
        // Persist enabled=false *before* tearing down the daemon: KeepAlive
        // means launchd respawns it between `kill TERM` and `bootout`, and a
        // respawned instance must read `enabled: false` or it can briefly
        // re-inhibit charging before the final SIGTERM resets it again.
        enabled = false
        persistConfig()
        do {
            try HelperInstaller.uninstall()
        } catch {
            presentError("Couldn't remove the helper: \(error.localizedDescription)")
        }
    }

    private func persistConfig() {
        try? ConfigStore.write(LimiterConfig(
            enabled: enabled,
            targetPercent: targetPercent,
            resumePercent: resumePercent
        ))
    }

    private func refreshBattery() {
        guard let status = BatteryReader.current() else { return }
        batteryPercent = status.percent
        pluggedIn = status.pluggedIn

        if enabled, pluggedIn, status.percent >= targetPercent {
            if !notifiedThisCycle {
                NotificationManager.notifyCapReached(percent: targetPercent)
                notifiedThisCycle = true
            }
        } else if !pluggedIn || status.percent < targetPercent - 2 {
            notifiedThisCycle = false
        }
    }

    private func presentError(_ message: String) {
        // LSUIElement app: without this the modal can open behind whatever
        // has focus after the admin dialog closes, and reads as a hang.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Battery Limiter"
        alert.informativeText = message
        alert.runModal()
    }
}
