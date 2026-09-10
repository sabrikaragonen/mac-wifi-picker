import Cocoa
import CoreLocation
import CoreWLAN
import UserNotifications

enum NetworkPriority: String, Codable {
    case high
    case normal
    case low

    var title: String {
        switch self {
        case .high: return "High"
        case .normal: return "Normal"
        case .low: return "Low"
        }
    }

    var rank: Int {
        switch self {
        case .high: return 2
        case .normal: return 1
        case .low: return 0
        }
    }
}

struct Config: Codable {
    var overrides: [String: NetworkPriority] = [:]
    var autoHotspotLow = true
    var preferHigh = true
    var notifications = true
}

struct ProcessResult {
    let output: String
    let status: Int32
}

struct VisibleNetwork {
    let ssid: String
    let rssi: Int
}

struct LinkHealth {
    let reachable: Bool
    let packetLoss: Double
    let averageLatency: Double?

    var healthy: Bool {
        reachable && packetLoss <= 25 && (averageLatency ?? .greatestFiniteMagnitude) <= 180
    }

    var summary: String {
        guard reachable, let averageLatency else { return "internet unavailable" }
        return String(format: "%.0f ms, %.0f%% loss", averageLatency, packetLoss)
    }
}

enum CheckReason {
    case automatic
    case manual
}

struct CheckOutcome {
    let message: String
    let visibleNetworks: [VisibleNetwork]
    let switchedFrom: String?
    let switchedTo: String?
}

