import BatteryLimiterShared
import Foundation

/// Polls battery state and the shared config file, and applies the
/// charge-inhibit state on change only. Runs continuously as root via
/// launchd so the limit is enforced even if the menu bar app isn't running.
final class ChargeController {
    private static var retainedSignalSource: DispatchSourceSignal?

    private var lastInhibited: Bool?
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
        apply(inhibited: battery.percent >= config.targetPercent)
    }

    private func apply(inhibited: Bool) {
        guard inhibited != lastInhibited else { return }
        do {
            try ChargeControl.setInhibited(inhibited)
            lastInhibited = inhibited
        } catch {
            logError("SMC write failed, resetting to normal charging: \(error)")
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
