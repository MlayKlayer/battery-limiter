import BatteryLimiterShared
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Polls battery state and the shared config file, and applies the resulting
/// charge action -- re-asserted every poll while limiting is on, written on
/// change only while it's off. Runs continuously as root via launchd so the
/// limit is enforced even if the menu bar app isn't running.
final class ChargeController {
    private static var retainedSignalSource: DispatchSourceSignal?

    private var lastAction: ChargeAction?
    private var loggedFailure = false
    private var dischargeProgress = DischargeProgress()
    private var loggedDischargeTimeout = false
    private var loggedConfigWriteFailure = false
    private let pollInterval: TimeInterval = 15

    private var rootPowerPort: io_connect_t = 0
    private var powerSourceSource: CFRunLoopSource?
    private var lastTickAt: Date?

    func run() {
        // A previous instance may have been SIGKILLed mid-discharge, which no
        // handler can catch. Clearing on the way in means an adapter cut can
        // never outlive one daemon lifetime.
        ChargeControl.releaseAdapter()
        // Which keys this Mac took. The set changed under macOS 15 and the old
        // one fails silently, so pin it down in the log on the way in.
        log("charge keys: \(ChargeControl.activeKeySet)")
        installSignalHandler()
        installSleepWakeHandler()
        installPowerSourceHandler()
        tick()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run()
    }

