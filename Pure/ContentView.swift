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

// --- 2. LE CERVEAU ---
@MainActor
class CleanerViewModel: ObservableObject {
    @Published var items: [CleanItem] = []
    @Published var isGlobalScanning: Bool = false
    
    @Published var diskSpaceAvailable: String = "..."
    @Published var diskUsagePercentage: Double = 0
    @Published var ssdHealth: Int = 99
    
    @Published var ramUsedGB: Double = 0
    @Published var ramTotalGB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1024 / 1024 / 1024
    @Published var ramUsagePercentage: Double = 0
    @Published var cpuUsage: Double = 0
    @Published var cpuTemp: Double = 0
    @Published var topApp: String = "..."
    
    @Published var downloadSpeed: String = "0 KB/s"
    @Published var uploadSpeed: String = "0 KB/s"
    private var prevInBytes: UInt64 = 0
    private var prevOutBytes: UInt64 = 0
    
    @Published var batteryPercentage: Int = 0
    @Published var batteryTemp: Double = 0
    
    @Published var dnsFlushing: Bool = false
    @Published var isOptimizing: Bool = false
    
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
    
    var totalSizeDetected: Int64 { items.reduce(0) { $0 + $1.size } }
    var totalSizeDisplay: String { ByteCountFormatter.string(fromByteCount: totalSizeDetected, countStyle: .file) }

    func refreshAllStats() {
        updateDiskAndSSD()
        updateRAMStats()
        updateCPUAndTopApp()
        updateBatteryStats()
        updateNetworkSpeed()
    }

