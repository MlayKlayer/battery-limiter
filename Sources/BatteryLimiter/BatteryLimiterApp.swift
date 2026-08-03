import SwiftUI

@main
struct BatteryLimiterApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Text(model.menuBarTitle)
        }
        .menuBarExtraStyle(.menu)
    }
}
