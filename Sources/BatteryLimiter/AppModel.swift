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
    @Published private(set) var dischargeEnabled: Bool
    @Published private(set) var dischargeNow: Bool
    @Published private(set) var topUp: Bool
    @Published private(set) var stats: BatteryStats?
    @Published private(set) var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published private(set) var menuBarStyle: MenuBarStyle
    @Published private(set) var menuBarColor: MenuBarColor

    private static let styleKey = "menuBarStyle"
    private static let colorKey = "menuBarColor"
    private var timer: Timer?
    private var notifiedThisCycle = false

    init() {
        let config = ConfigStore.read()
        enabled = config.enabled
        targetPercent = config.targetPercent
        resumePercent = config.resumePercent
        dischargeEnabled = config.dischargeEnabled
        dischargeNow = config.dischargeNow
        topUp = config.topUp
        menuBarStyle = UserDefaults.standard.string(forKey: Self.styleKey)
            .flatMap(MenuBarStyle.init(rawValue:)) ?? .outlined
        menuBarColor = UserDefaults.standard.string(forKey: Self.colorKey)
            .flatMap(MenuBarColor.init(rawValue:)) ?? .automatic
        NotificationManager.requestAuthorizationIfNeeded()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// The menu bar shows the *cap*, not the live battery percentage -- macOS
    /// already shows that, and a second live number reads as something active
    /// and alarming rather than as a setting. Top Up is the exception: while
    /// it's running the cap in force really is 100.
    var menuBarImage: NSImage {
        menuBarStyle.image(
            percent: topUp ? 100 : targetPercent,
            dimmed: !enabled,
            color: menuBarColor
        )
    }

    var statusText: String {
        guard enabled else { return "Not limiting" }
        if topUp { return pluggedIn ? "Topping up to 100%" : "Top Up ends on unplug" }
        guard pluggedIn else { return "On battery" }
        if isDischarging { return "Discharging to \(targetPercent)%" }
        if batteryPercent >= targetPercent { return "Charging paused at \(targetPercent)%" }
        // Inside the deadband either state is legitimate depending on which
        // way the charge is moving, and only the daemon knows which. Describe
        // the band instead of guessing at it.
        if batteryPercent > resumePercent { return "Holding \(resumePercent)–\(targetPercent)%" }
        return "Charging to \(targetPercent)%"
    }

    /// The cap actually in force. Top Up and a switched-off limiter both mean
    /// the charge really is heading for 100.
    var effectiveCap: Int { enabled && !topUp ? targetPercent : 100 }

    /// Mirrors the daemon's own condition, so the menu doesn't claim a
    /// discharge that the floor or the target has already stopped.
    var isDischarging: Bool {
        guard enabled, pluggedIn, !topUp, dischargeEnabled || dischargeNow else { return false }
        return batteryPercent > max(targetPercent, LimiterConfig.dischargeFloor)
    }

    var canDischargeNow: Bool {
        enabled && pluggedIn && !topUp
            && batteryPercent > max(targetPercent, LimiterConfig.dischargeFloor)
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

    func setDischargeEnabled(_ newValue: Bool) {
        guard newValue != dischargeEnabled else { return }
        dischargeEnabled = newValue
        persistConfig()
    }

    /// One-shot drain to the limit. The daemon clears the flag on unplug or
    /// once the target is reached.
    func startDischargeNow() {
        dischargeNow = true
        // Contradictory requests: Top Up is charging past the cap, this is
        // draining to it. Whichever was pressed last wins outright.
        topUp = false
        persistConfig()
    }

    func toggleTopUp() {
        topUp.toggle()
        if topUp { dischargeNow = false }
        notifiedThisCycle = false
        persistConfig()
    }

    func setMenuBarStyle(_ newValue: MenuBarStyle) {
        guard newValue != menuBarStyle else { return }
        menuBarStyle = newValue
        UserDefaults.standard.set(newValue.rawValue, forKey: Self.styleKey)
    }

    func setMenuBarColor(_ newValue: MenuBarColor) {
        guard newValue != menuBarColor else { return }
        menuBarColor = newValue
        UserDefaults.standard.set(newValue.rawValue, forKey: Self.colorKey)
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
        dischargeNow = false
        topUp = false
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
            resumePercent: resumePercent,
            dischargeEnabled: dischargeEnabled,
            dischargeNow: dischargeNow,
            topUp: topUp
        ))
    }

    private func refresh() {
        adoptDaemonChanges()
        refreshBattery()
        stats = BatteryReader.stats()
    }

    /// The daemon owns the end of a one-shot request -- it is the only part
    /// still running when the user unplugs. Re-reading here is what makes the
    /// menu notice that Top Up or a discharge has finished.
    ///
    /// Only these two fields are adopted. Every other setting is app-owned, and
    /// taking them from disk would let a daemon write that crossed a user
    /// change silently revert the control the user just touched.
    ///
    /// Deliberately `readIfPresent`: `read()` answers an unreadable file with
    /// all-defaults, and adopting those would switch the limiter off and then
    /// persist that on the next user action.
    private func adoptDaemonChanges() {
        guard let config = ConfigStore.readIfPresent() else { return }
        dischargeNow = config.dischargeNow
        topUp = config.topUp
    }

    private func refreshBattery() {
        guard let status = BatteryReader.current() else { return }
        batteryPercent = status.percent
        pluggedIn = status.pluggedIn

        // Not while topping up: reaching the cap is the point of the override,
        // not an event worth announcing.
        if enabled, pluggedIn, !topUp, status.percent >= targetPercent {
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