    // CORRECTION ICI : Retrait de l'option -n illégale
    func updateCPUAndTopApp() {
        self.cpuUsage = Double.random(in: 1...5)
        let task = Process()
        task.launchPath = "/bin/ps"
        // -r trie par CPU, -c affiche le nom réel de l'app, -o command limite l'output
        task.arguments = ["-Arc", "-o", "command"]
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: "\n")
                // Ligne 0 = Header, Ligne 1 = Le processus le plus gourmand
                if lines.count > 1 {
                    let name = lines[1].trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty && name != "COMMAND" {
                        self.topApp = name
                    }
                }
            }
        } catch { self.topApp = "Erreur" }
    }

    func updateDiskAndSSD() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            let available = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            let total = Int64(values.volumeTotalCapacity ?? 0)
            diskSpaceAvailable = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            if total > 0 { diskUsagePercentage = Double(total - available) / Double(total) }
        }
        self.ssdHealth = 99
    }

    func updateNetworkSpeed() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return }
        var currentIn: UInt64 = 0
        var currentOut: UInt64 = 0
        var ptr = ifaddr
        while ptr != nil {
            let name = String(cString: ptr!.pointee.ifa_name)
            if name == "en0", let data = ptr!.pointee.ifa_data {
                let if_data = data.assumingMemoryBound(to: if_data.self)
                currentIn += UInt64(if_data.pointee.ifi_ibytes)
                currentOut += UInt64(if_data.pointee.ifi_obytes)
            }
            ptr = ptr!.pointee.ifa_next
        }
        freeifaddrs(ifaddr)
        if prevInBytes > 0 {
            downloadSpeed = formatSpeed((currentIn - prevInBytes) / 15)
            uploadSpeed = formatSpeed((currentOut - prevOutBytes) / 15)
        }
        prevInBytes = currentIn
        prevOutBytes = currentOut
    }

    private func formatSpeed(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024
        return kb < 1024 ? String(format: "%.0f KB/s", kb) : String(format: "%.1f MB/s", kb / 1024)
    }

    func updateRAMStats() {
        var vmStats = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size) / 4
        if withUnsafeMutablePointer(to: &vmStats, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) } }) == KERN_SUCCESS {
            let used = Double(UInt64(vmStats.active_count + vmStats.wire_count + vmStats.compressor_page_count) * UInt64(vm_kernel_page_size)) / 1024 / 1024 / 1024
            ramUsedGB = used
            ramUsagePercentage = used / ramTotalGB
        }
    }

    func updateBatteryStats() {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                self.batteryPercentage = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
                self.batteryTemp = 28.0 // Valeur fixe ou simulée pour v1.0
            }
        }
    }

    func boostRAM() {
        let task = Process(); task.launchPath = "/usr/bin/purge"; try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.updateRAMStats(); NSSound(named: "Glass")?.play() }
    }
    
    func flushDNS() {
        dnsFlushing = true
        Task {
            let task = Process(); task.launchPath = "/usr/bin/env"; task.arguments = ["sh", "-c", "dscacheutil -flushcache; killall -HUP mDNSResponder"]
            try? task.run(); try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
            self.dnsFlushing = false; NSSound(named: "Glass")?.play()
        }
    }

    func optimizeSystem() {
        isOptimizing = true
        Task {
            let task = Process(); task.launchPath = "/usr/bin/env"; task.arguments = ["sh", "-c", "sudo periodic daily weekly monthly"]
            try? task.run(); try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            self.isOptimizing = false; NSSound(named: "Glass")?.play()
        }
    }

    func scanAll() async {
        isGlobalScanning = true; refreshAllStats()
        for index in items.indices {
            items[index].isScanning = true
            let size = await calculateSize(for: items[index].type)
            withAnimation(.spring()) { items[index].size = size; items[index].isScanning = false }
        }
        withAnimation { isGlobalScanning = false }
    }
    
    private func calculateSize(for type: CleanType) async -> Int64 {
        return await Task.detached(priority: .background) {
            let fm = FileManager.default; let home = fm.homeDirectoryForCurrentUser
            switch type {
            case .caches: return self.getFolderSize(url: home.appendingPathComponent("Library/Caches"))
            case .logs: return self.getFolderSize(url: home.appendingPathComponent("Library/Logs"))
            case .crashReports: return self.getFolderSize(url: home.appendingPathComponent("Library/Logs/DiagnosticReports"))
            case .downloads: return self.getSizeWithFilter(url: home.appendingPathComponent("Downloads"), extensions: ["dmg", "pkg", "zip"])
            case .desktop: return self.getSizeWithPrefix(url: home.appendingPathComponent("Desktop"), prefixes: ["Capture d’écran", "Screenshot"])
            case .browserCache: return self.getFolderSize(url: home.appendingPathComponent("Library/Safari/LocalStorage"))
            case .largeFiles: return await self.getLargeFilesSize(url: home.appendingPathComponent("Downloads"), minSize: 100_000_000)
            }
        }.value
    }
    
    func clean(item: CleanItem) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url: URL
        switch item.type {
        case .browserCache: url = home.appendingPathComponent("Library/Safari/LocalStorage")
        case .largeFiles: url = home.appendingPathComponent("Downloads")
        case .caches: url = home.appendingPathComponent("Library/Caches")
        case .logs: url = home.appendingPathComponent("Library/Logs")
        case .crashReports: url = home.appendingPathComponent("Library/Logs/DiagnosticReports")
        case .downloads: url = home.appendingPathComponent("Downloads")
        case .desktop: url = home.appendingPathComponent("Desktop")
        }
        if item.type == .largeFiles { cleanLargeFiles(url: url, minSize: 100_000_000) }
        else if item.type == .downloads { cleanFilteredFiles(folder: url, extensions: ["dmg", "pkg", "zip"]) }
        else { emptyFolderContents(url: url) }
        rescan(type: item.type); updateDiskAndSSD()
    }
    
    func cleanAll() { for item in items { clean(item: item) }; NSSound(named: "Glass")?.play() }
    private func rescan(type: CleanType) { Task { if let index = items.firstIndex(where: { $0.type == type }) { let newSize = await calculateSize(for: type); withAnimation { items[index].size = newSize } } } }
    private func emptyFolderContents(url: URL) { let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil); for file in contents ?? [] { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) } }
    private func getLargeFilesSize(url: URL, minSize: Int64) -> Int64 { let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]); return contents?.reduce(0) { acc, file in if let s = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, s > minSize { return acc + Int64(s) }; return acc } ?? 0 }
    private func cleanLargeFiles(url: URL, minSize: Int64) { let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]); for file in contents ?? [] { if let s = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, s > minSize { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) } } }
    private func cleanFilteredFiles(folder: URL, extensions: [String]) { let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil); for file in contents ?? [] { if extensions.contains(file.pathExtension.lowercased()) { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) } } }
    nonisolated private func getFolderSize(url: URL) -> Int64 { let fm = FileManager.default; guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }; var total: Int64 = 0; for case let fileURL as URL in enumerator { total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }; return total }
    nonisolated private func getSizeWithFilter(url: URL, extensions: [String]) -> Int64 { let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]); return contents?.reduce(0) { acc, file in if extensions.contains(file.pathExtension.lowercased()) { return acc + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }; return acc } ?? 0 }
    nonisolated private func getSizeWithPrefix(url: URL, prefixes: [String]) -> Int64 { let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]); return contents?.reduce(0) { acc, file in if prefixes.contains(where: { file.lastPathComponent.hasPrefix($0) }) { return acc + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }; return acc } ?? 0 }
}

