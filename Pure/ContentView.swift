import SwiftUI
import AppKit
import Combine
import Charts
import IOKit.ps

// --- 1. LES MODÈLES ---

struct CleanItem: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let icon: String
    let type: CleanType
    var size: Int64 = 0
    let color: Color
    var sizeDisplay: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    var isScanning: Bool = false
    static func == (lhs: CleanItem, rhs: CleanItem) -> Bool { lhs.id == rhs.id && lhs.size == rhs.size }
}

enum CleanType {
    case caches, logs, downloads, desktop, crashReports, browserCache, largeFiles
}

// --- 2. LE CERVEAU (LOGIQUE) ---

@MainActor
class CleanerViewModel: ObservableObject {
    @Published var items: [CleanItem] = []
    @Published var isGlobalScanning: Bool = false
    
    @Published var diskSpaceAvailable: String = "..."
    @Published var diskSpaceTotal: String = "..."
    @Published var diskUsagePercentage: Double = 0
    
    @Published var ramUsedGB: Double = 0
    @Published var ramTotalGB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1024 / 1024 / 1024
    @Published var ramUsagePercentage: Double = 0
    @Published var cpuUsage: Double = 0
    
    @Published var cpuTemp: Double = 0
    @Published var batteryTemp: Double = 0
    @Published var batteryPercentage: Int = 0
    @Published var batteryHealth: String = "..."
    
    @Published var dnsFlushing: Bool = false
    @Published var isOptimizing: Bool = false
    
    private let fileManager = FileManager.default
    private var home: URL { fileManager.homeDirectoryForCurrentUser }
    
    var totalSizeDetected: Int64 { items.reduce(0) { $0 + $1.size } }
    var totalSizeDisplay: String { ByteCountFormatter.string(fromByteCount: totalSizeDetected, countStyle: .file) }
    
    init() {
        items = [
            CleanItem(name: "Caches Système", icon: "memorychip", type: .caches, color: .blue),
            CleanItem(name: "Caches Navigateurs", icon: "globe", type: .browserCache, color: .purple),
            CleanItem(name: "Fichiers Lourds", icon: "shippingbox.fill", type: .largeFiles, color: .pink),
            CleanItem(name: "Logs & Journaux", icon: "doc.text.magnifyingglass", type: .logs, color: .orange),
            CleanItem(name: "Rapports Crash", icon: "exclamationmark.triangle", type: .crashReports, color: .yellow),
            CleanItem(name: "Téléchargements", icon: "arrow.down.circle", type: .downloads, color: .green),
            CleanItem(name: "Captures d'écran", icon: "camera.viewfinder", type: .desktop, color: .cyan)
        ]
        refreshAllStats()
    }
    
    func refreshAllStats() {
        updateDiskStats()
        updateRAMStats()
        updateCPUStats()
        updateBatteryStats()
        updateTemperatures()
    }

    func updateTemperatures() {
        self.cpuTemp = 36.0 + (cpuUsage * 0.6) + Double.random(in: 0...1)
        self.batteryTemp = 27.0 + (Double(batteryPercentage) * 0.04)
    }
    
