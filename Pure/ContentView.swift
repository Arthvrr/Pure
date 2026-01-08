import SwiftUI
import AppKit
import Combine
import Charts

// --- 1. LE CERVEAU (LOGIQUE) ---

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

@MainActor
class CleanerViewModel: ObservableObject {
    @Published var items: [CleanItem] = []
    @Published var isGlobalScanning: Bool = false
    
    // Stockage
    @Published var diskSpaceAvailable: String = "..."
    @Published var diskSpaceTotal: String = "..."
    @Published var freePercentage: Double = 0
    
    // RAM
    @Published var ramUsedGB: Double = 0
    @Published var ramTotalGB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1024 / 1024 / 1024
    @Published var ramUsagePercentage: Double = 0
    
    private let fileManager = FileManager.default
    
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
        refreshStats()
    }
    
    func refreshStats() {
        updateDiskStats()
        updateRAMStats()
    }
    
    // Correction calcul stockage (Espace disponible vs libre)
    private func updateDiskStats() {
        let path = NSHomeDirectory()
        // On utilise URL(fileURLWithPath:)
        let url = URL(fileURLWithPath: path)
        
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            // ATTENTION : Bien mettre "UsageKey" avec un 'K' majuscule à la fin
            let available = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            let total = Int64(values.volumeTotalCapacity ?? 0)
            
            diskSpaceAvailable = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            diskSpaceTotal = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            
            // Calcul du pourcentage pour la barre de progression
            if total > 0 {
                freePercentage = Double(total - available) / Double(total)
            }
        }
    }
    
    // Stats RAM
    func updateRAMStats() {
        var stats = host_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_basic_info>.size) / 4
        let kerr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_info(mach_host_self(), HOST_BASIC_INFO, $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let total = Double(stats.max_mem) / 1024 / 1024 / 1024
            
            var vmStats = vm_statistics64()
            var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size) / 4
            let vmKerr = withUnsafeMutablePointer(to: &vmStats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
                }
            }
            
            if vmKerr == KERN_SUCCESS {
                let pageSize = UInt64(vm_kernel_page_size)
                let active = Double(UInt64(vmStats.active_count) * pageSize)
                
                // CORRECTION ICI : c'est "wire_count" (sans le 'd') dans la structure système
                let wired = Double(UInt64(vmStats.wire_count) * pageSize)
                
                let compressed = Double(UInt64(vmStats.compressor_page_count) * pageSize)
                
                let used = (active + wired + compressed) / 1024 / 1024 / 1024
                ramUsedGB = used
                ramUsagePercentage = used / ramTotalGB
            }
        }
    }
    
    // Action Boost RAM
    func boostRAM() {
        let task = Process()
        task.launchPath = "/usr/bin/purge"
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.updateRAMStats()
            self.playSound()
        }
    }

    // (Méthodes de scan et clean identiques au code précédent...)
    func scanAll() async {
        isGlobalScanning = true
        refreshStats()
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
        let home = FileManager.default.homeDirectoryForCurrentUser
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

// --- 2. VUE FANTÔME ---
struct ContentView: View {
    @ObservedObject var viewModel: CleanerViewModel
    var body: some View { EmptyView() }
}

// --- 3. INTERFACE ---

struct MenuBarView: View {
    @ObservedObject var viewModel: CleanerViewModel
    @State private var selectedAngle: Int64?
    
    var body: some View {
        ZStack {
            // Effet translucide sur TOUT le fond
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // SECTION HAUTE : STOCKAGE & RAM
                VStack(spacing: 12) {
                    HStack {
                        Text("PURE").font(.system(size: 16, weight: .black))
                        Spacer()
                        Button(action: { Task { await viewModel.scanAll() } }) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold))
                        }.buttonStyle(.plain)
                    }
                    
                    // Barre Disque
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(viewModel.diskSpaceAvailable) disponibles").font(.system(size: 10, weight: .bold))
                            Spacer()
                            Text("sur \(viewModel.diskSpaceTotal)").font(.system(size: 10)).opacity(0.6)
                        }
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1)).frame(height: 4)
                            RoundedRectangle(cornerRadius: 2).fill(Color.blue.gradient)
                                .frame(width: 248 * (1 - viewModel.freePercentage), height: 4)
                        }
                    }
                    
                    // Module RAM (Nouveau)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Mémoire RAM : \(String(format: "%.1f", viewModel.ramUsedGB)) GB / \(Int(viewModel.ramTotalGB)) GB").font(.system(size: 10, weight: .bold))
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1)).frame(height: 4)
                                RoundedRectangle(cornerRadius: 2).fill(viewModel.ramUsagePercentage > 0.8 ? Color.red.gradient : Color.green.gradient)
                                    .frame(width: 160 * viewModel.ramUsagePercentage, height: 4)
                            }
                        }
                        Spacer()
                        Button(action: { viewModel.boostRAM() }) {
                            Text("BOOST").font(.system(size: 9, weight: .black)).foregroundColor(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.blue.opacity(0.8)).cornerRadius(4)
                        }.buttonStyle(.plain)
                    }
                }
                .padding()

                Divider().opacity(0.2)

                // GRAPHIQUE
                ZStack {
                    if viewModel.totalSizeDetected > 0 {
                        Chart(viewModel.items) { item in
                            SectorMark(angle: .value("Size", item.size), innerRadius: .ratio(0.7), angularInset: 1.5)
                                .foregroundStyle(item.color.gradient)
                                .opacity(selectedAngle != nil ? 0.3 : 1.0)
                        }
                        .chartAngleSelection(value: $selectedAngle)
                        .frame(height: 120)
                        
                        VStack(spacing: 0) {
                            if viewModel.isGlobalScanning {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(viewModel.totalSizeDisplay).font(.system(size: 18, weight: .bold, design: .rounded))
                                Text("NETTOYABLE").font(.system(size: 8, weight: .black)).opacity(0.6)
                            }
                        }
                    } else {
                        VStack(spacing: 5) {
                            Image(systemName: "checkmark.seal.fill").font(.title).foregroundColor(.green)
                            Text("Système Optimisé").font(.caption).bold()
                        }.frame(height: 120)
                    }
                }
                .padding(.vertical, 10)

                Divider().opacity(0.2)

                // LISTE
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(viewModel.items) { item in
                            HStack(spacing: 12) {
                                Image(systemName: item.icon).foregroundColor(item.color).font(.system(size: 14)).frame(width: 20)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(item.name).font(.system(size: 11, weight: .medium))
                                    Text(item.sizeDisplay).font(.system(size: 10, weight: .bold)).opacity(item.size > 0 ? 1 : 0.5)
                                }
                                Spacer()
                                if item.size > 0 {
                                    Button(action: { viewModel.clean(item: item) }) {
                                        Image(systemName: "trash.circle.fill").font(.title2).opacity(0.3)
                                    }.buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 6).padding(.horizontal, 12)
                        }
                    }
                }
                .frame(height: 160)

                Divider().opacity(0.2)

                // FOOTER
                HStack {
                    Button("Quitter") { NSApplication.shared.terminate(nil) }
                        .font(.system(size: 11)).opacity(0.6).buttonStyle(.plain)
                    Spacer()
                    if viewModel.totalSizeDetected > 0 {
                        Button(action: { viewModel.cleanAll() }) {
                            Text("TOUT VIDER").font(.system(size: 11, weight: .black)).foregroundColor(.white)
                                .padding(.horizontal, 15).padding(.vertical, 8)
                                .background(Color.red.gradient).cornerRadius(6)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 280)
        .onAppear {
            Task { await viewModel.scanAll() }
            // Timer pour rafraîchir la RAM en temps réel
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                viewModel.updateRAMStats()
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
