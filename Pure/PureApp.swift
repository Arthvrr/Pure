import SwiftUI

@main
struct PureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Pure", systemImage: "chart.pie.fill") {
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

// Le "Chef d'Orchestre"
class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel = CleanerViewModel()
    var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Laisse vide pour ne pas ouvrir la grande fenêtre au démarrage
        // L'app se lancera discrètement dans la barre des menus uniquement.
    }
    
    func showMainWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let contentView = ContentView(viewModel: viewModel)
            .frame(minWidth: 800, minHeight: 500)
            .background(GlassBackground().ignoresSafeArea())
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            // MODIFICATION ICI : J'ai retiré '.miniaturizable' pour enlever le bouton jaune
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        
        window.center()
        window.title = "PURE"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: contentView)
        
        self.mainWindow = window
        window.makeKeyAndOrderFront(nil)
        
        // Force l'app à venir au premier plan même sans icône Dock
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .underWindowBackground
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