final class AppDelegate: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let fileManager = FileManager.default
    private let wifiClient = CWWiFiClient.shared()
    private let locationManager = CLLocationManager()
    private let checkQueue = DispatchQueue(label: "local.wifipicker.check", qos: .utility)

    private var config = Config()
    private var wifiDevice = "en0"
    private var refreshTimer: Timer?
    private var checkTimer: Timer?
    private var isChecking = false
    private var lastStatus = "Ready"
    private var cachedVisibleNetworks: [VisibleNetwork] = []
    private var cachedSavedSSIDs: [String] = []
    private var lastSavedRefresh = Date.distantPast

    // These values intentionally live in memory. Restarting the app clears a stale
    // cooldown or pending candidate instead of trapping the user on a bad network.
    private var lastSwitchDate: Date?
    private var pendingCandidate: String?
    private var pendingCandidateCount = 0
    private var rejectedUntil: [String: Date] = [:]

    private let checkInterval: TimeInterval = 180
    private let switchCooldown: TimeInterval = 15 * 60
    private let minimumUsableRSSI = -78
    private let sameTierRSSIGain = 12
    private let connectTimeout: TimeInterval = 10

    private var home: String { NSHomeDirectory() }
    private var applicationSupportDirectory: URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/WiFi Picker", isDirectory: true)
    }
    private var configURL: URL { applicationSupportDirectory.appendingPathComponent("config.json") }
    private var legacyConfigPath: String { home + "/.wifi-picker.conf" }
    private var logPath: String { home + "/Library/Logs/wifi-picker.log" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        wifiDevice = detectWiFiDevice() ?? wifiClient.interface()?.interfaceName ?? "en0"
        loadConfig()
        refreshSavedNetworks(force: true)

        locationManager.delegate = self
        requestNotificationAccessIfNeeded()

        // A circled symbol stays visually distinct from macOS's built-in Wi-Fi icon.
        statusItem.button?.image = NSImage(systemSymbolName: "wifi.circle",
                                           accessibilityDescription: "Wi-Fi Picker")
        statusItem.button?.toolTip = "Wi-Fi Picker"
        rebuildMenu()
        if locationManager.authorizationStatus == .authorized ||
            locationManager.authorizationStatus == .authorizedAlways {
            DispatchQueue.main.async { [weak self] in self?.refreshNearbyNetworks() }
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.rebuildMenu()
        }
        checkTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.startCheck(reason: .automatic)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch manager.authorizationStatus {
            case .authorized, .authorizedAlways:
                self.lastStatus = "Location access granted"
                self.rebuildMenu()
                self.refreshNearbyNetworks()
            case .denied, .restricted:
                self.lastStatus = "Location access is required for Wi-Fi scanning"
                self.rebuildMenu()
            default:
                break
            }
        }
    }

    private func requestNotificationAccessIfNeeded() {
        guard config.notifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func run(_ path: String, _ arguments: [String]) -> ProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ProcessResult(output: output, status: process.terminationStatus)
        } catch {
            return ProcessResult(output: error.localizedDescription, status: -1)
        }
    }

    private func detectWiFiDevice() -> String? {
        let output = run("/usr/sbin/networksetup", ["-listallhardwareports"]).output
        let lines = output.components(separatedBy: .newlines)
        for index in lines.indices where
            lines[index].contains("Hardware Port: Wi-Fi") || lines[index].contains("Hardware Port: AirPort") {
            let next = index + 1
            if lines.indices.contains(next), lines[next].hasPrefix("Device: ") {
                return String(lines[next].dropFirst(8))
            }
        }
        return nil
    }

    private func currentSSID() -> String? {
        if let ssid = wifiClient.interface(withName: wifiDevice)?.ssid(), !ssid.isEmpty {
            return ssid
        }
        let result = run("/usr/sbin/networksetup", ["-getairportnetwork", wifiDevice])
        guard result.status == 0,
              let separator = result.output.range(of: ": "),
              !result.output.localizedCaseInsensitiveContains("not associated") else { return nil }
        let ssid = String(result.output[separator.upperBound...])
        return ssid.isEmpty ? nil : ssid
    }

    private func currentRSSI() -> Int? {
        guard let interface = wifiClient.interface(withName: wifiDevice) else { return nil }
        let value = interface.rssiValue()
        return value == 0 ? nil : value
    }

    private func readSavedSSIDs() -> [String] {
        let result = run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", wifiDevice])
        guard result.status == 0 else { return [] }
        var seen = Set<String>()
        return result.output.components(separatedBy: .newlines).dropFirst().compactMap { line in
            let ssid = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ssid.isEmpty, seen.insert(ssid).inserted else { return nil }
            return ssid
        }
    }

    private func refreshSavedNetworks(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSavedRefresh) >= 300 else { return }
        cachedSavedSSIDs = readSavedSSIDs()
        lastSavedRefresh = Date()
    }

    private func scanVisibleSavedNetworks(savedSSIDs: Set<String>) throws -> [VisibleNetwork] {
        guard let interface = wifiClient.interface(withName: wifiDevice) else {
            throw NSError(domain: "WiFiPicker", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Wi-Fi interface is unavailable"])
        }
        let scanned = try interface.scanForNetworks(withSSID: nil)
        var strongest: [String: Int] = [:]
        for network in scanned {
            guard let ssid = network.ssid, savedSSIDs.contains(ssid) else { continue }
            strongest[ssid] = max(strongest[ssid] ?? Int.min, network.rssiValue)
        }
        // Keep the active network visible even when it is an Instant Hotspot or
        // another connection that networksetup does not expose as preferred.
        if let ssid = currentSSID() {
            strongest[ssid] = max(strongest[ssid] ?? Int.min, currentRSSI() ?? -100)
        }
        return strongest.map { VisibleNetwork(ssid: $0.key, rssi: $0.value) }
            .sorted { $0.rssi > $1.rssi }
    }

    private func effectivePriority(for ssid: String, config: Config) -> NetworkPriority {
        if let explicit = config.overrides[ssid] { return explicit }
        if config.autoHotspotLow {
            let hotspotTerms = ["iphone", "personal hotspot", "kişisel erişim noktası"]
            if hotspotTerms.contains(where: { ssid.localizedCaseInsensitiveContains($0) }) {
                return .low
            }
        }
        return .normal
    }

    private func priorityDisplay(for ssid: String, config: Config) -> String {
        let priority = effectivePriority(for: ssid, config: config)
        if config.overrides[ssid] != nil { return priority.title }
        if priority == .low { return "Low (auto)" }
        return priority.title
    }

    private func loadConfig() {
        do {
            let data = try Data(contentsOf: configURL)
            config = try JSONDecoder().decode(Config.self, from: data)
            return
        } catch {
            config = migrateLegacyConfig() ?? Config()
            saveConfig()
        }
    }

    private func migrateLegacyConfig() -> Config? {
        guard let text = try? String(contentsOfFile: legacyConfigPath, encoding: .utf8) else { return nil }
        var migrated = Config()
        for ssid in parseLegacyArray(text, name: "HIGH_PRIORITY_SSIDS") {
            migrated.overrides[ssid] = .high
        }
        for ssid in parseLegacyArray(text, name: "LOW_PRIORITY_SSIDS") {
            migrated.overrides[ssid] = .low
        }
        migrated.autoHotspotLow = !text.contains("HOTSPOT_REGEX=\"$^\"")
        migrated.preferHigh = !text.contains("PREFER_HIGH_PRIORITY=0")
        migrated.notifications = !text.contains("NOTIFICATIONS=0")
        return migrated
    }

    private func parseLegacyArray(_ text: String, name: String) -> [String] {
        guard let range = text.range(of: name + "=(") else { return [] }
        let tail = text[range.upperBound...]
        guard let end = tail.firstIndex(of: ")") else { return [] }
        return tail[..<end].components(separatedBy: .newlines).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
    }

    private func saveConfig() {
        do {
            try fileManager.createDirectory(at: applicationSupportDirectory,
                                            withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: configURL, options: .atomic)
        } catch {
            lastStatus = "Could not save settings: \(error.localizedDescription)"
        }
    }

    private func measureHealth() -> LinkHealth {
        let result = run("/sbin/ping", ["-q", "-c", "3", "1.1.1.1"])
        let loss = firstNumber(in: result.output, pattern: #"([0-9.]+)% packet loss"#) ?? 100
        let average: Double?
        if let equals = result.output.range(of: "=", options: .backwards) {
            let values = result.output[equals.upperBound...]
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: "/")
            average = values.count >= 2 ? Double(values[1]) : nil
        } else {
            average = nil
        }
        return LinkHealth(reachable: result.status == 0 && loss < 100 && average != nil,
                          packetLoss: loss,
                          averageLatency: average)
    }

    private func firstNumber(in text: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }

    private func connect(to ssid: String) -> Bool {
        let result = run("/usr/sbin/networksetup", ["-setairportnetwork", wifiDevice, ssid])
        guard result.status == 0 else {
            appendLog("Connect failed for \(ssid): \(result.output)")
            return false
        }
        let deadline = Date().addingTimeInterval(connectTimeout)
        while Date() < deadline {
            if currentSSID() == ssid { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func startCheck(reason: CheckReason) {
        guard !isChecking else { return }
        let authorization = locationManager.authorizationStatus
        guard authorization == .authorized || authorization == .authorizedAlways else {
            if reason == .manual { requestLocationAccessFromUser() }
            lastStatus = "Allow Location access to scan nearby Wi-Fi"
            rebuildMenu()
            return
        }

        refreshSavedNetworks()
        let saved = cachedSavedSSIDs
        let snapshot = config
        isChecking = true
        lastStatus = "Checking nearby networks…"
        rebuildMenu()

        checkQueue.async { [weak self] in
            guard let self else { return }
            let outcome = self.performCheck(reason: reason, config: snapshot, savedSSIDs: saved)
            DispatchQueue.main.async {
                self.isChecking = false
                self.lastStatus = outcome.message
                self.cachedVisibleNetworks = outcome.visibleNetworks
                if let from = outcome.switchedFrom, let to = outcome.switchedTo {
                    self.sendSwitchNotification(from: from, to: to)
                }
                self.rebuildMenu()
            }
        }
    }

    private func refreshNearbyNetworks() {
        guard !isChecking else { return }
        let authorization = locationManager.authorizationStatus
        guard authorization == .authorized || authorization == .authorizedAlways else {
            lastStatus = "Allow Location access to scan nearby Wi-Fi"
            rebuildMenu()
            return
        }

        refreshSavedNetworks()
        let saved = cachedSavedSSIDs
        isChecking = true
        lastStatus = "Scanning nearby networks…"
        rebuildMenu()
        checkQueue.async { [weak self] in
            guard let self else { return }
            do {
                let visible = try self.scanVisibleSavedNetworks(savedSSIDs: Set(saved))
                self.appendLog("Passive scan found \(visible.count) visible saved/current networks")
                DispatchQueue.main.async {
                    self.cachedVisibleNetworks = visible
                    self.isChecking = false
                    self.lastStatus = "Nearby list refreshed (\(visible.count))"
                    self.rebuildMenu()
                }
            } catch {
                self.appendLog("Passive scan failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isChecking = false
                    self.lastStatus = "Wi-Fi scan failed: \(error.localizedDescription)"
                    self.rebuildMenu()
                }
            }
        }
    }

    private func performCheck(reason: CheckReason, config: Config, savedSSIDs: [String]) -> CheckOutcome {
        guard let originalSSID = currentSSID() else {
            return findAndConnectFromOffline(reason: reason, config: config, savedSSIDs: savedSSIDs)
        }

        let originalPriority = effectivePriority(for: originalSSID, config: config)
        let originalRSSI = currentRSSI() ?? -100
        let originalHealth = measureHealth()
        appendLog("Current=\(originalSSID) priority=\(originalPriority.rawValue) rssi=\(originalRSSI) health=\(originalHealth.summary)")

        // Scanning is passive: it refreshes RSSI/SSID data without leaving the
        // active network. We do it even when policy says the current network wins.
        let visible: [VisibleNetwork]
        do {
            visible = try scanVisibleSavedNetworks(savedSSIDs: Set(savedSSIDs))
            appendLog("Scan found \(visible.count) visible saved/current networks")
        } catch {
            appendLog("Scan failed: \(error.localizedDescription)")
            return CheckOutcome(message: "Wi-Fi scan failed: \(error.localizedDescription)",
                                visibleNetworks: [], switchedFrom: nil, switchedTo: nil)
        }

        if reason == .automatic && originalPriority == .high && originalHealth.healthy {
            resetPendingCandidate()
            return CheckOutcome(message: "Healthy High network; staying connected",
                                visibleNetworks: visible,
                                switchedFrom: nil, switchedTo: nil)
        }
        if reason == .automatic && originalPriority == .normal && originalHealth.healthy && !config.preferHigh {
            resetPendingCandidate()
            return CheckOutcome(message: "Current network is healthy",
                                visibleNetworks: visible,
                                switchedFrom: nil, switchedTo: nil)
        }

        let candidates = visible.filter { network in
            guard network.ssid != originalSSID, network.rssi >= minimumUsableRSSI else { return false }
            if reason == .automatic, rejectedUntil[network.ssid, default: .distantPast] > Date() {
                return false
            }
            let priority = effectivePriority(for: network.ssid, config: config)
            if originalHealth.healthy {
                if priority.rank > originalPriority.rank { return true }
                return reason == .manual && priority == originalPriority &&
                    network.rssi >= originalRSSI + sameTierRSSIGain
            }
            if priority.rank == originalPriority.rank {
                return network.rssi >= originalRSSI + sameTierRSSIGain
            }
            return priority.rank > originalPriority.rank || !originalHealth.reachable
        }.sorted { left, right in
            let leftPriority = effectivePriority(for: left.ssid, config: config)
            let rightPriority = effectivePriority(for: right.ssid, config: config)
            if leftPriority.rank != rightPriority.rank { return leftPriority.rank > rightPriority.rank }
            return left.rssi > right.rssi
        }

        guard let candidate = candidates.first else {
            resetPendingCandidate()
            return CheckOutcome(message: "No better visible saved network",
                                visibleNetworks: visible, switchedFrom: nil, switchedTo: nil)
        }

        let candidatePriority = effectivePriority(for: candidate.ssid, config: config)
        let isPriorityUpgrade = candidatePriority.rank > originalPriority.rank
        if reason == .automatic,
           !isPriorityUpgrade,
           originalHealth.reachable,
           !observeCandidate(candidate.ssid) {
            return CheckOutcome(message: "Watching \(candidate.ssid) before switching",
                                visibleNetworks: visible, switchedFrom: nil, switchedTo: nil)
        }
        if reason == .automatic,
           !isPriorityUpgrade,
           let lastSwitchDate,
           Date().timeIntervalSince(lastSwitchDate) < switchCooldown {
            return CheckOutcome(message: "Switch cooldown active",
                                visibleNetworks: visible, switchedFrom: nil, switchedTo: nil)
        }

        return attemptSwitch(from: originalSSID, to: candidate.ssid,
                             config: config, visibleNetworks: visible)
    }

    private func findAndConnectFromOffline(reason: CheckReason, config: Config,
                                           savedSSIDs: [String]) -> CheckOutcome {
        let visible: [VisibleNetwork]
        do {
            visible = try scanVisibleSavedNetworks(savedSSIDs: Set(savedSSIDs))
        } catch {
            return CheckOutcome(message: "Wi-Fi scan failed: \(error.localizedDescription)",
                                visibleNetworks: [], switchedFrom: nil, switchedTo: nil)
        }
        let candidates = visible.filter {
            $0.rssi >= minimumUsableRSSI &&
                (reason == .manual || rejectedUntil[$0.ssid, default: .distantPast] <= Date())
        }.sorted { left, right in
            let leftPriority = effectivePriority(for: left.ssid, config: config)
            let rightPriority = effectivePriority(for: right.ssid, config: config)
            if leftPriority.rank != rightPriority.rank { return leftPriority.rank > rightPriority.rank }
            return left.rssi > right.rssi
        }
        guard let candidate = candidates.first else {
            return CheckOutcome(message: "No usable visible saved network",
                                visibleNetworks: visible, switchedFrom: nil, switchedTo: nil)
        }
        return attemptSwitch(from: nil, to: candidate.ssid, config: config, visibleNetworks: visible)
    }

    private func attemptSwitch(from originalSSID: String?, to targetSSID: String,
                               config: Config, visibleNetworks: [VisibleNetwork]) -> CheckOutcome {
        appendLog("Trying target=\(targetSSID)")
        guard connect(to: targetSSID) else {
            rejectedUntil[targetSSID] = Date().addingTimeInterval(switchCooldown)
            if let originalSSID { _ = connect(to: originalSSID) }
            resetPendingCandidate()
            return CheckOutcome(message: "Could not connect to \(targetSSID)",
                                visibleNetworks: visibleNetworks, switchedFrom: nil, switchedTo: nil)
        }

        let targetHealth = measureHealth()
        guard targetHealth.healthy else {
            appendLog("Target=\(targetSSID) rejected: \(targetHealth.summary)")
            rejectedUntil[targetSSID] = Date().addingTimeInterval(switchCooldown)
            if let originalSSID { _ = connect(to: originalSSID) }
            resetPendingCandidate()
            return CheckOutcome(message: "Rejected \(targetSSID); restored previous network",
                                visibleNetworks: visibleNetworks, switchedFrom: nil, switchedTo: nil)
        }

        lastSwitchDate = Date()
        rejectedUntil.removeValue(forKey: targetSSID)
        resetPendingCandidate()
        appendLog("Switched from \(originalSSID ?? "offline") to \(targetSSID); \(targetHealth.summary)")
        return CheckOutcome(message: "Connected to \(targetSSID) (\(targetHealth.summary))",
                            visibleNetworks: visibleNetworks,
                            switchedFrom: originalSSID,
                            switchedTo: targetSSID)
    }

    private func observeCandidate(_ ssid: String) -> Bool {
        if pendingCandidate == ssid {
            pendingCandidateCount += 1
        } else {
            pendingCandidate = ssid
            pendingCandidateCount = 1
        }
        return pendingCandidateCount >= 2
    }

    private func resetPendingCandidate() {
        pendingCandidate = nil
        pendingCandidateCount = 0
    }

    private func appendLog(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = URL(fileURLWithPath: logPath)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        guard let data = line.data(using: .utf8) else { return }
        if !fileManager.fileExists(atPath: logPath) {
            fileManager.createFile(atPath: logPath, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { }
    }

    private func sendSwitchNotification(from: String, to: String) {
        guard config.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "Wi-Fi switched"
        content.body = "\(from) → \(to)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func makeNetworkMenuItem(ssid: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(ssid)  ·  \(priorityDisplay(for: ssid, config: config))",
                              action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for priority in [NetworkPriority.high, .normal, .low] {
            let choice = NSMenuItem(title: priority.title,
                                    action: #selector(setPriority(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = [ssid, priority.rawValue]
            choice.state = effectivePriority(for: ssid, config: config) == priority ? .on : .off
            submenu.addItem(choice)
        }
        if config.overrides[ssid] != nil {
            submenu.addItem(.separator())
            let automatic = NSMenuItem(title: "Use automatic default",
                                       action: #selector(clearPriorityOverride(_:)), keyEquivalent: "")
            automatic.target = self
            automatic.representedObject = ssid
            submenu.addItem(automatic)
        }
        item.submenu = submenu
        return item
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let current = currentSSID()
        let currentName = current ?? "Not connected"
        let currentItem = NSMenuItem(title: "Current: \(currentName)", action: nil, keyEquivalent: "")
        currentItem.isEnabled = false
        menu.addItem(currentItem)
        if let current {
            let priority = NSMenuItem(title: "Priority: \(priorityDisplay(for: current, config: config))",
                                      action: nil, keyEquivalent: "")
            priority.isEnabled = false
            menu.addItem(priority)
        }
        let status = NSMenuItem(title: isChecking ? "Status: Checking…" : "Status: \(lastStatus)",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let find = NSMenuItem(title: "Find better Wi-Fi now",
                              action: #selector(findBetter), keyEquivalent: "")
        find.target = self
        find.isEnabled = !isChecking
        menu.addItem(find)
        let refresh = NSMenuItem(title: "Refresh nearby networks",
                                 action: #selector(refreshNearby), keyEquivalent: "")
        refresh.target = self
        refresh.isEnabled = !isChecking
        menu.addItem(refresh)
        menu.addItem(.separator())

        var visibleSaved = cachedVisibleNetworks
        if let current, !visibleSaved.contains(where: { $0.ssid == current }) {
            visibleSaved.insert(VisibleNetwork(ssid: current, rssi: currentRSSI() ?? -100), at: 0)
        }
        let nearbyTitle = NSMenuItem(title: "Nearby Known Wi-Fi (\(visibleSaved.count))",
                                     action: nil, keyEquivalent: "")
        nearbyTitle.isEnabled = false
        menu.addItem(nearbyTitle)
        if visibleSaved.isEmpty {
            let empty = NSMenuItem(title: "No nearby saved networks yet",
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for network in visibleSaved {
                let item = makeNetworkMenuItem(ssid: network.ssid)
                if network.ssid == current { item.title = "✓ " + item.title }
                if network.rssi > -100 { item.title += "  (\(network.rssi) dBm)" }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()

        let hotspot = NSMenuItem(title: "Auto-low iPhone hotspots",
                                 action: #selector(toggleHotspot), keyEquivalent: "")
        hotspot.target = self
        hotspot.state = config.autoHotspotLow ? .on : .off
        settingsMenu.addItem(hotspot)
        let prefer = NSMenuItem(title: "Actively prefer High networks",
                                action: #selector(togglePreferHigh), keyEquivalent: "")
        prefer.target = self
        prefer.state = config.preferHigh ? .on : .off
        settingsMenu.addItem(prefer)
        let notices = NSMenuItem(title: "Switch notifications",
                                 action: #selector(toggleNotifications), keyEquivalent: "")
        notices.target = self
        notices.state = config.notifications ? .on : .off
        settingsMenu.addItem(notices)

        if locationManager.authorizationStatus == .denied ||
            locationManager.authorizationStatus == .restricted {
            let locationSettings = NSMenuItem(title: "Open Location Settings…",
                                              action: #selector(openLocationSettings), keyEquivalent: "")
            locationSettings.target = self
            settingsMenu.addItem(locationSettings)
        } else if locationManager.authorizationStatus == .notDetermined {
            let enableScanning = NSMenuItem(title: "Enable nearby Wi-Fi scanning…",
                                            action: #selector(requestLocationAccessFromUser),
                                            keyEquivalent: "")
            enableScanning.target = self
            settingsMenu.addItem(enableScanning)
        }

        settingsMenu.addItem(.separator())
        let saved = NSMenuItem(title: "All Saved Networks (\(cachedSavedSSIDs.count))",
                               action: nil, keyEquivalent: "")
        let savedMenu = NSMenu()
        for ssid in cachedSavedSSIDs {
            savedMenu.addItem(makeNetworkMenuItem(ssid: ssid))
        }
        saved.submenu = savedMenu
        settingsMenu.addItem(saved)

        let logs = NSMenuItem(title: "Open log", action: #selector(openLog), keyEquivalent: "")
        logs.target = self
        settingsMenu.addItem(logs)
        settings.submenu = settingsMenu
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Wi-Fi Picker", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.toolTip = "Wi-Fi Picker — \(currentName)"
    }

    @objc private func setPriority(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String], values.count == 2,
              let priority = NetworkPriority(rawValue: values[1]) else { return }
        config.overrides[values[0]] = priority
        saveConfig()
        rebuildMenu()
    }

    @objc private func clearPriorityOverride(_ sender: NSMenuItem) {
        guard let ssid = sender.representedObject as? String else { return }
        config.overrides.removeValue(forKey: ssid)
        saveConfig()
        rebuildMenu()
    }

    @objc private func findBetter() { startCheck(reason: .manual) }

    @objc private func refreshNearby() {
        if locationManager.authorizationStatus == .notDetermined {
            requestLocationAccessFromUser()
        } else {
            refreshNearbyNetworks()
        }
    }

    @objc private func requestLocationAccessFromUser() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        locationManager.requestWhenInUseAuthorization()
    }

    @objc private func toggleHotspot() {
        config.autoHotspotLow.toggle()
        saveConfig()
        rebuildMenu()
    }

    @objc private func togglePreferHigh() {
        config.preferHigh.toggle()
        saveConfig()
        rebuildMenu()
    }

    @objc private func toggleNotifications() {
        config.notifications.toggle()
        saveConfig()
        if config.notifications { requestNotificationAccessIfNeeded() }
        rebuildMenu()
    }

    @objc private func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openLog() {
        if !fileManager.fileExists(atPath: logPath) {
            fileManager.createFile(atPath: logPath, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
