import SwiftUI

@main
struct BatteryLimiterApp: App {
    @StateObject private var model = AppModel()

    init() {
        DestructiveMenuItem.paintRed()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Image(nsImage: model.menuBarImage)
        }
        .menuBarExtraStyle(.menu)
    }
}