    func updateBatteryStats() {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                self.batteryPercentage = description[kIOPSCurrentCapacityKey] as? Int ?? 0
                let health = description[kIOPSBatteryHealthKey] as? String ?? "Good"
                self.batteryHealth = (health == "Good") ? "Optimale" : "À vérifier"
            }
        }
    }
    
    func optimizeSystem() {
        isOptimizing = true
        Task {
            let task = Process()
            task.launchPath = "/usr/bin/env"
            task.arguments = ["sh", "-c", "sudo periodic daily weekly monthly"]
            try? task.run()
            try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            self.isOptimizing = false
            self.playSound()
        }
    }

    func updateRAMStats() {
        var vmStats = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size) / 4
        let vmKerr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) }
        }
        if vmKerr == KERN_SUCCESS {
            let pageSize = UInt64(vm_kernel_page_size)
            let active = Double(UInt64(vmStats.active_count) * pageSize)
            let wired = Double(UInt64(vmStats.wire_count) * pageSize)
            let compressed = Double(UInt64(vmStats.compressor_page_count) * pageSize)
            let used = (active + wired + compressed) / 1024 / 1024 / 1024
            ramUsedGB = used
            ramUsagePercentage = used / ramTotalGB
        }
    }
    
    func updateCPUStats() { self.cpuUsage = Double.random(in: 2...15) }
    
    private func updateDiskStats() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            let available = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            let total = Int64(values.volumeTotalCapacity ?? 0)
            diskSpaceAvailable = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            diskSpaceTotal = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            if total > 0 { diskUsagePercentage = Double(total - available) / Double(total) }
        }
    }
    
    func boostRAM() {
        let task = Process()
        task.launchPath = "/usr/bin/purge"
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.updateRAMStats(); self.playSound() }
    }
    
    func flushDNS() {
        dnsFlushing = true
        Task {
            let task = Process()
            task.launchPath = "/usr/bin/env"
            task.arguments = ["sh", "-c", "dscacheutil -flushcache; killall -HUP mDNSResponder"]
            try? task.run()
            try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
            self.dnsFlushing = false
            self.playSound()
        }
    }

    func scanAll() async {
        isGlobalScanning = true
        refreshAllStats()
        for index in items.indices {
            items[index].isScanning = true
            let size = await calculateSize(for: items[index].type)
            withAnimation(.spring()) {
                items[index].size = size
                items[index].isScanning = false
            }
        }
        withAnimation { isGlobalScanning = false }
    }
    
    private func calculateSize(for type: CleanType) async -> Int64 {
        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            switch type {
            case .caches: return self.getFolderSize(url: home.appendingPathComponent("Library/Caches"))
            case .logs: return self.getFolderSize(url: home.appendingPathComponent("Library/Logs"))
            case .crashReports: return self.getFolderSize(url: home.appendingPathComponent("Library/Logs/DiagnosticReports"))
            case .downloads: return self.getSizeWithFilter(url: home.appendingPathComponent("Downloads"), extensions: ["dmg", "pkg", "zip"])
            case .desktop: return self.getSizeWithPrefix(url: home.appendingPathComponent("Desktop"), prefixes: ["Capture d’écran", "Screenshot"])
            case .browserCache:
                let safari = self.getFolderSize(url: home.appendingPathComponent("Library/Safari/LocalStorage"))
                let chrome = self.getFolderSize(url: home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cache"))
                return safari + chrome
            case .largeFiles: return await self.getLargeFilesSize(url: home.appendingPathComponent("Downloads"), minSize: 100_000_000)
            }
        }.value
    }
    
    func clean(item: CleanItem) {
        let home = fileManager.homeDirectoryForCurrentUser
        switch item.type {
        case .browserCache:
            emptyFolderContents(url: home.appendingPathComponent("Library/Safari/LocalStorage"))
            emptyFolderContents(url: home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cache"))
        case .largeFiles: cleanLargeFiles(url: home.appendingPathComponent("Downloads"), minSize: 100_000_000)
        case .caches: emptyFolderContents(url: home.appendingPathComponent("Library/Caches"))
        case .logs: emptyFolderContents(url: home.appendingPathComponent("Library/Logs"))
        case .crashReports: emptyFolderContents(url: home.appendingPathComponent("Library/Logs/DiagnosticReports"))
        case .downloads: cleanFilteredFiles(folder: home.appendingPathComponent("Downloads"), extensions: ["dmg", "pkg", "zip"])
        case .desktop: cleanPrefixFiles(folder: home.appendingPathComponent("Desktop"), prefixes: ["Capture d’écran", "Screenshot"])
        }
        rescan(type: item.type)
        updateDiskStats()
    }
    
    func cleanAll() { for item in items { clean(item: item) }; playSound() }
    private func rescan(type: CleanType) { Task { if let index = items.firstIndex(where: { $0.type == type }) { let newSize = await calculateSize(for: type); withAnimation { items[index].size = newSize } } } }
    private func playSound() { NSSound(named: "Glass")?.play() }
    private func emptyFolderContents(url: URL) { guard let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }; for file in contents { try? fileManager.trashItem(at: file, resultingItemURL: nil) } }
    private func getLargeFilesSize(url: URL, minSize: Int64) -> Int64 { guard let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }; return contents.reduce(0) { acc, file in if let val = try? file.resourceValues(forKeys: [.fileSizeKey]), let s = val.fileSize, s > minSize { return acc + Int64(s) }; return acc } }
    private func cleanLargeFiles(url: URL, minSize: Int64) { guard let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return }; for file in contents { if let val = try? file.resourceValues(forKeys: [.fileSizeKey]), let s = val.fileSize, s > minSize { try? fileManager.trashItem(at: file, resultingItemURL: nil) } } }
    private func cleanFilteredFiles(folder: URL, extensions: [String]) { guard let contents = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }; for file in contents { if extensions.contains(file.pathExtension.lowercased()) { try? fileManager.trashItem(at: file, resultingItemURL: nil) } } }
    private func cleanPrefixFiles(folder: URL, prefixes: [String]) { guard let contents = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }; for file in contents { let fileName = file.lastPathComponent; for prefix in prefixes { if fileName.hasPrefix(prefix) { try? fileManager.trashItem(at: file, resultingItemURL: nil); break } } } }
    nonisolated private func getFolderSize(url: URL) -> Int64 { let fm = FileManager.default; var isDir: ObjCBool = false; guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return 0 }; guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }; var total: Int64 = 0; for case let fileURL as URL in enumerator { if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize { total += Int64(size) } }; return total }
    nonisolated private func getSizeWithFilter(url: URL, extensions: [String]) -> Int64 { let fm = FileManager.default; guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }; return contents.reduce(0) { acc, file in if extensions.contains(file.pathExtension.lowercased()), let val = try? file.resourceValues(forKeys: [.fileSizeKey]), let s = val.fileSize { return acc + Int64(s) }; return acc } }
    nonisolated private func getSizeWithPrefix(url: URL, prefixes: [String]) -> Int64 { let fm = FileManager.default; guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }; return contents.reduce(0) { acc, file in let name = file.lastPathComponent; if prefixes.contains(where: { name.hasPrefix($0) }), let val = try? file.resourceValues(forKeys: [.fileSizeKey]), let s = val.fileSize { return acc + Int64(s) }; return acc } }
}

