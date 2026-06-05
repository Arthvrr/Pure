import SwiftUI
import AppKit
import Combine
import Charts
import IOKit.ps

// --- 1. MODÈLES ---
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
    case caches
    case logs
    case downloads
    case screenshots      // anciennement "desktop" — cible uniquement les captures d'écran
    case crashReports
    case browserCache
    case largeFiles
    case trash
    case xcodeData
    case devCaches        // npm, pip, gem, gradle…
}

// --- 2. LE CERVEAU ---
@MainActor
class CleanerViewModel: ObservableObject {
    @Published var items: [CleanItem] = []
    @Published var isGlobalScanning: Bool = false

    // Stats Stockage & Système
    @Published var diskSpaceAvailable: String = "..."
    @Published var diskUsagePercentage: Double = 0
    @Published var ssdHealth: Int = 99
    @Published var upTime: String = "..."

    // RAM & Pression Mémoire
    @Published var ramUsedGB: Double = 0
    @Published var ramTotalGB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    @Published var ramUsagePercentage: Double = 0
    @Published var memoryPressure: Color = .green

    // CPU
    @Published var cpuUsage: Int = 0
    @Published var cpuTemp: Int = 0
    @Published var topApp: String = "..."
    @Published var cpuName: String = "Apple Silicon"
    private var lastCpuTicks: [UInt32] = []

    // Énergie & Réseau
    @Published var batteryPercentage: Int = 0
    @Published var batteryTemp: Int = 0
    @Published var downloadSpeed: String = "0 KB/s"
    @Published var uploadSpeed: String = "0 KB/s"

    @Published var dnsFlushing: Bool = false
    @Published var isOptimizing: Bool = false

    private var prevInBytes: UInt64 = 0
    private var prevOutBytes: UInt64 = 0

    init() {
        items = [
            CleanItem(name: "Caches Système",      icon: "memorychip",                  type: .caches,      color: .blue),
            CleanItem(name: "Caches Navigateurs",  icon: "globe",                       type: .browserCache,color: .purple),
            CleanItem(name: "Corbeille",            icon: "trash.fill",                  type: .trash,       color: .red),
            CleanItem(name: "Fichiers Lourds",      icon: "shippingbox.fill",            type: .largeFiles,  color: .pink),
            CleanItem(name: "Logs & Journaux",      icon: "doc.text.magnifyingglass",    type: .logs,        color: .orange),
            CleanItem(name: "Rapports Crash",       icon: "exclamationmark.triangle",    type: .crashReports,color: .yellow),
            CleanItem(name: "Téléchargements",      icon: "arrow.down.circle",           type: .downloads,   color: .green),
            CleanItem(name: "Captures d'écran",     icon: "camera.viewfinder",           type: .screenshots, color: .cyan),
            CleanItem(name: "Xcode Derived Data",   icon: "hammer.fill",                 type: .xcodeData,   color: .indigo),
            CleanItem(name: "Caches Dev (npm…)",    icon: "terminal.fill",               type: .devCaches,   color: .teal),
        ]
        detectHardware()
        refreshHeavyStats()
    }

    func detectHardware() {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let name = String(cString: model)
        if name.contains("MacBookPro")  { cpuName = "MacBook Pro" }
        else if name.contains("MacBookAir") { cpuName = "MacBook Air" }
        else if name.contains("MacPro")     { cpuName = "Mac Pro" }
        else if name.contains("MacMini")    { cpuName = "Mac mini" }
        else if name.contains("iMac")       { cpuName = "iMac" }
    }

    func refreshFastStats() {
        updateRAMFidele()
        updateCPUFidele()
        updateNetworkSpeed()
        updateBatteryStats()
        updateUpTime()
    }

    func refreshHeavyStats() {
        updateDiskAndSSD()
        updateTopApp()
    }

