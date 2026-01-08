import SwiftUI

@main
struct PureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Pure", systemImage: "chart.pie.fill") {
            // Utilise MenuBarView pour le menu de la barre des menus
            MenuBarView(viewModel: appDelegate.viewModel)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quitter PURE") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel = CleanerViewModel()
}