    private func installSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.resetAndExit()
        }
        source.resume()
        Self.retainedSignalSource = source
    }

    // MARK: - Sleep and wake

    /// Nothing runs while the Mac is asleep, so a cap can't be *maintained*
    /// through sleep -- only re-asserted the instant the machine is back, which
    /// includes the dark wakes macOS takes for maintenance. Registering here
    /// also gives the one moment that matters for safety: clearing the adapter
    /// cut before we lose the ability to clear it at all.
    private func installSleepWakeHandler() {
        var notifier: io_object_t = 0
        var portRef: IONotificationPortRef?
        let context = Unmanaged.passUnretained(self).toOpaque()

        let connection = IORegisterForSystemPower(context, &portRef, { context, _, messageType, argument in
            guard let context else { return }
            Unmanaged<ChargeController>.fromOpaque(context)
                .takeUnretainedValue()
                .handlePowerMessage(messageType, argument)
        }, &notifier)

        guard connection != MACH_PORT_NULL, let portRef else {
            logError("could not register for sleep/wake notifications; falling back to the \(Int(pollInterval))s poll")
            return
        }
        rootPowerPort = connection
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(portRef).takeUnretainedValue(),
            .commonModes
        )
    }

    /// Re-checks the moment the power source changes, rather than waiting out
    /// the poll.
    ///
    /// Attaching a charger is what actually broke the cap in testing: replugging
    /// while the Mac was asleep cleared `CH0B`/`CH0C`, and nothing noticed until
    /// the next maintenance wake happened to give this daemon CPU time. Measured
    /// overnight on an M3 Air, those wakes were 15-35 minutes apart and the pack
    /// charged 86% -> 89% (+205 mAh) past an 80% cap in the gap.
    ///
    /// This does not close the window -- nothing runs during deep sleep, so a
    /// charger attached to a sleeping Mac is still only caught once the system
    /// gives out any runtime. It removes the wait *after* that point.
    private func installPowerSourceHandler() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<ChargeController>.fromOpaque(context).takeUnretainedValue().tickFromNotification()
        }, context)?.takeRetainedValue() else {
            logError("could not register for power source changes; falling back to the \(Int(pollInterval))s poll")
            return
        }
        powerSourceSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// `IOMessage.h` defines these as macros with a cast
    /// (`iokit_common_msg(x)` -> `(UInt32)(sys_iokit|sub_iokit_common|x)`), and
    /// Swift imports no macro that casts -- so they have to be restated.
    /// Values taken from the SDK header by compiling it, not by hand.
    private enum PowerMessage {
        static let canSystemSleep: natural_t = 0xE000_0270
        static let systemWillSleep: natural_t = 0xE000_0280
        static let systemHasPoweredOn: natural_t = 0xE000_0300
    }

    private func handlePowerMessage(_ messageType: natural_t, _ argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case PowerMessage.canSystemSleep:
            // Never veto sleep -- we only want to be told it's coming. Not
            // answering stalls the sleep attempt for ~30s.
            IOAllowPowerChange(rootPowerPort, Int(bitPattern: argument))

        case PowerMessage.systemWillSleep:
            // The last code that will run until wake. A discharge left armed
            // here drains the pack all night against an adapter the system has
            // been told to ignore. `lastAction` is deliberately kept so the
            // deadband doesn't forget which side of the band it was on.
            // Sleeping stops the discharge dead, so none of the time about to
            // pass counts against it.
            clearDischargeWatchdog()
            let released = ChargeControl.releaseAdapter()
            log("sleep: \(stateDescription()), applied=\(lastAction?.rawValue ?? "none"), adapter cut cleared=\(released)")
            if !released {
                logError("sleep: could not clear the adapter cut -- the Mac may sleep on battery power")
            }
            // Allowed either way: by WillSleep the transition is committed, and
            // sitting on it only stalls the machine without saving the pack.
            IOAllowPowerChange(rootPowerPort, Int(bitPattern: argument))

        case PowerMessage.systemHasPoweredOn:
            log("wake: \(stateDescription()), re-asserting")
            tick()

        default:
            break
        }
    }

    // MARK: - Polling

    /// These notifications fire on any change to the power-source description,
    /// which includes the time-remaining estimate and so can churn every few
    /// seconds. Steady state is the poll's job; this only has to catch
    /// transitions, so a repeat inside the debounce window is dropped rather
    /// than turned into another round of SMC writes.
    private func tickFromNotification() {
        if let last = lastTickAt, Date().timeIntervalSince(last) < 3 { return }
        tick()
    }

    private func tick() {
        lastTickAt = Date()
        var config = ConfigStore.read()
        guard let battery = BatteryReader.current() else {
            apply(.normal)
            return
        }
        clearSpentRequests(&config, battery: battery)

        let decided = config.action(
            percent: battery.percent,
            pluggedIn: battery.pluggedIn,
            // lastAction doubles as the hysteresis state: it *is* what is
            // currently applied to the hardware, discharge included.
            currentlyInhibited: lastAction.map { $0 != .normal } ?? false
        )
        let action = dischargeWatchdog(decided, percent: battery.percent)

        // A one-shot the watchdog gave up on has to be cleared, or it stays
        // pending forever: the decision keeps coming back `.discharge`, the
        // watchdog keeps overriding it, and pressing the button again changes
        // nothing until the user unplugs.
        if decided == .discharge, action != .discharge, config.dischargeNow {
            config.dischargeNow = false
            writeFlags(of: config)
        }
        apply(action)
    }

    /// `dischargeNow` and `topUp` are one-shot and scoped to this plug-in
    /// session. The daemon clears them because it is the only part guaranteed
    /// to still be running when the user unplugs -- the menu bar app can be
    /// quit at any time without stopping the limiter.
    ///
    /// These two fields are the *only* ones the daemon owns. It re-reads
    /// immediately before writing and carries over nothing else: the app owns
    /// every other field, and writing back the copy this tick started with
    /// would silently revert a setting the user changed in between.
    private func clearSpentRequests(_ config: inout LimiterConfig, battery: BatteryStatus) {
        var cleared = config
        if !battery.pluggedIn {
            cleared.topUp = false
            cleared.dischargeNow = false
        } else if cleared.dischargeNow, battery.percent <= cleared.dischargeStopsAt {
            cleared.dischargeNow = false
        }
        guard cleared != config else { return }
        config = writeFlags(of: cleared)
    }

    /// Persists just the two daemon-owned flags. Re-reads immediately before
    /// writing and carries nothing else over, so a user setting changed since
    /// this tick began survives.
    @discardableResult
    private func writeFlags(of config: LimiterConfig) -> LimiterConfig {
        var fresh = ConfigStore.readIfPresent() ?? config
        fresh.dischargeNow = config.dischargeNow
        fresh.topUp = config.topUp
        do {
            try ConfigStore.write(fresh)
            loggedConfigWriteFailure = false
        } catch {
            // Worth a line: a config the daemon can't write means a one-shot
            // request never clears, which reads to the user as a discharge they
            // never asked for that won't stop.
            if !loggedConfigWriteFailure {
                logError("could not clear a one-shot request in config: \(error)")
                loggedConfigWriteFailure = true
            }
        }
        return fresh
    }

    /// Stops a discharge that is going *nowhere* -- not one that is merely
    /// slow. See `DischargeProgress` for the rule and why it isn't a plain
    /// elapsed-time timeout.
    private func dischargeWatchdog(_ action: ChargeAction, percent: Int) -> ChargeAction {
        guard action == .discharge else {
            clearDischargeWatchdog()
            return action
        }
        guard dischargeProgress.isStalled(percent: percent, now: Date()) else { return action }
        if !loggedDischargeTimeout {
            logError("discharge sat at \(percent)% for \(Int(DischargeProgress.maxStall / 3600))h without dropping; stopping")
            loggedDischargeTimeout = true
        }
        return .inhibit
    }

    private func clearDischargeWatchdog() {
        dischargeProgress.clear()
        loggedDischargeTimeout = false
    }

    private func apply(_ action: ChargeAction) {
        // Re-assert every poll while acting: the SMC can clear these keys
        // across sleep/wake and charger transitions, and a cached "already
        // applied" would leave charging uncapped until the next state change.
        // Only while acting -- an idle helper with the limit off stays cached
        // and silent.
        let reassert = action != .normal
        guard reassert || action != lastAction else { return }
        do {
            try ChargeControl.apply(action)
            // Only on change, not every re-assert: this is a handful of lines a
            // day, and it is what pins down *when* charging resumed. Working
            // that out after the first overnight run meant cross-referencing
            // `pmset -g log`, because nothing here recorded it.
            if action != lastAction {
                log("\(lastAction?.rawValue ?? "start") -> \(action.rawValue) at \(stateDescription())")
            }
            lastAction = action
            loggedFailure = false
        } catch {
            // ponytail: log once per failure run, not once per poll -- the
            // daemon's log is unrotated. Per-failure detail if it ever matters.
            if !loggedFailure {
                logError("SMC write failed, resetting to normal charging: \(error)")
                loggedFailure = true
            }
            ChargeControl.releaseAdapter()
            try? ChargeControl.apply(.normal)
            lastAction = .normal
        }
    }

    private func resetAndExit() {
        ChargeControl.releaseAdapter()
        try? ChargeControl.apply(.normal)
        exit(0)
    }

    private func stateDescription() -> String {
        guard let battery = BatteryReader.current() else { return "battery unreadable" }
        return "\(battery.percent)% \(battery.pluggedIn ? "on AC" : "on battery")"
    }

    /// Timestamped because the first overnight run had to be reconstructed
    /// against `pmset -g log` to establish what happened in which order, which
    /// is most of the value of logging it at all.
    private static let logTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func log(_ message: String) {
        write(message, to: .standardOutput)
    }

    private func logError(_ message: String) {
        write(message, to: .standardError)
    }

    private func write(_ message: String, to handle: FileHandle) {
        let stamp = Self.logTimestamp.string(from: Date())
        handle.write(Data("\(stamp) battery-limiter-helper: \(message)\n".utf8))
    }
}
