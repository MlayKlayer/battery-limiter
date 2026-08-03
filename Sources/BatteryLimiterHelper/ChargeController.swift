import BatteryLimiterShared
import Foundation

/// Polls battery state and the shared config file, and applies the
/// charge-inhibit state -- re-asserted every poll while limiting is on,
/// written on change only while it's off. Runs continuously as root via
/// launchd so the limit is enforced even if the menu bar app isn't running.
final class ChargeController {
    private static var retainedSignalSource: DispatchSourceSignal?

    private var lastInhibited: Bool?
    private var loggedFailure = false
    private let pollInterval: TimeInterval = 15

    func run() {
        installSignalHandler()
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

    private func tick() {
        let config = ConfigStore.read()
        guard config.enabled,
              let battery = BatteryReader.current(),
              battery.pluggedIn
        else {
            apply(inhibited: false)
            return
        }
        // Re-assert every poll while limiting is on: the SMC can clear
        // CH0B/CH0C across sleep/wake and charger transitions, and a cached
        // "already applied" would leave charging uncapped until the next
        // state change. Only while enabled -- an idle helper with the limit
        // off stays cached and silent.
        apply(inhibited: battery.percent >= config.targetPercent, reassert: true)
    }

    private func apply(inhibited: Bool, reassert: Bool = false) {
        guard reassert || inhibited != lastInhibited else { return }
        do {
            try ChargeControl.setInhibited(inhibited)
            lastInhibited = inhibited
            loggedFailure = false
        } catch {
            // ponytail: log once per failure run, not once per poll -- the
            // daemon's log is unrotated. Per-failure detail if it ever matters.
            if !loggedFailure {
                logError("SMC write failed, resetting to normal charging: \(error)")
                loggedFailure = true
            }
            try? ChargeControl.setInhibited(false)
            lastInhibited = false
        }
    }

    private func resetAndExit() {
        try? ChargeControl.setInhibited(false)
        exit(0)
    }

    private func logError(_ message: String) {
        FileHandle.standardError.write(Data("battery-limiter-helper: \(message)\n".utf8))
    }
}