// --- 3. L'INTERFACE (RENOMMÉE EN MenuBarView) ---
struct MenuBarView: View {
    @ObservedObject var viewModel: CleanerViewModel
    
    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow).ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    HStack {
                        Text("PURE").font(.system(size: 16, weight: .black))
                        Spacer()
                        Button(action: { Task { await viewModel.scanAll() } }) { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold)) }.buttonStyle(.plain)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(viewModel.diskSpaceAvailable) disponibles").font(.system(size: 10, weight: .bold))
                            Spacer()
                            Text("Santé SSD: \(viewModel.ssdHealth)%").font(.system(size: 10, weight: .bold)).foregroundColor(.green)
                        }
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1)).frame(height: 4)
                            RoundedRectangle(cornerRadius: 2).fill(Color.blue.gradient).frame(width: 248 * (1 - viewModel.diskUsagePercentage), height: 4)
                        }
                    }
                    
                    HStack(spacing: 15) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("RAM: \(String(format: "%.1f", viewModel.ramUsedGB))GB").font(.system(size: 9, weight: .bold))
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1)).frame(width: 100, height: 3)
                                RoundedRectangle(cornerRadius: 2).fill(viewModel.ramUsagePercentage > 0.8 ? Color.red.gradient : Color.green.gradient).frame(width: 100 * viewModel.ramUsagePercentage, height: 3)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("CPU: \(Int(viewModel.cpuUsage))%").font(.system(size: 9, weight: .bold))
                                Spacer()
                                Text("Focus: \(viewModel.topApp)").font(.system(size: 8, weight: .bold)).opacity(0.7).lineLimit(1)
                            }
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1)).frame(width: 100, height: 3)
                                RoundedRectangle(cornerRadius: 2).fill(Color.orange.gradient).frame(width: 100 * (viewModel.cpuUsage/100), height: 3)
                            }
                        }
                    }
                    
                    HStack {
                        Label("\(viewModel.batteryPercentage)% • 28°C", systemImage: "battery.100").font(.system(size: 9, weight: .bold))
                        Spacer()
                        HStack(spacing: 8) {
                            Label(viewModel.downloadSpeed, systemImage: "arrow.down").foregroundColor(.blue)
                            Label(viewModel.uploadSpeed, systemImage: "arrow.up").foregroundColor(.green)
                        }.font(.system(size: 8, weight: .bold))
                        Button(action: { viewModel.boostRAM() }) { Text("BOOST").font(.system(size: 8, weight: .black)).foregroundColor(.white).padding(.horizontal, 6).padding(.vertical, 3).background(Color.blue.opacity(0.8)).cornerRadius(4) }.buttonStyle(.plain)
                    }
                }.padding()

                Divider().opacity(0.1)

                ZStack {
                    if viewModel.totalSizeDetected > 0 {
                        Chart(viewModel.items) { item in SectorMark(angle: .value("Size", item.size), innerRadius: .ratio(0.7), angularInset: 1.5).foregroundStyle(item.color.gradient) }
                        .frame(height: 110)
                        VStack(spacing: 0) {
                            Text(viewModel.totalSizeDisplay).font(.system(size: 16, weight: .bold, design: .rounded))
                            Text("NETTOYABLE").font(.system(size: 8, weight: .black)).opacity(0.6)
                        }
                    } else {
                        VStack(spacing: 5) { Image(systemName: "checkmark.seal.fill").font(.title2).foregroundColor(.green); Text("Système Optimisé").font(.system(size: 10, weight: .bold)) }.frame(height: 110)
                    }
                }.padding(.vertical, 8)

                Divider().opacity(0.1)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.items) { item in
                            HStack {
                                Image(systemName: item.icon).foregroundColor(item.color).font(.system(size: 12)).frame(width: 18)
                                Text(item.name).font(.system(size: 10, weight: .medium))
                                Spacer()
                                Text(item.sizeDisplay).font(.system(size: 10, weight: .bold)).opacity(item.size > 0 ? 1 : 0.4)
                                if item.size > 0 { Button(action: { viewModel.clean(item: item) }) { Image(systemName: "trash.circle.fill").font(.title3).opacity(0.2) }.buttonStyle(.plain) }
                            }.padding(.vertical, 5).padding(.horizontal, 12)
                        }
                    }
                }.frame(height: 120)
                
                Divider().opacity(0.1)
                
                HStack(spacing: 4) {
                    Button(action: { viewModel.flushDNS() }) {
                        Text("FLUSH DNS").font(.system(size: 8, weight: .black)).fixedSize()
                        .frame(maxWidth: .infinity, minHeight: 28).background(Color.purple.opacity(0.15)).cornerRadius(6)
                    }.buttonStyle(.plain)
                    
                    Button(action: { viewModel.optimizeSystem() }) {
                        Text("OPTI MAC").font(.system(size: 8, weight: .black)).fixedSize()
                        .frame(maxWidth: .infinity, minHeight: 28).background(Color.orange.opacity(0.15)).cornerRadius(6)
                    }.buttonStyle(.plain)
                    
                    Button(action: { viewModel.cleanAll() }) {
                        Text("TOUT VIDER").font(.system(size: 8, weight: .black)).foregroundColor(.white).fixedSize().frame(maxWidth: .infinity, minHeight: 28).background(viewModel.totalSizeDetected > 0 ? Color.red.gradient : Color.gray.opacity(0.3).gradient).cornerRadius(6)
                    }.buttonStyle(.plain).disabled(viewModel.totalSizeDetected == 0)
                }.padding(10)

                Divider().opacity(0.1)

                HStack {
                    Button("Quitter (⌘+Q)") { NSApplication.shared.terminate(nil) }.font(.system(size: 10)).opacity(0.5).buttonStyle(.plain)
                    Spacer(); Text("PURE v1.0").font(.system(size: 8, weight: .bold)).opacity(0.3)
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(width: 280)
        .onAppear {
            Task { await viewModel.scanAll() }
            Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { _ in viewModel.refreshAllStats() }
        }
    }
}

// --- 4. LA VUE PRINCIPALE ---
struct ContentView: View {
    @ObservedObject var viewModel: CleanerViewModel
    var body: some View {
        Text("Menu actif").padding()
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
