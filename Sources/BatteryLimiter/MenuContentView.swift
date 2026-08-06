import BatteryLimiterShared
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.statusText)

        Divider()

        Toggle("Limit Charging", isOn: Binding(
            get: { model.enabled },
            set: { model.setEnabled($0) }
        ))

        Picker("Limit to", selection: Binding(
            get: { model.targetPercent },
            set: { model.setTargetPercent($0) }
        )) {
            Text("80%").tag(80)
            Text("85%").tag(85)
            Text("90%").tag(90)
            Text("95%").tag(95)
        }
        .disabled(!model.enabled)

        Picker("Resume at", selection: Binding(
            get: { model.resumePercent },
            set: { model.setResumePercent($0) }
        )) {
            Text("60%").tag(60)
            Text("65%").tag(65)
            Text("70%").tag(70)
            Text("75%").tag(75)
            Text("77%").tag(77)
        }
        .disabled(!model.enabled)

        Divider()

        Toggle("Discharge to Limit", isOn: Binding(
            get: { model.dischargeEnabled },
            set: { model.setDischargeEnabled($0) }
        ))
        .disabled(!model.enabled)

        Button("Discharge Now") {
            model.startDischargeNow()
        }
        .disabled(!model.canDischargeNow)

        Button(model.topUp ? "Cancel Top Up" : "Top Up to 100% Once") {
            model.toggleTopUp()
        }
        .disabled(!model.enabled)

        Divider()

        Menu("Stats") {
            if let stats = model.stats {
                Text("Health  \(stats.healthPercent)%")
                Text("\(stats.maxCapacity) / \(stats.designCapacity) mAh")
                Text("Charge  \(stats.currentCapacity) mAh")
                Text("Cycles  \(stats.cycleCount)")
                Divider()
                Text(String(format: "Temperature  %.1f °C", stats.temperatureCelsius))
                Text(String(format: "Voltage  %.2f V", stats.volts))
                Text("Current  \(stats.milliamps) mA")
                Text(String(format: "Power  %.2f W", stats.watts))
                Divider()
                Text(timeRemaining(stats))
            } else {
                Text("Unavailable")
            }
        }

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        Picker("Style", selection: Binding(
            get: { model.menuBarStyle },
            set: { model.setMenuBarStyle($0) }
        )) {
            ForEach(MenuBarStyle.allCases) { style in
                Text(style.label).tag(style)
            }
        }

        Picker("Color", selection: Binding(
            get: { model.menuBarColor },
            set: { model.setMenuBarColor($0) }
        )) {
            ForEach(MenuBarColor.allCases) { color in
                Text(color.label).tag(color)
            }
        }

        // Coloured red by DestructiveMenuItem, not from here -- see there.
        Button(DestructiveMenuItem.title) {
            model.uninstallHelper()
        }

        Divider()

        Button("Quit Battery Limiter") {
            NSApplication.shared.terminate(nil)
        }
    }

    /// macOS declines to estimate for a few minutes after any power transition,
    /// and reports nothing at all while the adapter is carrying the load.
    private func timeRemaining(_ stats: BatteryStats) -> String {
        guard let seconds = stats.timeRemaining else { return "Time remaining  —" }
        let minutes = Int(seconds) / 60
        let label = stats.charging ? "Until full" : "Time remaining"
        return "\(label)  \(minutes / 60)h \(minutes % 60)m"
    }
}

/// Draws **Remove Helper…** in red, the one destructive item in the menu.
///
/// `.menuBarExtraStyle(.menu)` renders through NSMenu, and an NSMenuItem takes
/// colour only from `attributedTitle`: `Button(role: .destructive)` and
/// `.foregroundStyle(.red)` were both tried on the SwiftUI side and neither
/// shows. SwiftUI exposes no handle on the menu it builds, but
/// `didBeginTracking` hands over the NSMenu just before it draws, which is late
/// enough to have the items and early enough to restyle one.
///
/// Matching on the title is the weak point, so the Button reads its label from
/// `title` here rather than repeating the string.
enum DestructiveMenuItem {
    static let title = "Remove Helper…"

    private static var observer: NSObjectProtocol?

    /// Muted rather than `systemRed` (#FF3B30), which glows against a menu
    /// background. Resolved per appearance instead of one fixed tone, since a
    /// red dark enough to sit calmly on a light menu goes muddy on a dark one.
    private static let ink = NSColor(name: "RemoveHelperRed") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.90, green: 0.48, blue: 0.44, alpha: 1)
            : NSColor(srgbRed: 0.70, green: 0.22, blue: 0.18, alpha: 1)
    }

    static func paintRed() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let menu = notification.object as? NSMenu else { return }
            for item in menu.items where item.title == title {
                item.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.foregroundColor: ink]
                )
            }
        }
    }
}