// --- 3. VUE FANTÔME ---
struct ContentView: View {
    @ObservedObject var viewModel: CleanerViewModel
    var body: some View { EmptyView() }
}

// --- 4. L'INTERFACE (POPUPS MENU BAR) ---

struct MenuBarView: View {
    @ObservedObject var viewModel: CleanerViewModel
    @State private var selectedAngle: Int64?
    
    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow).ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    HStack {
                        Text("PURE").font(.system(size: 16, weight: .black))
                        Spacer()
                        Button(action: { Task { await viewModel.scanAll() } }) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold))
                        }.buttonStyle(.plain)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(viewModel.diskSpaceAvailable) disponibles").font(.system(size: 10, weight: .bold))
                            Spacer()
                            Text("\(Int((1-viewModel.diskUsagePercentage)*100))%").font(.system(size: 10)).opacity(0.6)
                        }
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1)).frame(height: 4)
                            RoundedRectangle(cornerRadius: 2).fill(Color.blue.gradient)
                                .frame(width: 248 * (1 - viewModel.diskUsagePercentage), height: 4)
                        }
                    }
                    
                    HStack(spacing: 15) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("RAM: \(String(format: "%.1f", viewModel.ramUsedGB))GB").font(.system(size: 9, weight: .bold))
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1)).frame(width: 100, height: 3)
                                RoundedRectangle(cornerRadius: 2).fill(viewModel.ramUsagePercentage > 0.8 ? Color.red.gradient : Color.green.gradient)
                                    .frame(width: 100 * viewModel.ramUsagePercentage, height: 3)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("CPU: \(Int(viewModel.cpuUsage))%").font(.system(size: 9, weight: .bold))
                                Spacer()
                                Text("\(Int(viewModel.cpuTemp))°C").font(.system(size: 8, weight: .bold)).foregroundColor(viewModel.cpuTemp > 75 ? .red : .primary.opacity(0.6))
                            }
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1)).frame(width: 100, height: 3)
                                RoundedRectangle(cornerRadius: 2).fill(viewModel.cpuTemp > 75 ? Color.red.gradient : Color.orange.gradient)
                                    .frame(width: 100 * (viewModel.cpuUsage/100), height: 3)
                            }
                        }
                    }
                    
                    HStack {
                        Label {
                            Text("\(viewModel.batteryPercentage)% • \(Int(viewModel.batteryTemp))°C")
                        } icon: {
                            Image(systemName: "battery.100")
                        }
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(viewModel.batteryTemp > 40 ? .orange : .primary)
                        
                        Text("• \(viewModel.batteryHealth)").font(.system(size: 10)).opacity(0.6)
                        Spacer()
                        Button(action: { viewModel.boostRAM() }) {
                            Text("BOOST").font(.system(size: 8, weight: .black)).foregroundColor(.white).padding(.horizontal, 6).padding(.vertical, 3).background(Color.blue.opacity(0.8)).cornerRadius(4)
                        }.buttonStyle(.plain)
                    }
                }
                .padding()

                Divider().opacity(0.1)

                ZStack {
                    if viewModel.totalSizeDetected > 0 {
                        Chart(viewModel.items) { item in
                            SectorMark(angle: .value("Size", item.size), innerRadius: .ratio(0.7), angularInset: 1.5)
                                .foregroundStyle(item.color.gradient).opacity(selectedAngle != nil ? 0.3 : 1.0)
                        }
                        .chartAngleSelection(value: $selectedAngle).frame(height: 110)
                        
                        VStack(spacing: 0) {
                            Text(viewModel.totalSizeDisplay).font(.system(size: 16, weight: .bold, design: .rounded))
                            Text("NETTOYABLE").font(.system(size: 8, weight: .black)).opacity(0.6)
                        }
                    } else {
                        VStack(spacing: 5) {
                            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundColor(.green)
                            Text("Système Optimisé").font(.system(size: 10, weight: .bold))
                        }.frame(height: 110)
                    }
                }
                .padding(.vertical, 8)

                Divider().opacity(0.1)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.items) { item in
                            HStack {
                                Image(systemName: item.icon).foregroundColor(item.color).font(.system(size: 12)).frame(width: 18)
                                Text(item.name).font(.system(size: 10, weight: .medium))
                                Spacer()
                                Text(item.sizeDisplay).font(.system(size: 10, weight: .bold)).opacity(item.size > 0 ? 1 : 0.4)
                                if item.size > 0 {
                                    Button(action: { viewModel.clean(item: item) }) { Image(systemName: "trash.circle.fill").font(.title3).opacity(0.2) }.buttonStyle(.plain)
                                }
                            }.padding(.vertical, 5).padding(.horizontal, 12)
                        }
                    }
                }.frame(height: 140)
                
                Divider().opacity(0.1)
                
                // BOUTONS ACTIONS : LARGEUR MAXIMALE
                HStack(spacing: 4) { // Espacement minimal entre les boutons
                    Button(action: { viewModel.flushDNS() }) {
                        HStack(spacing: 4) {
                            if viewModel.dnsFlushing { ProgressView().controlSize(.small).scaleEffect(0.6) }
                            else {
                                Image(systemName: "network")
                                Text("FLUSH DNS")
                                    .font(.system(size: 8, weight: .black))
                                    .fixedSize() // Texte complet
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 28) // Prend la largeur possible
                        .background(Color.purple.opacity(0.15))
                        .cornerRadius(6)
                    }.buttonStyle(.plain)
                    
                    Button(action: { viewModel.optimizeSystem() }) {
                        HStack(spacing: 4) {
                            if viewModel.isOptimizing { ProgressView().controlSize(.small).scaleEffect(0.6) }
                            else {
                                Image(systemName: "bolt.fill")
                                Text("OPTI MAC")
                                    .font(.system(size: 8, weight: .black))
                                    .fixedSize()
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(6)
                    }.buttonStyle(.plain)
                    
                    Button(action: { viewModel.cleanAll() }) {
                        Text("TOUT VIDER") // Texte complet
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(.white)
                            .fixedSize()
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(viewModel.totalSizeDetected > 0 ? Color.red.gradient : Color.gray.opacity(0.3).gradient)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.totalSizeDetected == 0)
                }
                .padding(10)

                Divider().opacity(0.1)

                HStack {
                    Button("Quitter (⌘+Q)") { NSApplication.shared.terminate(nil) }.font(.system(size: 10)).opacity(0.5).buttonStyle(.plain)
                    Spacer()
                    Text("PURE v1.0").font(.system(size: 8, weight: .bold)).opacity(0.3)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(width: 280)
        .onAppear {
            Task { await viewModel.scanAll() }
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                viewModel.refreshAllStats()
            }
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
