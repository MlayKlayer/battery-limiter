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

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        Button("Remove Helper…") {
            model.uninstallHelper()
        }

        Divider()

        Button("Quit Battery Limiter") {
            NSApplication.shared.terminate(nil)
        }
    }
}