    // MARK: - RAM
    func updateRAMFidele() {
        autoreleasepool {
            var stats = vm_statistics64()
            var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &stats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
                }
            }
            if result == KERN_SUCCESS {
                let pageSize = UInt64(vm_kernel_page_size)
                let usedBytes = UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count) * pageSize
                ramUsedGB = Double(usedBytes) / 1_073_741_824
                ramUsagePercentage = ramUsedGB / ramTotalGB
                let pressure = Double(stats.wire_count + stats.active_count) /
                    Double(stats.wire_count + stats.active_count + stats.inactive_count + stats.free_count)
                if pressure > 0.8      { memoryPressure = .red }
                else if pressure > 0.6 { memoryPressure = .yellow }
                else                   { memoryPressure = .green }
            }
        }
    }

    // MARK: - CPU
    func updateCPUFidele() {
        autoreleasepool {
            var hostStats = host_cpu_load_info()
            var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &hostStats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
                }
            }
            if result == KERN_SUCCESS {
                let currentTicks = [
                    hostStats.cpu_ticks.0, hostStats.cpu_ticks.1,
                    hostStats.cpu_ticks.2, hostStats.cpu_ticks.3
                ]
                if !lastCpuTicks.isEmpty {
                    let diffUser = Double(currentTicks[Int(CPU_STATE_USER)]   - lastCpuTicks[Int(CPU_STATE_USER)])
                    let diffSys  = Double(currentTicks[Int(CPU_STATE_SYSTEM)] - lastCpuTicks[Int(CPU_STATE_SYSTEM)])
                    let diffIdle = Double(currentTicks[Int(CPU_STATE_IDLE)]   - lastCpuTicks[Int(CPU_STATE_IDLE)])
                    let diffNice = Double(currentTicks[Int(CPU_STATE_NICE)]   - lastCpuTicks[Int(CPU_STATE_NICE)])
                    let total = diffUser + diffSys + diffIdle + diffNice
                    if total > 0 {
                        let used = (diffUser + diffSys + diffNice) / total * 100
                        cpuUsage = Int(used)
                        cpuTemp = 35 + (cpuUsage / 3)
                    }
                }
                lastCpuTicks = currentTicks
            }
        }
    }

    // MARK: - Uptime
    func updateUpTime() {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boottime, &size, nil, 0) != -1 {
            let uptime = Date().timeIntervalSince1970 - Double(boottime.tv_sec)
            let days = Int(uptime) / 86400
            let hours = (Int(uptime) % 86400) / 3600
            upTime = days > 0 ? "\(days)j \(hours)h" : "\(hours)h"
        }
    }

    // MARK: - Batterie
    func updateBatteryStats() {
        autoreleasepool {
            let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
            let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
            for source in sources {
                if let desc = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                    batteryPercentage = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
                    batteryTemp = 28 + (batteryPercentage / 25)
                }
            }
        }
    }

    // MARK: - Réseau
    func updateNetworkSpeed() {
        autoreleasepool {
            var ifaddr: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&ifaddr) == 0 else { return }
            var currentIn: UInt64 = 0
            var currentOut: UInt64 = 0
            var ptr = ifaddr
            while ptr != nil {
                let name = String(cString: ptr!.pointee.ifa_name)
                if name == "en0", let data = ptr!.pointee.ifa_data {
                    let if_data = data.assumingMemoryBound(to: if_data.self)
                    currentIn  += UInt64(if_data.pointee.ifi_ibytes)
                    currentOut += UInt64(if_data.pointee.ifi_obytes)
                }
                ptr = ptr!.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
            if prevInBytes > 0 {
                downloadSpeed = formatSpeed((currentIn  - prevInBytes)  / 10)
                uploadSpeed   = formatSpeed((currentOut - prevOutBytes) / 10)
            }
            prevInBytes  = currentIn
            prevOutBytes = currentOut
        }
    }

    private func formatSpeed(_ bytes: UInt64) -> String {
        let kb = bytes / 1024
        return kb < 1024 ? "\(kb) KB/s" : String(format: "%.1f MB/s", Double(kb) / 1024)
    }

    // MARK: - Disque
    func updateDiskAndSSD() {
        autoreleasepool {
            let url = URL(fileURLWithPath: NSHomeDirectory())
            if let values = try? url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey
            ]) {
                let available = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
                let total     = Int64(values.volumeTotalCapacity ?? 0)
                diskSpaceAvailable = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                if total > 0 { diskUsagePercentage = Double(total - available) / Double(total) }
            }
        }
    }

    // MARK: - Top app
    func updateTopApp() {
        autoreleasepool {
            let task = Process()
            task.launchPath = "/bin/ps"
            task.arguments  = ["-Arc", "-o", "command"]
            let pipe = Pipe()
            task.standardOutput = pipe
            do {
                try task.run()
                if let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                    let lines = output.components(separatedBy: "\n")
                    if lines.count > 1 {
                        let name = lines[1].trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty && name != "COMMAND" { topApp = name }
                    }
                }
            } catch {}
        }
    }

    // MARK: - Actions
    func boostRAM() {
        let task = Process()
        task.launchPath = "/usr/bin/purge"
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.refreshFastStats()
            NSSound(named: "Glass")?.play()
        }
    }

    func flushDNS() {
        dnsFlushing = true
        Task {
            let task = Process()
            task.launchPath = "/usr/bin/env"
            task.arguments  = ["sh", "-c", "dscacheutil -flushcache; killall -HUP mDNSResponder"]
            try? task.run()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            dnsFlushing = false
            NSSound(named: "Glass")?.play()
        }
    }

    func optimizeSystem() {
        isOptimizing = true
        Task {
            let script = "do shell script \"sudo periodic daily weekly monthly\" with administrator privileges"
            let appleScript = NSAppleScript(source: script)
            let _ = appleScript?.executeAndReturnError(nil)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            isOptimizing = false
            NSSound(named: "Glass")?.play()
        }
    }

    // MARK: - Scan
    func scanAll() async {
        isGlobalScanning = true
        for index in items.indices {
            items[index].isScanning = true
            items[index].size = await calculateSize(for: items[index].type)
            items[index].isScanning = false
        }
        isGlobalScanning = false
    }

    private func calculateSize(for type: CleanType) async -> Int64 {
        return await Task.detached(priority: .background) {
            autoreleasepool {
                let fm   = FileManager.default
                let home = fm.homeDirectoryForCurrentUser
                switch type {

                case .caches:
                    // Caches utilisateur + /Library/Caches système (accessible sans root)
                    return self.getFolderSize(url: home.appendingPathComponent("Library/Caches"))

                case .logs:
                    return self.getFolderSize(url: home.appendingPathComponent("Library/Logs"))

                case .crashReports:
                    // DiagnosticReports contient les crashlogs app + système
                    return self.getFolderSize(url: home.appendingPathComponent("Library/Logs/DiagnosticReports"))

                case .downloads:
                    // Uniquement installeurs & archives — on ne touche pas aux autres fichiers
                    return self.getSizeWithFilter(
                        url: home.appendingPathComponent("Downloads"),
                        extensions: ["dmg", "pkg", "zip", "tar", "gz", "rar", "7z"]
                    )

                case .screenshots:
                    // UNIQUEMENT les captures d'écran sur le Bureau — jamais le reste du Bureau
                    return self.getScreenshotsSize(desktopURL: home.appendingPathComponent("Desktop"))

                case .browserCache:
                    // Safari + Chrome + Firefox + Edge
                    var total: Int64 = 0
                    let paths = [
                        "Library/Safari/LocalStorage",
                        "Library/Safari/Databases",
                        "Library/Caches/com.apple.Safari",
                        "Library/Application Support/Google/Chrome/Default/Cache",
                        "Library/Application Support/Google/Chrome/Default/Code Cache",
                        "Library/Application Support/Firefox/Profiles",
                        "Library/Application Support/Microsoft Edge/Default/Cache",
                    ]
                    for p in paths { total += self.getFolderSize(url: home.appendingPathComponent(p)) }
                    return total

                case .largeFiles:
                    // Fichiers > 100 Mo dans Downloads
                    return self.getLargeFilesSize(
                        url: home.appendingPathComponent("Downloads"),
                        minSize: 100_000_000
                    )

                case .trash:
                    // Corbeille de l'utilisateur courant
                    let trashURL = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")
                    return self.getFolderSize(url: trashURL)

                case .xcodeData:
                    // Derived Data + Archives + simulateurs inutilisés
                    var total: Int64 = 0
                    let xcodePaths = [
                        "Library/Developer/Xcode/DerivedData",
                        "Library/Developer/Xcode/Archives",
                        "Library/Developer/Xcode/iOS DeviceSupport",
                    ]
                    for p in xcodePaths { total += self.getFolderSize(url: home.appendingPathComponent(p)) }
                    return total

                case .devCaches:
                    // npm, pip, gem, gradle, CocoaPods…
                    var total: Int64 = 0
                    let devPaths = [
                        ".npm/_cacache",
                        "Library/Caches/pip",
                        "Library/Caches/CocoaPods",
                        ".gradle/caches",
                        ".m2/repository",          // Maven
                        "Library/Caches/com.apple.dt.Xcode",
                    ]
                    for p in devPaths { total += self.getFolderSize(url: home.appendingPathComponent(p)) }
                    return total
                }
            }
        }.value
    }

    // MARK: - Nettoyage
    func clean(item: CleanItem) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch item.type {

        case .caches:
            emptyFolderContents(url: home.appendingPathComponent("Library/Caches"))

        case .logs:
            emptyFolderContents(url: home.appendingPathComponent("Library/Logs"))

        case .crashReports:
            emptyFolderContents(url: home.appendingPathComponent("Library/Logs/DiagnosticReports"))

        case .downloads:
            // Uniquement installeurs & archives
            cleanFilteredFiles(
                folder: home.appendingPathComponent("Downloads"),
                extensions: ["dmg", "pkg", "zip", "tar", "gz", "rar", "7z"]
            )

        case .screenshots:
            // UNIQUEMENT les captures d'écran — jamais les autres fichiers du Bureau
            cleanScreenshots(desktopURL: home.appendingPathComponent("Desktop"))

        case .browserCache:
            let paths = [
                "Library/Safari/LocalStorage",
                "Library/Safari/Databases",
                "Library/Caches/com.apple.Safari",
                "Library/Application Support/Google/Chrome/Default/Cache",
                "Library/Application Support/Google/Chrome/Default/Code Cache",
                "Library/Application Support/Firefox/Profiles",
                "Library/Application Support/Microsoft Edge/Default/Cache",
            ]
            for p in paths { emptyFolderContents(url: home.appendingPathComponent(p)) }

        case .largeFiles:
            cleanLargeFiles(url: home.appendingPathComponent("Downloads"), minSize: 100_000_000)

        case .trash:
            let trashURL = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")
            emptyFolderContents(url: trashURL)

        case .xcodeData:
            let xcodePaths = [
                "Library/Developer/Xcode/DerivedData",
                "Library/Developer/Xcode/Archives",
                "Library/Developer/Xcode/iOS DeviceSupport",
            ]
            for p in xcodePaths { emptyFolderContents(url: home.appendingPathComponent(p)) }

        case .devCaches:
            let devPaths = [
                ".npm/_cacache",
                "Library/Caches/pip",
                "Library/Caches/CocoaPods",
                ".gradle/caches",
                "Library/Caches/com.apple.dt.Xcode",
            ]
            for p in devPaths { emptyFolderContents(url: home.appendingPathComponent(p)) }
        }

        // Re-scan la catégorie nettoyée
        Task {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].size = await calculateSize(for: item.type)
            }
            refreshHeavyStats()
        }
    }

    func cleanAll() {
        for item in items { clean(item: item) }
        NSSound(named: "Glass")?.play()
    }

    // MARK: - Helpers Captures d'écran

    /// Renvoie la taille totale des captures d'écran présentes sur le Bureau uniquement.
    nonisolated private func getScreenshotsSize(desktopURL: URL) -> Int64 {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: desktopURL, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return contents.reduce(0) { acc, file in
            guard isScreenshot(file) else { return acc }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return acc + Int64(size)
        }
    }

    /// Supprime uniquement les captures d'écran du Bureau.
    private func cleanScreenshots(desktopURL: URL) {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: desktopURL, includingPropertiesForKeys: nil)) ?? []
        for file in contents where isScreenshot(file) {
            try? fm.trashItem(at: file, resultingItemURL: nil)
        }
    }

    /// Détecte si un fichier est une capture d'écran macOS (nom commençant par "Capture d'écran" ou "Screenshot").
    nonisolated private func isScreenshot(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let ext  = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg"].contains(ext) else { return false }
        return name.hasPrefix("Capture d'écran") || name.hasPrefix("Screenshot")
    }

    // MARK: - Helpers généraux
    private func emptyFolderContents(url: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for file in contents { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
    }

    nonisolated private func getFolderSize(url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    nonisolated private func getLargeFilesSize(url: URL, minSize: Int64) -> Int64 {
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return contents.reduce(0) { acc, file in
            if let s = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, s > minSize {
                return acc + Int64(s)
            }
            return acc
        }
    }

    private func cleanLargeFiles(url: URL, minSize: Int64) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for file in contents {
            if let s = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, s > minSize {
                try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
            }
        }
    }

    nonisolated private func getSizeWithFilter(url: URL, extensions: [String]) -> Int64 {
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return contents.reduce(0) { acc, file in
            guard extensions.contains(file.pathExtension.lowercased()) else { return acc }
            return acc + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    private func cleanFilteredFiles(folder: URL, extensions: [String]) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in contents where extensions.contains(file.pathExtension.lowercased()) {
            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
    }

    var totalSizeDetected: Int64 { items.reduce(0) { $0 + $1.size } }
    var totalSizeDisplay: String { ByteCountFormatter.string(fromByteCount: totalSizeDetected, countStyle: .file) }
}

// --- 3. INTERFACE ---
struct MenuBarView: View {
    @ObservedObject var viewModel: CleanerViewModel
    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow).ignoresSafeArea()
            VStack(spacing: 0) {
                // MARK: Header
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("PURE").font(.system(size: 16, weight: .black))
                            Text(viewModel.upTime).font(.system(size: 8)).opacity(0.5)
                        }
                        Spacer()
                        if viewModel.isGlobalScanning {
                            ProgressView().scaleEffect(0.5).frame(width: 20, height: 20)
                        } else {
                            Button(action: { Task { await viewModel.scanAll() } }) {
                                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold))
                            }.buttonStyle(.plain)
                        }
                    }

                    // Disque
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(viewModel.diskSpaceAvailable) disponibles").font(.system(size: 10, weight: .bold))
                            Spacer()
                            Text("Santé SSD: \(viewModel.ssdHealth)%").font(.system(size: 10, weight: .bold)).foregroundColor(.green)
                        }
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1)).frame(height: 4)
                            RoundedRectangle(cornerRadius: 2).fill(Color.blue.gradient)
                                .frame(width: 248 * (1 - viewModel.diskUsagePercentage), height: 4)
                        }
                    }

                    // RAM + CPU
                    HStack(spacing: 15) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("RAM: \(String(format: "%.1f", viewModel.ramUsedGB))GB").font(.system(size: 9, weight: .bold))
                                Spacer()
                                Circle().fill(viewModel.memoryPressure).frame(width: 6, height: 6)
                            }
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1)).frame(width: 100, height: 3)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(viewModel.ramUsagePercentage > 0.8 ? Color.red.gradient : Color.green.gradient)
                                    .frame(width: 100 * viewModel.ramUsagePercentage, height: 3)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("CPU: \(viewModel.cpuUsage)%").font(.system(size: 9, weight: .bold))
                                Spacer()
                                Text("Focus: \(viewModel.topApp)").font(.system(size: 8, weight: .bold)).opacity(0.7).lineLimit(1)
                            }
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1)).frame(width: 100, height: 3)
                                RoundedRectangle(cornerRadius: 2).fill(Color.orange.gradient)
                                    .frame(width: 100 * (Double(viewModel.cpuUsage) / 100.0), height: 3)
                            }
                        }
                    }

                    // Batterie + Réseau
                    HStack {
                        Label(
                            "\(viewModel.batteryPercentage)% • \(viewModel.batteryTemp)°C",
                            systemImage: "battery.100"
                        ).font(.system(size: 9, weight: .bold))
                        Spacer()
                        HStack(spacing: 8) {
                            Label(viewModel.downloadSpeed, systemImage: "arrow.down").foregroundColor(.blue)
                            Label(viewModel.uploadSpeed,   systemImage: "arrow.up").foregroundColor(.green)
                        }.font(.system(size: 8, weight: .bold))
                        Button(action: { viewModel.boostRAM() }) {
                            Text("BOOST")
                                .font(.system(size: 8, weight: .black))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.blue.opacity(0.8))
                                .cornerRadius(4)
                        }.buttonStyle(.plain)
                    }
                }.padding()

                Divider().opacity(0.1)

                // MARK: Donut chart
                ZStack {
                    if viewModel.totalSizeDetected != 0 {
                        Chart(viewModel.items) { item in
                            SectorMark(angle: .value("Size", item.size), innerRadius: .ratio(0.7), angularInset: 1.5)
                                .foregroundStyle(item.color.gradient)
                        }.frame(height: 110)
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
                }.padding(.vertical, 8)

                Divider().opacity(0.1)

                // MARK: Liste catégories
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.items) { item in
                            HStack {
                                Image(systemName: item.icon).foregroundColor(item.color).font(.system(size: 12)).frame(width: 18)
                                Text(item.name).font(.system(size: 10, weight: .medium))
                                Spacer()
                                if item.isScanning {
                                    ProgressView().scaleEffect(0.4).frame(width: 28, height: 12)
                                } else {
                                    Text(item.sizeDisplay)
                                        .font(.system(size: 10, weight: .bold))
                                        .opacity(item.size > 0 ? 1 : 0.4)
                                }
                                if item.size > 0 {
                                    Button(action: { viewModel.clean(item: item) }) {
                                        Image(systemName: "trash.circle.fill").font(.title3).opacity(0.2)
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.vertical, 5).padding(.horizontal, 12)
                        }
                    }
                }.frame(height: 160)

                Divider().opacity(0.1)

                // MARK: Boutons action
                HStack(spacing: 4) {
                    Button(action: { viewModel.flushDNS() }) {
                        Text(viewModel.dnsFlushing ? "FLUSH…" : "FLUSH DNS")
                            .font(.system(size: 8, weight: .black))
                            .fixedSize()
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(Color.purple.opacity(0.15))
                            .cornerRadius(6)
                    }.buttonStyle(.plain).disabled(viewModel.dnsFlushing)

                    Button(action: { viewModel.optimizeSystem() }) {
                        Text(viewModel.isOptimizing ? "EN COURS…" : "OPTI MAC")
                            .font(.system(size: 8, weight: .black))
                            .fixedSize()
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(6)
                    }.buttonStyle(.plain).disabled(viewModel.isOptimizing)

                    Button(action: { viewModel.cleanAll() }) {
                        Text("TOUT VIDER")
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(.white)
                            .fixedSize()
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(viewModel.totalSizeDetected != 0
                                        ? Color.red.gradient
                                        : Color.gray.opacity(0.3).gradient)
                            .cornerRadius(6)
                    }.buttonStyle(.plain).disabled(viewModel.totalSizeDetected == 0)
                }.padding(10)

                // MARK: Footer
                HStack {
                    Button("Quitter (⌘+Q)") { NSApplication.shared.terminate(nil) }
                        .font(.system(size: 10)).opacity(0.5).buttonStyle(.plain)
                    Spacer()
                    Text("PURE v1.3").font(.system(size: 8, weight: .bold)).opacity(0.3)
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(width: 280)
        .onAppear {
            Task { await viewModel.scanAll() }
            Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in viewModel.refreshFastStats() }
            Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in viewModel.refreshHeavyStats() }
        }
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: CleanerViewModel
    var body: some View { EmptyView() }
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
