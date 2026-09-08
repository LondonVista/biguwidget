import Cocoa
import SwiftUI
import WebKit

// MARK: - Public links (edit before you ship)

enum BigUwidgetConfig {
    /// Ko-fi / GitHub Sponsors / PayPal. Donate is hidden if this is nil.
    static let donateURL = URL(string: "https://ko-fi.com/london_vista")
    static let appVersion = "1.0.4"
    static let updateFeedURL = URL(string: "https://github.com/LondonVista/biguwidget/releases/latest/download/latest.json")
    static let githubReleasesURL = URL(string: "https://github.com/LondonVista/biguwidget/releases/latest")
    static let githubAPIURL = URL(string: "https://api.github.com/repos/LondonVista/biguwidget/releases/latest")
}

enum UpdatePolicy: String, CaseIterable {
    case off
    case prompt
    case auto
}

private func biguVersionCompare(_ a: String, _ b: String) -> ComparisonResult {
    let pa = a.split(separator: ".").compactMap { Int($0) }
    let pb = b.split(separator: ".").compactMap { Int($0) }
    let n = max(pa.count, pb.count)
    for i in 0..<n {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x > y { return .orderedDescending }
        if x < y { return .orderedAscending }
    }
    return .orderedSame
}

final class UpdateChecker {
    static let shared = UpdateChecker()
    private init() {}
    private var checking = false
    private var promptedFor: String?

    func checkSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.checkNow()
        }
    }

    func checkNow() {
        let policy = UpdatePolicy(rawValue: UserDefaults.standard.string(forKey: "bigu.settings.updatePolicy") ?? "prompt") ?? .prompt
        guard policy != .off else { return }
        guard !checking else { return }
        checking = true
        Task.detached { [weak self] in
            let info = await Self.fetchLatest()
            await MainActor.run {
                self?.checking = false
                guard let info else { return }
                let current = BigUwidgetConfig.appVersion
                guard biguVersionCompare(info.version, current) == .orderedDescending else { return }
                if policy == .auto {
                    self?.install(info)
                } else {
                    self?.prompt(info)
                }
            }
        }
    }

    private struct LatestInfo {
        let version: String
        let notes: String
        let url: URL
    }

    private static func fetchLatest() async -> LatestInfo? {
        if let feed = BigUwidgetConfig.updateFeedURL, let info = await parseFeed(feed) { return info }
        if let api = BigUwidgetConfig.githubAPIURL, let info = await parseGitHubAPI(api) { return info }
        return nil
    }

    private static func parseFeed(_ url: URL) async -> LatestInfo? {
        var req = URLRequest(url: url)
        req.setValue("BigUwidget/\(BigUwidgetConfig.appVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, res) = try? await URLSession.shared.data(for: req),
              let http = res as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let ver = (obj["version"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "v")) ?? ""
        guard !ver.isEmpty else { return nil }
        let notes = obj["notes"] as? String ?? ""
        let downloads = obj["downloads"] as? [String: String]
        let link = downloads?["darwin"] ?? (obj["url"] as? String) ?? BigUwidgetConfig.githubReleasesURL?.absoluteString
        guard let link, let dest = URL(string: link) else { return nil }
        return LatestInfo(version: ver, notes: notes, url: dest)
    }

    private static func parseGitHubAPI(_ url: URL) async -> LatestInfo? {
        var req = URLRequest(url: url)
        req.setValue("BigUwidget/\(BigUwidgetConfig.appVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, res) = try? await URLSession.shared.data(for: req),
              let http = res as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tag = ((obj["tag_name"] as? String) ?? "").replacingOccurrences(of: "v", with: "")
        guard !tag.isEmpty else { return nil }
        let notes = obj["body"] as? String ?? ""
        var dest = BigUwidgetConfig.githubReleasesURL
        if let assets = obj["assets"] as? [[String: Any]] {
            let mac = assets.first { (($0["name"] as? String) ?? "").lowercased().contains("mac") }
                ?? assets.first { (($0["name"] as? String) ?? "").lowercased().contains("darwin") }
            if let s = mac?["browser_download_url"] as? String { dest = URL(string: s) }
        }
        if dest == nil, let html = obj["html_url"] as? String { dest = URL(string: html) }
        guard let dest else { return nil }
        return LatestInfo(version: tag, notes: notes, url: dest)
    }

    private func prompt(_ info: LatestInfo) {
        if promptedFor == info.version { return }
        promptedFor = info.version
        let alert = NSAlert()
        alert.messageText = "BigUwidget \(info.version) is available"
        alert.informativeText = info.notes.isEmpty
            ? "You have \(BigUwidgetConfig.appVersion). Install the new version?"
            : info.notes
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            install(info)
        }
    }

    private func install(_ info: LatestInfo) {
        Task {
            do {
                try await Self.applyInPlaceUpdate(from: info)
            } catch {
                await MainActor.run {
                    let fail = NSAlert()
                    fail.messageText = "Could not install automatically"
                    fail.informativeText = error.localizedDescription + "\n\nThe download page will open so you can install manually."
                    fail.runModal()
                    NSWorkspace.shared.open(info.url)
                }
            }
        }
    }

    private static func shQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func findApp(in dir: URL) -> URL? {
        let it = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let u = it?.nextObject() as? URL {
            if u.pathExtension == "app", u.lastPathComponent == "BigUwidget.app" {
                return u
            }
        }
        return nil
    }

    private static func applyInPlaceUpdate(from info: LatestInfo) async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("bigu-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zipURL = tmp.appendingPathComponent("update.zip")
        let (downloaded, _) = try await URLSession.shared.download(from: info.url)
        if fm.fileExists(atPath: zipURL.path) { try fm.removeItem(at: zipURL) }
        try fm.moveItem(at: downloaded, to: zipURL)

        let unzipDir = tmp.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-xk", zipURL.path, unzipDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw NSError(domain: "BigUwidget", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not unzip the update."])
        }
        guard let newApp = findApp(in: unzipDir) else {
            throw NSError(domain: "BigUwidget", code: 2, userInfo: [NSLocalizedDescriptionKey: "The zip did not contain BigUwidget.app."])
        }

        let dest = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let srcQ = shQuote(newApp.path)
        let destQ = shQuote(dest.path)
        let tmpQ = shQuote(tmp.path)
        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.25; done
        sleep 0.4
        /usr/bin/xattr -dr com.apple.quarantine \(srcQ) 2>/dev/null || true
        rm -rf \(destQ)
        /usr/bin/ditto \(srcQ) \(destQ)
        open \(destQ)
        rm -rf \(tmpQ)
        """
        let sh = tmp.appendingPathComponent("install.sh")
        try script.write(to: sh, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh.path)

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [sh.path]
        try helper.run()

        await MainActor.run {
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Data Models

struct DayUse: Identifiable, Equatable {
    let key: String
    let label: String
    let percent: Double
    var accumulatedGain: Double = 0   // > 0 means an intra-week reset happened on this day
    var id: String { key }
}

struct RecentDeltaItem: Identifiable, Equatable {
    let delta: Double
    let timestamp: Double
    var id: Double { timestamp }
}

struct SessionDeltaRecord: Identifiable, Equatable {
    var id: Double { timestamp }
    let timestamp: Double
    let dateStr: String
    let weeklyDelta: Double
    let weeklyTotal: Double
    let fiveHourPercent: Double?
}

struct QuotaResetRecord: Identifiable, Codable, Equatable {
    var id: String { "\(dateStr)_\(type)" }
    let timestamp: Double
    let dateStr: String
    let displayTitle: String
    let gainedPercent: Double
    let type: String // "manual", "intraweek", "scheduled"
    let note: String?
}

struct UsageSlice: Identifiable, Equatable {
    let name: String
    let percent: Double
    let color: Color
    var id: String { name }
}

struct UsageSnapshot: Equatable {
    var totalPercent: Double
    var resetsAt: Date?
    var resetsLabel: String
    var slices: [UsageSlice]
    var daily: [DayUse]
    var yesterdayUsed: Double?
    var fiveHourPercent: Double?
    var fiveHourResetsAt: Date?
    var fiveHourResetsLabel: String?
    var planLabel: String
    var fetchedAt: Date
    var recentDeltas: [RecentDeltaItem] = []

    static func == (lhs: UsageSnapshot, rhs: UsageSnapshot) -> Bool {
        lhs.totalPercent == rhs.totalPercent &&
        lhs.resetsAt == rhs.resetsAt &&
        lhs.resetsLabel == rhs.resetsLabel &&
        lhs.slices == rhs.slices &&
        lhs.daily == rhs.daily &&
        lhs.yesterdayUsed == rhs.yesterdayUsed &&
        lhs.fiveHourPercent == rhs.fiveHourPercent &&
        lhs.fiveHourResetsAt == rhs.fiveHourResetsAt &&
        lhs.fiveHourResetsLabel == rhs.fiveHourResetsLabel &&
        lhs.planLabel == rhs.planLabel &&
        lhs.recentDeltas == rhs.recentDeltas
    }
}

enum WidgetState: Equatable {
    case loading
    case ready(UsageSnapshot)
    case error(String)
    case needsLogin
}

enum FetchOutcome: Equatable {
    case success
    case needsLogin
    case failed(String)
}

enum ServiceKind: String, CaseIterable, Identifiable {
    case grok = "Grok"
    case grokBot = "Grok Bot"
    case agy = "AGY"
    case claudeGPT = "Claude & GPT"
    case chatGPT = "ChatGPT"
    var id: String { rawValue }

    var cacheDirName: String {
        switch self {
        case .grok: return "GrokUsageWidget"
        case .grokBot: return "GrokBotUsageWidget"
        case .agy: return "AGYusageWidget"
        case .claudeGPT: return "ClaudeGPTUsageWidget"
        case .chatGPT: return "ChatGPTUsageWidget"
        }
    }

    var collapseKey: String {
        switch self {
        case .claudeGPT: return "combined.collapsed.claudeGPT"
        case .chatGPT: return "combined.collapsed.chatGPT"
        default: return "combined.collapsed.\(rawValue)"
        }
    }

    var hideWeekStripKey: String {
        switch self {
        case .claudeGPT: return "bigu.hideWeekStrip.ClaudeGPT"
        case .chatGPT: return "bigu.hideWeekStrip.ChatGPT"
        default: return "bigu.hideWeekStrip.\(rawValue)"
        }
    }

    var showsFiveHour: Bool {
        self == .agy || self == .claudeGPT || self == .chatGPT
    }

    var loginURL: URL {
        switch self {
        case .grok: return URL(string: "https://grok.com")!
        case .grokBot: return URL(string: "https://cursor.com/login")!
        case .agy, .claudeGPT: return URL(string: "https://antigravity.google")!
        case .chatGPT: return URL(string: "https://chatgpt.com")!
        }
    }

    var displayName: String {
        switch self {
        case .claudeGPT: return "Claude & GPT (from AGY)"
        default: return rawValue
        }
    }

    var loginTitle: String {
        switch self {
        case .claudeGPT: return "Claude & GPT (from AGY)"
        default: return rawValue
        }
    }

    var loginHint: String {
        switch self {
        case .grok:
            return "Log in to grok.com below. When you see your Grok home page, click I’m signed in."
        case .grokBot:
            return "Log in to Cursor below. When your dashboard loads, click I’m signed in."
        case .agy, .claudeGPT:
            return "Log in with the Google account you use for Antigravity. If the Antigravity app is installed, BigUwidget can also read its token. You can paste an access token instead."
        case .chatGPT:
            return "Log in to chatgpt.com below. When you see the chat home page, click I’m signed in. This uses ChatGPT’s unofficial usage feed (5-hour + weekly)."
        }
    }
}

// MARK: - Palette & Parsers

enum ProductPalette {
    static func color(for name: String, index: Int) -> Color {
        let n = name.lowercased()
        if n.contains("gemini") { return Color(hex: 0x4285F4) }
        if n.contains("claude") { return Color(hex: 0xF28B82) }
        if n.contains("gpt") { return Color(hex: 0x34A853) }
        if n.contains("premium") || n.contains("chat") { return Color(hex: 0x32D74B) }
        let fallback = [Color(hex: 0x4285F4), Color(hex: 0xF28B82), Color(hex: 0xFBBC04), Color(hex: 0x34A853)]
        return fallback[index % fallback.count]
    }
}

enum UsageParser {
    static func formatSoft(_ value: Double) -> String {
        let clamped = max(0, value)
        if clamped.rounded() == clamped {
            return "\(Int(clamped))%"
        }
        return String(format: "%.1f%%", clamped)
    }

    static func formatOverrun(_ value: Double) -> String {
        let clamped = max(0, value)
        if clamped.rounded() == clamped {
            return "+\(Int(clamped))%"
        }
        return String(format: "+%.1f%%", clamped)
    }

    static func deltaAgeLabel(_ ts: Double, now: Date = Date()) -> String {
        guard ts > 0 else { return "" }
        let sec = max(0, Int(now.timeIntervalSince1970 - ts))
        if sec < 15 { return "now" }
        if sec < 60 { return "\(sec)s" }
        let min = sec / 60
        if min < 60 { return "\(min)m" }
        let hr = min / 60
        if hr < 24 { return "\(hr)h" }
        let days = hr / 24
        return "\(days)d"
    }

    static func remainingParts(until date: Date, now: Date = Date()) -> (days: String?, rest: String) {
        let totalMinutes = max(0, Int(date.timeIntervalSince(now) / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return ("\(days)d", "\(hours)h \(minutes)m")
        }
        if hours > 0 {
            return (nil, "\(hours)h \(minutes)m")
        }
        return (nil, "\(minutes)m")
    }

    static func resetCountdownColor(until date: Date, now: Date = Date()) -> Color {
        let hours = date.timeIntervalSince(now) / 3600
        if hours <= 24 { return Color(hex: 0xFF453A) }
        if hours <= 48 { return Color(hex: 0xFF9F0A) }
        return Color(hex: 0xFFD60A)
    }

    static func fiveHourCountdownColor(until date: Date, now: Date = Date()) -> Color {
        let minutes = date.timeIntervalSince(now) / 60
        if minutes <= 30 { return Color(hex: 0xFF453A) }
        if minutes <= 90 { return Color(hex: 0xFF9F0A) }
        return Color(hex: 0x32D74B)
    }

    static func formatReset(_ date: Date?) -> String {
        guard let date else { return "Reset time unknown" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d 'at' h:mm a"
        return "Resets \(f.string(from: date))"
    }

    static func formatResetOn(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE MMM d 'at' h:mm a"
        return "on \(f.string(from: date))"
    }

    static func lastRefreshed(_ date: Date, now: Date = Date()) -> String {
        let sec = max(0, Int(now.timeIntervalSince(date)))
        if sec < 5 { return "Refreshed just now" }
        if sec < 60 { return "Refreshed \(sec)s ago" }
        let min = sec / 60
        if min < 60 { return "Refreshed \(min)m ago" }
        return "Refreshed \(min / 60)h ago"
    }

    static func isResetWeekday(_ key: String, reset: Date?) -> Bool {
        guard let reset else { return false }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let day = f.date(from: key) else { return false }
        return Calendar.current.component(.weekday, from: day)
            == Calendar.current.component(.weekday, from: reset)
    }

    static let evenDailyShare = 100.0 / 7.0

    struct DailyBudgetStatus {
        let todayLeft: Double
        let paceOverrun: Double
        let todayOverrun: Double
    }

    static func calculateDailyStatus(
        totalPercent: Double,
        todayUsed: Double,
        resetsAt: Date?,
        now: Date = Date()
    ) -> DailyBudgetStatus {
        let effectiveTodayUsed = max(0, todayUsed)
        // Remaining weekly pool at the start of today (before today's use).
        let remainingAtOpen = max(0, 100.0 - max(0, totalPercent - effectiveTodayUsed))
        let poolRemainingNow = max(0, 100.0 - totalPercent)

        guard let reset = resetsAt else {
            let budget = min(remainingAtOpen, evenDailyShare)
            let left = min(max(0, budget - effectiveTodayUsed), poolRemainingNow)
            let overrun = max(0, effectiveTodayUsed - budget)
            return DailyBudgetStatus(todayLeft: left, paceOverrun: 0, todayOverrun: overrun)
        }

        let startOfToday = Calendar.current.startOfDay(for: now)
        let secondsFromMorning = max(0, reset.timeIntervalSince(startOfToday))
        let daysFromMorning = max(0.05, secondsFromMorning / 86400.0)
        let secondsLeft = max(0, reset.timeIntervalSince(now))

        let todayBudget: Double = {
            if daysFromMorning <= 1.0 {
                return remainingAtOpen
            }
            return remainingAtOpen / daysFromMorning
        }()

        let todayLeft = min(max(0, todayBudget - effectiveTodayUsed), poolRemainingNow)
        let todayOverrun = max(0, effectiveTodayUsed - todayBudget)

        let totalPeriodSeconds: Double = 7.0 * 24.0 * 3600.0
        let fractionRemaining = min(1.0, secondsLeft / totalPeriodSeconds)
        let expectedRemaining = fractionRemaining * 100.0
        let paceOverrun = max(0, expectedRemaining - poolRemainingNow)

        return DailyBudgetStatus(
            todayLeft: todayLeft,
            paceOverrun: paceOverrun,
            todayOverrun: todayOverrun
        )
    }

    static let claudeGPTModels = ["Claude 3.7 Sonnet", "Claude 3.5 Sonnet", "Claude 3 Opus", "GPT-OSS 120B"]
}

enum PctFmt {
    static func day(_ p: Double) -> String {
        if p <= 0.05 { return "·" }
        if abs(p - p.rounded()) < 0.05 { return "\(Int(p.rounded()))" }
        return String(format: "%.1f", p)
    }
    static func total(_ p: Double) -> String {
        if p <= 0.05 { return "0%" }
        if abs(p - p.rounded()) < 0.05 { return "\(Int(p.rounded()))%" }
        return String(format: "%.1f%%", p)
    }
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xff) / 255.0
        let g = Double((hex >> 8) & 0xff) / 255.0
        let b = Double(hex & 0xff) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

private struct NativeSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        if n.width > 0 || n.height > 0 { value = n }
    }
}

/// Scales a card and reserves layout space so AutoFit windows grow/shrink with it.
struct LayoutScale<Content: View>: View {
    var scale: CGFloat
    @ViewBuilder var content: Content
    @State private var native: CGSize = CGSize(width: 206, height: 120)

    var body: some View {
        let s = min(2, max(0.5, scale))
        content
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: NativeSizeKey.self, value: g.size)
                }
            )
            .onPreferenceChange(NativeSizeKey.self) { native = $0 }
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: max(1, native.width * s), height: max(1, native.height * s), alignment: .topLeading)
    }
}

// MARK: - Sub-Store for a Single Service

final class SingleServiceStore: ObservableObject {
    let service: ServiceKind
    let cacheDirName: String

    @Published var state: WidgetState = .loading
    @Published var dailyMap: [String: [String: Double]] = [:]
    @Published var isCollapsed: Bool
    @Published var fetchWarning: String? = nil

    private var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(cacheDirName, isDirectory: true)
    }

    private var cacheURL: URL { directoryURL.appendingPathComponent("last-usage.json") }
    private var dailyURL: URL { directoryURL.appendingPathComponent("daily-usage.json") }
    private var deltasURL: URL { directoryURL.appendingPathComponent("session-deltas.json") }

    private let collapseKey: String

    init(service: ServiceKind, cacheDirName: String) {
        self.service = service
        self.cacheDirName = cacheDirName
        self.collapseKey = service.collapseKey
        self.isCollapsed = UserDefaults.standard.bool(forKey: collapseKey)
        reloadFromDisk()
    }

    func toggleCollapse() {
        isCollapsed.toggle()
        UserDefaults.standard.set(isCollapsed, forKey: collapseKey)
    }

    private var geminiDeltasURL: URL { directoryURL.appendingPathComponent("gemini-deltas.json") }
    private var geminiSessionDeltasURL: URL { directoryURL.appendingPathComponent("gemini-session-deltas.json") }

    func reloadFromDisk() {
        sessionCacheValid = false
        let newMap = loadDailyMap()
        if newMap != dailyMap {
            dailyMap = newMap
        }
        guard let snap = loadCached() else { return }
        applyReady(snap)
    }

    func applyFetchOutcome(_ outcome: FetchOutcome) {
        switch outcome {
        case .success:
            fetchWarning = nil
            sessionCacheValid = false
            reloadFromDisk()
        case .needsLogin:
            if case .ready = state {
                fetchWarning = "offline"
                reloadFromDisk()
            } else {
                fetchWarning = "offline"
                withAnimation(.easeInOut(duration: 0.2)) {
                    state = .needsLogin
                }
            }
        case .failed(let msg):
            if case .ready = state {
                fetchWarning = msg
                reloadFromDisk()
            } else {
                fetchWarning = nil
                withAnimation(.easeInOut(duration: 0.2)) {
                    state = .error(msg)
                }
            }
        }
    }

    /// Animate only when usage data changes. Timestamp-only refresh stays silent.
    private func applyReady(_ snap: UsageSnapshot) {
        let newState = WidgetState.ready(snap)
        switch state {
        case .ready(let old):
            if old != snap {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                    state = newState
                }
            } else if old.fetchedAt != snap.fetchedAt {
                state = newState
            }
        default:
            if state != newState {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                    state = newState
                }
            }
        }
    }

    private static func jsonDouble(_ item: [String: Any], _ key: String) -> Double? {
        if let n = item[key] as? NSNumber { return n.doubleValue }
        if let d = item[key] as? Double { return d }
        if let i = item[key] as? Int { return Double(i) }
        if let s = item[key] as? String { return Double(s) }
        return nil
    }

    private func loadSessionRecords(from url: URL) -> [SessionDeltaRecord] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { item -> SessionDeltaRecord? in
            let ts = Self.jsonDouble(item, "timestamp")
            let delta = Self.jsonDouble(item, "weeklyDelta") ?? Self.jsonDouble(item, "delta")
            guard let ts, let delta else { return nil }
            let total = Self.jsonDouble(item, "weeklyTotal") ?? 0
            let dStr = item["date"] as? String ?? ""
            let five = Self.jsonDouble(item, "fiveHourPercent")
            return SessionDeltaRecord(timestamp: ts, dateStr: dStr, weeklyDelta: delta, weeklyTotal: total, fiveHourPercent: five)
        }
    }

    private func loadGeminiDeltas() -> [RecentDeltaItem] {
        guard let data = try? Data(contentsOf: geminiDeltasURL),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Double]] else { return [] }
        return Array(list.compactMap { d -> RecentDeltaItem? in
            guard let delta = d["delta"], let ts = d["timestamp"], abs(delta) < 30.0, abs(delta) > 0.005 else { return nil }
            return RecentDeltaItem(delta: delta, timestamp: ts)
        }.prefix(4))
    }

    private func loadLegacyClaudeDeltas() -> [RecentDeltaItem] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = appSupport.appendingPathComponent("AGYusageWidget/claude-deltas.json")
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Double]] else { return [] }
        return Array(list.compactMap { d -> RecentDeltaItem? in
            guard let delta = d["delta"], let ts = d["timestamp"], abs(delta) < 30.0, delta > 0.005 else { return nil }
            return RecentDeltaItem(delta: delta, timestamp: ts)
        }.prefix(4))
    }

    func usedPercent(on key: String) -> Double {
        let e = dailyMap[key] ?? [:]
        guard let open = e["open"], var close = e["close"] else { return 0.0 }

        let cal = Calendar.current
        let now = Date()
        let todayKey = String(format: "%04d-%02d-%02d",
            cal.component(.year, from: now),
            cal.component(.month, from: now),
            cal.component(.day, from: now))
        if key == todayKey, case .ready(let snap) = state {
            close = snap.totalPercent
        }

        let resetsAt: Date? = {
            if case .ready(let snap) = state { return snap.resetsAt }
            return nil
        }()
        let bonus = effectiveAccumulated(on: key, resetsAt: resetsAt)

        // Midnight artifact: open stamped 0 before the weekly reset. Do not borrow
        // yesterday's close when this day is a real intra-week reset to ~0.
        var effectiveOpen = open
        if effectiveOpen == 0 && bonus < 0.5 {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd"
            if let d = fmt.date(from: key),
               let prevD = Calendar.current.date(byAdding: .day, value: -1, to: d) {
                let prevKey = fmt.string(from: prevD)
                if let prevEntry = dailyMap[prevKey], let prevClose = prevEntry["close"], prevClose > 0 {
                    effectiveOpen = prevClose
                }
            }
        }

        return max(0, close - effectiveOpen)
    }

    /// Intra-week extra pool only. Scheduled weekly reset and the old
    /// "copy yesterday's close as gain" bug are not bonus quota.
    func effectiveAccumulated(on key: String, resetsAt: Date?) -> Double {
        let entry = dailyMap[key] ?? [:]
        let acc = entry["accumulated"] ?? 0
        if acc < 0.5 { return 0 }
        if UsageParser.isResetWeekday(key, reset: resetsAt) { return 0 }

        let open = entry["open"] ?? 0
        let close = entry["close"] ?? 0
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        if let d = fmt.date(from: key),
           let prevD = Calendar.current.date(byAdding: .day, value: -1, to: d) {
            let prevKey = fmt.string(from: prevD)
            if let prevClose = dailyMap[prevKey]?["close"],
               abs(acc - prevClose) < 1.5, close > 10, open < 0.5 {
                return 0
            }
        }
        return acc
    }

    func sumUsed(from start: Date, to end: Date) -> Double {
        var total = 0.0
        var d = start
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        while d < end {
            total += usedPercent(on: fmt.string(from: d))
            d = cal.date(byAdding: .day, value: 1, to: d) ?? end
        }
        return total
    }

    func daysForDisplay(now: Date = Date(), resetsAt: Date? = nil) -> [DayUse] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today)
        let isoMondayOffset = (weekday + 5) % 7
        guard let monday = cal.date(byAdding: .day, value: -isoMondayOffset, to: today) else {
            return placeholderWeek()
        }

        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        let labels = ["M", "T", "W", "T", "F", "S", "S"]
        return (0..<7).compactMap { i -> DayUse? in
            guard let d = cal.date(byAdding: .day, value: i, to: monday) else { return nil }
            let key = fmt.string(from: d)
            let gain = effectiveAccumulated(on: key, resetsAt: resetsAt)
            return DayUse(key: key, label: labels[i], percent: usedPercent(on: key), accumulatedGain: gain)
        }
    }

    func currentWeekResetGain(now: Date = Date(), resetsAt: Date? = nil) -> Double {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today)
        let isoMondayOffset = (weekday + 5) % 7
        guard let monday = cal.date(byAdding: .day, value: -isoMondayOffset, to: today) else {
            return 0
        }

        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        var gain = 0.0
        for i in 0..<7 {
            if let d = cal.date(byAdding: .day, value: i, to: monday) {
                let key = fmt.string(from: d)
                gain += effectiveAccumulated(on: key, resetsAt: resetsAt)
            }
        }

        if gain < 0.1, let reset = resetsAt {
            let cycleStart = cal.date(byAdding: .day, value: -7, to: reset) ?? cal.date(byAdding: .day, value: -7, to: today)!
            var cur = cal.startOfDay(for: cycleStart)
            let endDay = cal.startOfDay(for: now)
            while cur <= endDay {
                let key = fmt.string(from: cur)
                gain += effectiveAccumulated(on: key, resetsAt: resetsAt)
                cur = cal.date(byAdding: .day, value: 1, to: cur) ?? endDay.addingTimeInterval(86400)
            }
        }

        return gain
    }

    // MARK: - Quota Reset History Persistence

    var resetHistoryURL: URL { directoryURL.appendingPathComponent("quota-resets.json") }

    func saveQuotaReset(_ rec: QuotaResetRecord) {
        var existing = loadQuotaResets()
        if let idx = existing.firstIndex(where: { $0.id == rec.id }) {
            existing[idx] = rec
        } else {
            existing.append(rec)
        }
        let list = existing.map { r -> [String: Any] in
            var dict: [String: Any] = [
                "timestamp": r.timestamp,
                "dateStr": r.dateStr,
                "displayTitle": r.displayTitle,
                "gainedPercent": r.gainedPercent,
                "type": r.type
            ]
            if let note = r.note { dict["note"] = note }
            return dict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) else { return }
        try? data.write(to: resetHistoryURL, options: .atomic)
    }

    func deleteQuotaReset(id: String) {
        var existing = loadQuotaResets()
        existing.removeAll(where: { $0.id == id })
        let list = existing.map { r -> [String: Any] in
            var dict: [String: Any] = [
                "timestamp": r.timestamp,
                "dateStr": r.dateStr,
                "displayTitle": r.displayTitle,
                "gainedPercent": r.gainedPercent,
                "type": r.type
            ]
            if let note = r.note { dict["note"] = note }
            return dict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) else { return }
        try? data.write(to: resetHistoryURL, options: .atomic)
    }

    func loadQuotaResets() -> [QuotaResetRecord] {
        var records: [QuotaResetRecord] = []
        if let data = try? Data(contentsOf: resetHistoryURL),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            records = list.compactMap { item -> QuotaResetRecord? in
                guard let ts = (item["timestamp"] as? NSNumber)?.doubleValue,
                      let dateStr = item["dateStr"] as? String,
                      let title = item["displayTitle"] as? String,
                      let gain = (item["gainedPercent"] as? NSNumber)?.doubleValue,
                      let type = item["type"] as? String else { return nil }
                let note = item["note"] as? String
                return QuotaResetRecord(timestamp: ts, dateStr: dateStr, displayTitle: title, gainedPercent: gain, type: type, note: note)
            }
        }
        // Auto-ingest any recorded accumulated gains from dailyMap
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        for (dayKey, entry) in dailyMap {
            if let acc = entry["accumulated"], acc > 0 {
                if !records.contains(where: { $0.dateStr == dayKey }) {
                    let ts = (fmt.date(from: dayKey)?.timeIntervalSince1970) ?? Date().timeIntervalSince1970
                    let autoRec = QuotaResetRecord(
                        timestamp: ts,
                        dateStr: dayKey,
                        displayTitle: "Intra-Week Reset",
                        gainedPercent: acc,
                        type: "intraweek",
                        note: "Google Antigravity manual reset detected (+ \(Int(acc.rounded()))% quota gained)"
                    )
                    records.append(autoRec)
                }
            }
        }
        records.sort { $0.timestamp > $1.timestamp }
        return records
    }

    private func placeholderWeek() -> [DayUse] {
        let letters = ["M", "T", "W", "T", "F", "S", "S"]
        return letters.enumerated().map { i, letter in
            DayUse(key: "\(i)", label: letter, percent: 0)
        }
    }

    private func loadCached() -> UsageSnapshot? {
        if let data = try? Data(contentsOf: cacheURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let snap = parseSnapshot(dict) {
            return snap
        }
        if service == .claudeGPT {
            return bootstrapClaudeFromAGYRaw()
        }
        return nil
    }

    private func loadDailyMap() -> [String: [String: Double]] {
        guard let data = try? Data(contentsOf: dailyURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return [:]
        }
        var out: [String: [String: Double]] = [:]
        for (k, v) in obj {
            out[k] = [
                "open": (v["open"] as? NSNumber)?.doubleValue ?? 0,
                "close": (v["close"] as? NSNumber)?.doubleValue ?? 0,
                "accumulated": (v["accumulated"] as? NSNumber)?.doubleValue ?? 0
            ]
        }
        return out
    }

    private var cachedSessionDeltas: [SessionDeltaRecord] = []
    private var sessionCacheValid = false
    private var sessionCacheStamp: (TimeInterval, TimeInterval) = (0, 0)

    private func fileStamp(_ url: URL) -> TimeInterval {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
    }

    func loadAllSessionDeltas() -> [SessionDeltaRecord] {
        let extraURL: URL = {
            if service == .agy { return geminiSessionDeltasURL }
            if service == .claudeGPT {
                return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("AGYusageWidget/claude-deltas.json")
            }
            return deltasURL
        }()
        let stamp = (fileStamp(deltasURL), fileStamp(extraURL))
        if sessionCacheValid && stamp == sessionCacheStamp {
            return cachedSessionDeltas
        }

        var records = loadSessionRecords(from: deltasURL)
        if service == .agy {
            for rec in loadSessionRecords(from: geminiSessionDeltasURL) {
                if !records.contains(where: { abs($0.timestamp - rec.timestamp) < 1.0 }) {
                    records.append(rec)
                }
            }
        }
        if service == .claudeGPT && records.isEmpty {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            for item in loadLegacyClaudeDeltas() {
                records.append(SessionDeltaRecord(
                    timestamp: item.timestamp,
                    dateStr: df.string(from: Date(timeIntervalSince1970: item.timestamp)),
                    weeklyDelta: item.delta,
                    weeklyTotal: 0,
                    fiveHourPercent: nil
                ))
            }
        }
        records.sort { $0.timestamp < $1.timestamp }
        cachedSessionDeltas = records.reversed()
        sessionCacheValid = true
        sessionCacheStamp = stamp
        return cachedSessionDeltas
    }

    private func loadRecentDeltasFromDisk() -> [RecentDeltaItem] {
        guard let data = try? Data(contentsOf: deltasURL),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let deltas = list.reversed().compactMap { item -> RecentDeltaItem? in
            guard let d = (item["weeklyDelta"] as? NSNumber)?.doubleValue, d > 0.005, abs(d) < 30.0 else { return nil }
            let ts = (item["timestamp"] as? NSNumber)?.doubleValue ?? 0
            return RecentDeltaItem(delta: d, timestamp: ts)
        }
        return Array(deltas.prefix(4))
    }

    private func parseSnapshot(_ d: [String: Any]) -> UsageSnapshot? {
        let rLabel = d["resetsLabel"] as? String ?? ""

        var slices: [UsageSlice] = []
        if let sl = d["slices"] as? [[String: Any]] {
            for (i, s) in sl.enumerated() {
                let name = s["name"] as? String ?? "Slice \(i+1)"
                let p = (s["percent"] as? NSNumber)?.doubleValue ?? 0.0
                slices.append(UsageSlice(name: name, percent: p, color: ProductPalette.color(for: name, index: i)))
            }
        }

        let fDate = (d["fetchedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        var fiveUsed = (d["fiveHourPercent"] as? NSNumber)?.doubleValue
        var fiveReset = (d["fiveHourResetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let fiveLabel = d["fiveHourResetsLabel"] as? String
        let plan = d["planLabel"] as? String ?? service.rawValue

        var total = (d["totalPercent"] as? NSNumber)?.doubleValue ?? 0.0
        var rDate = (d["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        if service == .agy, let gemini = quotaGroup(namedContains: "gemini") {
            applyQuotaGroup(gemini, total: &total, resetsAt: &rDate, fiveUsed: &fiveUsed, fiveReset: &fiveReset, slices: &slices, sliceName: "Gemini")
        }
        if service == .claudeGPT, slices.contains(where: { $0.name.contains("Claude") }) == false,
           let claude = quotaGroup(namedContains: "claude") ?? quotaGroup(namedContains: "gpt") {
            applyQuotaGroup(claude, total: &total, resetsAt: &rDate, fiveUsed: &fiveUsed, fiveReset: &fiveReset, slices: &slices, sliceName: "Claude & GPT")
        }

        var recentDeltas = loadRecentDeltasFromDisk()
        if recentDeltas.isEmpty && service == .agy {
            recentDeltas = loadGeminiDeltas()
        }
        if recentDeltas.isEmpty && service == .claudeGPT {
            recentDeltas = loadLegacyClaudeDeltas()
        }
        if recentDeltas.isEmpty, let rawDeltaList = d["recentDeltas"] as? [[String: Any]] {
            recentDeltas = rawDeltaList.compactMap { item in
                guard let delta = (item["delta"] as? NSNumber)?.doubleValue,
                      let ts = (item["timestamp"] as? NSNumber)?.doubleValue else { return nil }
                return RecentDeltaItem(delta: delta, timestamp: ts)
            }
        }

        return UsageSnapshot(
            totalPercent: total,
            resetsAt: rDate,
            resetsLabel: rLabel,
            slices: slices,
            daily: daysForDisplay(now: Date(), resetsAt: rDate),
            yesterdayUsed: nil,
            fiveHourPercent: fiveUsed,
            fiveHourResetsAt: fiveReset,
            fiveHourResetsLabel: fiveLabel,
            planLabel: plan,
            fetchedAt: fDate,
            recentDeltas: recentDeltas
        )
    }

    private func quotaGroup(namedContains needle: String) -> [String: Any]? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let rawURL = appSupport.appendingPathComponent("AGYusageWidget/last-raw.json")
        guard let rawData = try? Data(contentsOf: rawURL),
              let rawJson = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              let groups = rawJson["groups"] as? [[String: Any]] else { return nil }
        return groups.first(where: { ($0["displayName"] as? String ?? "").lowercased().contains(needle) })
    }

    private func applyQuotaGroup(
        _ group: [String: Any],
        total: inout Double,
        resetsAt: inout Date?,
        fiveUsed: inout Double?,
        fiveReset: inout Date?,
        slices: inout [UsageSlice],
        sliceName: String
    ) {
        let buckets = group["buckets"] as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        for b in buckets {
            let window = b["window"] as? String ?? ""
            let rem = (b["remainingFraction"] as? NSNumber)?.doubleValue ?? 1.0
            let used = max(0, min(100, (1.0 - rem) * 100.0))
            let rTime = b["resetTime"] as? String ?? ""
            let resetDate = iso.date(from: rTime) ?? isoFallback.date(from: rTime)
            if window == "weekly" {
                total = used
                if let rd = resetDate { resetsAt = rd }
                if let idx = slices.firstIndex(where: { $0.name.contains(sliceName) || $0.name.contains("Gemini") && sliceName.contains("Gemini") }) {
                    slices[idx] = UsageSlice(name: slices[idx].name, percent: used, color: slices[idx].color)
                } else if !slices.contains(where: { $0.name.contains(sliceName) }) {
                    slices.append(UsageSlice(name: sliceName, percent: used, color: ProductPalette.color(for: sliceName, index: 0)))
                }
            } else if window == "5h" {
                fiveUsed = used
                fiveReset = resetDate
            }
        }
    }

    private func bootstrapClaudeFromAGYRaw() -> UsageSnapshot? {
        guard let group = quotaGroup(namedContains: "claude") ?? quotaGroup(namedContains: "gpt") else { return nil }
        var total = 0.0
        var rDate: Date? = nil
        var fiveUsed: Double? = nil
        var fiveReset: Date? = nil
        var slices: [UsageSlice] = []
        applyQuotaGroup(group, total: &total, resetsAt: &rDate, fiveUsed: &fiveUsed, fiveReset: &fiveReset, slices: &slices, sliceName: "Claude & GPT")
        guard total > 0 || fiveUsed != nil else { return nil }
        return UsageSnapshot(
            totalPercent: total,
            resetsAt: rDate,
            resetsLabel: rDate != nil ? UsageParser.formatReset(rDate) : "Weekly Quota",
            slices: slices,
            daily: daysForDisplay(now: Date(), resetsAt: rDate),
            yesterdayUsed: nil,
            fiveHourPercent: fiveUsed,
            fiveHourResetsAt: fiveReset,
            fiveHourResetsLabel: fiveReset.map { UsageParser.formatResetOn($0) },
            planLabel: "Claude & GPT",
            fetchedAt: Date(),
            recentDeltas: loadLegacyClaudeDeltas()
        )
    }
}

// MARK: - Live Service Fetchers

enum KeychainTokenHelper {
    private static var cachedToken: String?
    private static let lock = NSLock()

    static func getStoredToken() -> String? {
        lock.lock()
        if let cachedToken, !cachedToken.isEmpty {
            let hit = cachedToken
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let fetched = readFromKeychain(), !fetched.isEmpty else { return nil }
        lock.lock()
        cachedToken = fetched
        lock.unlock()
        return fetched
    }

    static func invalidate() {
        lock.lock()
        cachedToken = nil
        lock.unlock()
    }

    static func saveAccessToken(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        invalidate()
        let payload: String
        if trimmed.hasPrefix("{") {
            payload = trimmed
        } else {
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            payload = "{\"access_token\":\"\(escaped)\"}"
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = [
            "add-generic-password", "-U",
            "-s", "gemini",
            "-a", "antigravity",
            "-w", payload
        ]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        if let token = readFromKeychain(), !token.isEmpty {
            lock.lock()
            cachedToken = token
            lock.unlock()
        }
    }

    private static func readFromKeychain() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty, var str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return nil
            }
            if str.hasPrefix("go-keyring-base64:") {
                let b64 = String(str.dropFirst("go-keyring-base64:".count))
                if let decodedData = Data(base64Encoded: b64),
                   let decoded = String(data: decodedData, encoding: .utf8) {
                    str = decoded
                }
            }
            guard let jsonData = str.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return nil
            }
            let tokenObj = (obj["token"] as? [String: Any]) ?? obj
            return tokenObj["access_token"] as? String
        } catch {
            return nil
        }
    }
}

enum LiveServiceFetcher {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    static func fetchEnabled(_ enabled: Set<WidgetCardID>, completion: @escaping ([ServiceKind: FetchOutcome]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var outcomes: [ServiceKind: FetchOutcome] = [:]

        func setOutcome(_ kind: ServiceKind, _ outcome: FetchOutcome) {
            lock.lock()
            outcomes[kind] = outcome
            lock.unlock()
        }

        let wantGoogle = enabled.contains(.agy) || enabled.contains(.claudeGPT)
        if wantGoogle {
            group.enter()
            fetchAGY { outcome in
                if enabled.contains(.agy) { setOutcome(.agy, outcome) }
                if enabled.contains(.claudeGPT) { setOutcome(.claudeGPT, outcome) }
                group.leave()
            }
        }

        if enabled.contains(.grok) {
            group.enter()
            fetchGrok { outcome in
                setOutcome(.grok, outcome)
                group.leave()
            }
        }

        if enabled.contains(.grokBot) {
            group.enter()
            fetchGrokBot { outcome in
                setOutcome(.grokBot, outcome)
                group.leave()
            }
        }

        if enabled.contains(.chatGPT) {
            group.enter()
            fetchChatGPT { outcome in
                setOutcome(.chatGPT, outcome)
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(outcomes)
        }
    }

    private static let agyEndpoints = [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    ]

    private static func collectCookies(domains: [String], completion: @escaping ([String: String]) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var dict = BinaryCookiesReader.getCookies(domains: domains)
            for c in cookies where domains.contains(where: { c.domain.contains($0) }) {
                dict[c.name] = c.value
            }
            completion(dict)
        }
    }

    static func fetchAGY(completion: ((FetchOutcome) -> Void)? = nil) {
        func cookiePath() {
            collectCookies(domains: ["antigravity.google", "google.com", "cloudcode"]) { dict in
                if dict.isEmpty {
                    completion?(.needsLogin)
                    return
                }
                let header = dict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
                fetchAGYWithCookies(cookieHeader: header, index: 0, completion: completion)
            }
        }

        if let token = KeychainTokenHelper.getStoredToken(), !token.isEmpty {
            fetchAGYWithToken(token: token, index: 0) { outcome in
                if outcome == .needsLogin {
                    cookiePath()
                } else {
                    completion?(outcome)
                }
            }
            return
        }
        cookiePath()
    }

    private static func agyFailOutcome(status: Int, error: Error?) -> FetchOutcome {
        if status == 401 || status == 403 { return .needsLogin }
        if error != nil { return .failed("Network error") }
        if status == 0 { return .failed("Couldn't refresh") }
        return .failed("Couldn't refresh (\(status))")
    }

    private static func fetchAGYWithToken(token: String, index: Int = 0, allowRetry: Bool = true, completion: ((FetchOutcome) -> Void)? = nil) {
        guard index < agyEndpoints.count, let url = URL(string: agyEndpoints[index]) else {
            completion?(.failed("Couldn't refresh"))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("Antigravity/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = Data("{}".utf8)

        session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let data = data, let str = String(data: data, encoding: .utf8) {
                    saveAGYRawData(str, rawData: data)
                    completion?(.success)
                    return
                }
                if status == 401 || status == 403 {
                    KeychainTokenHelper.invalidate()
                    if allowRetry, let fresh = KeychainTokenHelper.getStoredToken(), fresh != token, !fresh.isEmpty {
                        fetchAGYWithToken(token: fresh, index: 0, allowRetry: false, completion: completion)
                        return
                    }
                }
                if index + 1 < agyEndpoints.count {
                    fetchAGYWithToken(token: token, index: index + 1, allowRetry: allowRetry, completion: completion)
                } else {
                    completion?(agyFailOutcome(status: status, error: error))
                }
            }
        }.resume()
    }

    private static func fetchAGYWithCookies(cookieHeader: String, index: Int = 0, completion: ((FetchOutcome) -> Void)? = nil) {
        guard index < agyEndpoints.count, let url = URL(string: agyEndpoints[index]) else {
            completion?(cookieHeader.isEmpty ? .needsLogin : .failed("Couldn't refresh"))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cookieHeader.isEmpty {
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        req.httpBody = Data("{}".utf8)

        session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let data = data, let str = String(data: data, encoding: .utf8) {
                    saveAGYRawData(str, rawData: data)
                    completion?(.success)
                    return
                }
                if index + 1 < agyEndpoints.count {
                    fetchAGYWithCookies(cookieHeader: cookieHeader, index: index + 1, completion: completion)
                } else {
                    completion?(agyFailOutcome(status: status, error: error))
                }
            }
        }.resume()
    }

    private static func saveAGYRawData(_ rawString: String, rawData: Data) {
        let agyDir = serviceDir("AGYusageWidget")
        try? rawData.write(to: agyDir.appendingPathComponent("last-raw.json"), options: .atomic)

        guard let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]] else { return }

        var geminiWeekly: Double?
        var geminiReset: Double?
        var gemini5h: Double?
        var gemini5hReset: Double?
        var claudeWeekly: Double?
        var claudeReset: Double?
        var claude5h: Double?
        var claude5hReset: Double?

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()

        for g in groups {
            let gName = (g["displayName"] as? String ?? "").lowercased()
            let buckets = g["buckets"] as? [[String: Any]] ?? []
            for b in buckets {
                let window = b["window"] as? String ?? ""
                let rem = (b["remainingFraction"] as? NSNumber)?.doubleValue ?? 1.0
                let used = max(0, min(100, (1.0 - rem) * 100.0))
                let rTime = b["resetTime"] as? String ?? ""
                let dTs = (iso.date(from: rTime) ?? isoFallback.date(from: rTime))?.timeIntervalSince1970

                if gName.contains("gemini") {
                    if window == "weekly" {
                        geminiWeekly = used
                        geminiReset = dTs
                    } else if window == "5h" {
                        gemini5h = used
                        gemini5hReset = dTs
                    }
                } else if gName.contains("claude") || gName.contains("gpt") {
                    if window == "weekly" {
                        claudeWeekly = used
                        claudeReset = dTs
                    } else if window == "5h" {
                        claude5h = used
                        claude5hReset = dTs
                    }
                }
            }
        }

        let nowTs = Date().timeIntervalSince1970
        let prevClaudeFromAGY = readClaudeSliceFromAGY()

        if let geminiWeekly {
            writeServiceCache(
                dir: agyDir,
                planLabel: "AGY",
                totalPercent: geminiWeekly,
                slices: [["name": "Gemini", "percent": geminiWeekly]],
                resetsAt: geminiReset,
                fiveHourPercent: gemini5h,
                fiveHourResetsAt: gemini5hReset,
                nowTs: nowTs,
                minStep: 0.003,
                maxStep: 30.0,
                prevTotalOverride: nil
            )
        }

        if let claudeWeekly {
            let claudeDir = serviceDir("ClaudeGPTUsageWidget")
            migrateLegacyClaudeDeltasIfNeeded(claudeDir: claudeDir)
            let prevClaude = readPrevTotal(in: claudeDir) ?? prevClaudeFromAGY
            writeServiceCache(
                dir: claudeDir,
                planLabel: "Claude & GPT",
                totalPercent: claudeWeekly,
                slices: [["name": "Claude & GPT", "percent": claudeWeekly]],
                resetsAt: claudeReset,
                fiveHourPercent: claude5h,
                fiveHourResetsAt: claude5hReset,
                nowTs: nowTs,
                minStep: 0.003,
                maxStep: 30.0,
                prevTotalOverride: prevClaude
            )
        }
    }

    private static func serviceDir(_ name: String) -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func readPrevTotal(in dir: URL) -> Double? {
        let url = dir.appendingPathComponent("last-usage.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["totalPercent"] as? NSNumber)?.doubleValue
    }

    private static func readClaudeSliceFromAGY() -> Double? {
        let url = serviceDir("AGYusageWidget").appendingPathComponent("last-usage.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let slices = obj["slices"] as? [[String: Any]],
              let cl = slices.first(where: { (($0["name"] as? String) ?? "").contains("Claude") }) else { return nil }
        return (cl["percent"] as? NSNumber)?.doubleValue
    }

    private static func migrateLegacyClaudeDeltasIfNeeded(claudeDir: URL) {
        let dest = claudeDir.appendingPathComponent("session-deltas.json")
        if FileManager.default.fileExists(atPath: dest.path) { return }
        let legacy = serviceDir("AGYusageWidget").appendingPathComponent("claude-deltas.json")
        guard let data = try? Data(contentsOf: legacy),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Double]] else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let converted: [[String: Any]] = list.compactMap { d in
            guard let delta = d["delta"], let ts = d["timestamp"], delta > 0.005, abs(delta) < 30 else { return nil }
            return [
                "timestamp": ts,
                "date": df.string(from: Date(timeIntervalSince1970: ts)),
                "weeklyDelta": delta,
                "weeklyTotal": 0
            ]
        }
        guard !converted.isEmpty,
              let out = try? JSONSerialization.data(withJSONObject: converted, options: [.prettyPrinted]) else { return }
        try? out.write(to: dest, options: .atomic)
    }

    private static func appendPositiveDelta(
        to deltasURL: URL,
        prevTotal: Double?,
        newTotal: Double,
        fiveHour: Double?,
        nowTs: Double,
        minStep: Double,
        maxStep: Double,
        cap: Int
    ) {
        guard let prev = prevTotal, newTotal > prev + minStep else { return }
        let diff = newTotal - prev
        // Large increases are real usage (widget was closed, or a heavy run).
        // Decreases are handled as resets in updateDailyUsage, not here.
        _ = maxStep

        var list: [[String: Any]] = []
        if let sData = try? Data(contentsOf: deltasURL),
           let existing = try? JSONSerialization.jsonObject(with: sData) as? [[String: Any]] {
            list = existing
        }
        if list.contains(where: { abs((($0["timestamp"] as? NSNumber)?.doubleValue ?? 0) - nowTs) < 1.0 }) {
            return
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var rec: [String: Any] = [
            "date": df.string(from: Date(timeIntervalSince1970: nowTs)),
            "timestamp": nowTs,
            "weeklyDelta": diff,
            "weeklyTotal": newTotal
        ]
        if let f5 = fiveHour { rec["fiveHourPercent"] = f5 }
        list.append(rec)
        let cutoff = nowTs - (366.0 * 24.0 * 3600.0)
        list = list.filter { (($0["timestamp"] as? NSNumber)?.doubleValue ?? 0) >= cutoff }
        let hardCap = max(cap, 4000)
        if list.count > hardCap { list = Array(list.suffix(hardCap)) }
        if let sOut = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) {
            try? sOut.write(to: deltasURL, options: .atomic)
        }
    }

    private static func updateDailyUsage(dir: URL, totalPercent: Double, nowTs: Double, resetsAt: Double?) {
        let dailyURL = dir.appendingPathComponent("daily-usage.json")
        var map: [String: [String: Double]] = [:]
        if let data = try? Data(contentsOf: dailyURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for (k, v) in obj {
                map[k] = [
                    "open": (v["open"] as? NSNumber)?.doubleValue ?? 0,
                    "close": (v["close"] as? NSNumber)?.doubleValue ?? 0,
                    "accumulated": (v["accumulated"] as? NSNumber)?.doubleValue ?? 0
                ]
            }
        }

        let cal = Calendar.current
        let now = Date(timeIntervalSince1970: nowTs)
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let todayKey = fmt.string(from: now)
        let yesterdayKey = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)).map { fmt.string(from: $0) }

        var entry = map[todayKey] ?? [:]
        let yesterdayClose = yesterdayKey.flatMap { map[$0]?["close"] }

        if entry["open"] == nil {
            entry["open"] = yesterdayClose ?? totalPercent
        }

        if let prevClose = entry["close"] ?? yesterdayClose, totalPercent + 5 < prevClose {
            let resetDate = resetsAt.map { Date(timeIntervalSince1970: $0) }
            let scheduled = UsageParser.isResetWeekday(todayKey, reset: resetDate)
            if scheduled {
                entry["accumulated"] = 0
            } else {
                let drop = prevClose - totalPercent
                entry["accumulated"] = (entry["accumulated"] ?? 0) + drop
            }
            entry["open"] = totalPercent
        }

        entry["close"] = totalPercent
        if entry["accumulated"] == nil { entry["accumulated"] = 0 }
        map[todayKey] = entry

        var out: [String: [String: Double]] = [:]
        for (k, v) in map { out[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]) {
            try? data.write(to: dailyURL, options: .atomic)
        }
    }

    private static func writeServiceCache(
        dir: URL,
        planLabel: String,
        totalPercent: Double,
        slices: [[String: Any]],
        resetsAt: Double?,
        fiveHourPercent: Double?,
        fiveHourResetsAt: Double?,
        nowTs: Double,
        minStep: Double,
        maxStep: Double,
        prevTotalOverride: Double?
    ) {
        let lastUsageURL = dir.appendingPathComponent("last-usage.json")
        let deltasURL = dir.appendingPathComponent("session-deltas.json")
        let prevTotal = prevTotalOverride ?? readPrevTotal(in: dir)
        appendPositiveDelta(
            to: deltasURL,
            prevTotal: prevTotal,
            newTotal: totalPercent,
            fiveHour: fiveHourPercent,
            nowTs: nowTs,
            minStep: minStep,
            maxStep: maxStep,
            cap: 4000
        )
        updateDailyUsage(dir: dir, totalPercent: totalPercent, nowTs: nowTs, resetsAt: resetsAt)

        var recentDeltas: [[String: Any]] = []
        if let sData = try? Data(contentsOf: deltasURL),
           let list = try? JSONSerialization.jsonObject(with: sData) as? [[String: Any]] {
            recentDeltas = Array(list.reversed().prefix(4)).compactMap { item in
                guard let d = (item["weeklyDelta"] as? NSNumber)?.doubleValue,
                      let ts = (item["timestamp"] as? NSNumber)?.doubleValue else { return nil }
                return ["delta": d, "timestamp": ts]
            }
        }

        var dict: [String: Any] = [
            "planLabel": planLabel,
            "fetchedAt": nowTs,
            "totalPercent": totalPercent,
            "slices": slices,
            "recentDeltas": recentDeltas
        ]
        if let r = resetsAt {
            dict["resetsAt"] = r
            dict["resetsLabel"] = UsageParser.formatReset(Date(timeIntervalSince1970: r))
        }
        if let f5 = fiveHourPercent { dict["fiveHourPercent"] = f5 }
        if let f5r = fiveHourResetsAt {
            dict["fiveHourResetsAt"] = f5r
            dict["fiveHourResetsLabel"] = UsageParser.formatResetOn(Date(timeIntervalSince1970: f5r))
        }
        if let uData = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? uData.write(to: lastUsageURL, options: .atomic)
        }
    }

    static func fetchGrok(completion: ((FetchOutcome) -> Void)? = nil) {
        collectCookies(domains: ["grok.com", "x.ai"]) { dict in
            performGrokRequest(cookies: dict, completion: completion)
        }
    }

    private static func performGrokRequest(cookies: [String: String], completion: ((FetchOutcome) -> Void)? = nil) {
        guard !cookies.isEmpty, let url = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig") else {
            completion?(.needsLogin)
            return
        }
        let header = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        req.setValue("1", forHTTPHeaderField: "x-grpc-web")
        req.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue(header, forHTTPHeaderField: "Cookie")
        req.httpBody = Data([0, 0, 0, 0, 0])

        session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let data = data, let parsed = CreditsBinary.parse(data) {
                    saveGrokData(parsed, rawData: data)
                    completion?(.success)
                    return
                }
                completion?(agyFailOutcome(status: status, error: error))
            }
        }.resume()
    }

    private static func saveGrokData(_ parsed: [String: Any], rawData: Data) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let grokDir = appSupport.appendingPathComponent("GrokUsageWidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: grokDir, withIntermediateDirectories: true)
        let rawURL = grokDir.appendingPathComponent("last-raw.json")
        let dump: [String: Any] = ["status": 200, "bytes": rawData.count, "parsed": parsed]
        if let dData = try? JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted]) {
            try? dData.write(to: rawURL, options: .atomic)
        }

        let total = parsed["usagePercent"] as? Double ?? 0.0
        let products = parsed["productUsage"] as? [[String: Any]] ?? []
        var slices: [[String: Any]] = []
        for p in products {
            let pName = p["name"] as? String ?? "Product"
            let pUsed = p["usagePercent"] as? Double ?? 0.0
            slices.append(["name": pName, "percent": pUsed])
        }

        let period = parsed["currentPeriod"] as? [String: Any]
        let resetStr = period?["end"] as? String
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        let resetDate = resetStr.flatMap { iso.date(from: $0) ?? isoFallback.date(from: $0) }
        let nowTs = Date().timeIntervalSince1970
        writeServiceCache(
            dir: grokDir,
            planLabel: "Grok",
            totalPercent: total,
            slices: slices,
            resetsAt: resetDate?.timeIntervalSince1970,
            fiveHourPercent: nil,
            fiveHourResetsAt: nil,
            nowTs: nowTs,
            minStep: 0.005,
            maxStep: 50.0,
            prevTotalOverride: nil
        )
    }

    static func fetchGrokBot(completion: ((FetchOutcome) -> Void)? = nil) {
        collectCookies(domains: ["cursor.com", "cursor.sh"]) { dict in
            performGrokBotRequest(cookies: dict, completion: completion)
        }
    }

    private static func performGrokBotRequest(cookies: [String: String], completion: ((FetchOutcome) -> Void)? = nil) {
        guard !cookies.isEmpty, let url = URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status") else {
            completion?(.needsLogin)
            return
        }
        let header = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        req.setValue("https://cursor.com", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue(header, forHTTPHeaderField: "Cookie")
        req.httpBody = Data("{}".utf8)

        session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    saveGrokBotData(json, rawData: data)
                    completion?(.success)
                    return
                }
                completion?(agyFailOutcome(status: status, error: error))
            }
        }.resume()
    }

    private static func saveGrokBotData(_ json: [String: Any], rawData: Data) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let botDir = appSupport.appendingPathComponent("GrokBotUsageWidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: botDir, withIntermediateDirectories: true)
        let rawURL = botDir.appendingPathComponent("last-raw.json")
        try? rawData.write(to: rawURL, options: .atomic)

        let total = json["usagePercent"] as? Double ?? 0.0
        let plan = (json["grokPlanLabel"] as? String) ?? (json["includedUsageSuperGrokPlan"] as? String) ?? "Grok Bot"
        let resetStr = json["nextResetTimestampUtc"] as? String
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        let resetDate = resetStr.flatMap { iso.date(from: $0) ?? isoFallback.date(from: $0) }
        let nowTs = Date().timeIntervalSince1970
        writeServiceCache(
            dir: botDir,
            planLabel: plan,
            totalPercent: total,
            slices: [["name": "Grok Bot", "percent": total]],
            resetsAt: resetDate?.timeIntervalSince1970,
            fiveHourPercent: nil,
            fiveHourResetsAt: nil,
            nowTs: nowTs,
            minStep: 0.003,
            maxStep: 50.0,
            prevTotalOverride: nil
        )
    }

    private static func chatgptDeviceId() -> String {
        let key = "bigu.chatgpt.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static func fetchChatGPT(completion: ((FetchOutcome) -> Void)? = nil) {
        collectCookies(domains: ["chatgpt.com", "openai.com"]) { dict in
            guard !dict.isEmpty else {
                completion?(.needsLogin)
                return
            }
            fetchChatGPTSession(cookies: dict, completion: completion)
        }
    }

    private static func fetchChatGPTSession(cookies: [String: String], completion: ((FetchOutcome) -> Void)? = nil) {
        guard let url = URL(string: "https://chatgpt.com/api/auth/session") else {
            completion?(.failed("Couldn't refresh"))
            return
        }
        let header = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        req.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue(header, forHTTPHeaderField: "Cookie")
        req.setValue(chatgptDeviceId(), forHTTPHeaderField: "oai-device-id")

        session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 {
                    completion?(.needsLogin)
                    return
                }
                guard status == 200, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = json["accessToken"] as? String, !token.isEmpty else {
                    completion?(agyFailOutcome(status: status, error: error))
                    return
                }
                fetchChatGPTUsage(token: token, cookies: cookies, completion: completion)
            }
        }.resume()
    }

    private static func fetchChatGPTUsage(token: String, cookies: [String: String], completion: ((FetchOutcome) -> Void)? = nil) {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            completion?(.failed("Couldn't refresh"))
            return
        }
        let header = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        req.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue(header, forHTTPHeaderField: "Cookie")
        req.setValue(chatgptDeviceId(), forHTTPHeaderField: "oai-device-id")

        session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 {
                    completion?(.needsLogin)
                    return
                }
                guard status == 200, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion?(agyFailOutcome(status: status, error: error))
                    return
                }
                saveChatGPTData(json, rawData: data)
                completion?(.success)
            }
        }.resume()
    }

    private static func chatGPTWindowUsed(_ window: [String: Any]?) -> Double? {
        guard let window else { return nil }
        return (window["used_percent"] as? NSNumber)?.doubleValue
    }

    private static func chatGPTResetDate(_ window: [String: Any]?) -> Date? {
        guard let window else { return nil }
        if let epoch = (window["reset_at"] as? NSNumber)?.doubleValue, epoch > 1_000_000_000 {
            return Date(timeIntervalSince1970: epoch)
        }
        if let after = (window["reset_after_seconds"] as? NSNumber)?.doubleValue, after > 0 {
            return Date().addingTimeInterval(after)
        }
        return nil
    }

    private static func saveChatGPTData(_ json: [String: Any], rawData: Data) {
        let dir = serviceDir("ChatGPTUsageWidget")
        let rawURL = dir.appendingPathComponent("last-raw.json")
        try? rawData.write(to: rawURL, options: .atomic)

        let usage = (json["usage"] as? [String: Any]) ?? json
        let rate = usage["rate_limit"] as? [String: Any]
        let primary = rate?["primary_window"] as? [String: Any]
        let secondary = rate?["secondary_window"] as? [String: Any]
        let five = chatGPTWindowUsed(primary)
        let weekly = chatGPTWindowUsed(secondary) ?? five ?? 0
        let plan = (usage["plan_type"] as? String)?.capitalized ?? "ChatGPT"
        let nowTs = Date().timeIntervalSince1970
        writeServiceCache(
            dir: dir,
            planLabel: plan,
            totalPercent: weekly,
            slices: [["name": "ChatGPT", "percent": weekly]],
            resetsAt: chatGPTResetDate(secondary)?.timeIntervalSince1970,
            fiveHourPercent: five,
            fiveHourResetsAt: chatGPTResetDate(primary)?.timeIntervalSince1970,
            nowTs: nowTs,
            minStep: 0.003,
            maxStep: 100.0,
            prevTotalOverride: nil
        )
    }
}

// MARK: - Binary Cookies & Credits Parsing Helpers

enum BinaryCookiesReader {
    static func getCookies(domains: [String]) -> [String: String] {
        var result: [String: String] = [:]
        let paths = [
            "~/Library/HTTPStorages/com.jakubsokolowski.grok-usage-widget.binarycookies",
            "~/Library/HTTPStorages/com.jakubsokolowski.grokbot-usage-widget.binarycookies",
            "~/Library/HTTPStorages/com.jakubsokolowski.BigUwidget.binarycookies",
            "~/Library/HTTPStorages/com.jakubsokolowski.agy-usage-widget.binarycookies"
        ]
        for p in paths {
            let expanded = NSString(string: p).expandingTildeInPath
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { continue }
            let parsed = parseBinaryCookies(data: data)
            for (url, name, val) in parsed {
                if domains.contains(where: { url.contains($0) }) {
                    result[name] = val
                }
            }
        }
        return result
    }

    private static func parseBinaryCookies(data: Data) -> [(url: String, name: String, val: String)] {
        var cookies: [(String, String, String)] = []
        guard data.count > 12 else { return [] }
        let buf = [UInt8](data)
        guard buf[0] == 0x63, buf[1] == 0x6F, buf[2] == 0x6F, buf[3] == 0x6B else { return [] }
        let numPages = Int(UInt32(buf[4]) << 24 | UInt32(buf[5]) << 16 | UInt32(buf[6]) << 8 | UInt32(buf[7]))
        guard data.count >= 8 + numPages * 4 else { return [] }
        var pageSizes: [Int] = []
        for i in 0..<numPages {
            let off = 8 + i * 4
            let sz = Int(UInt32(buf[off]) << 24 | UInt32(buf[off+1]) << 16 | UInt32(buf[off+2]) << 8 | UInt32(buf[off+3]))
            pageSizes.append(sz)
        }
        var pos = 8 + numPages * 4
        for sz in pageSizes {
            guard pos + sz <= buf.count, sz >= 8 else { break }
            let pageData = Array(buf[pos..<(pos+sz)])
            pos += sz
            let numCookies = Int(UInt32(pageData[4]) | UInt32(pageData[5]) << 8 | UInt32(pageData[6]) << 16 | UInt32(pageData[7]) << 24)
            guard pageData.count >= 8 + numCookies * 4 else { continue }
            var cookieOffsets: [Int] = []
            for i in 0..<numCookies {
                let off = 8 + i * 4
                let cOff = Int(UInt32(pageData[off]) | UInt32(pageData[off+1]) << 8 | UInt32(pageData[off+2]) << 16 | UInt32(pageData[off+3]) << 24)
                cookieOffsets.append(cOff)
            }
            for cOff in cookieOffsets {
                guard cOff + 32 <= pageData.count else { continue }
                let urlOff = Int(UInt32(pageData[cOff+16]) | UInt32(pageData[cOff+17]) << 8 | UInt32(pageData[cOff+18]) << 16 | UInt32(pageData[cOff+19]) << 24)
                let nameOff = Int(UInt32(pageData[cOff+20]) | UInt32(pageData[cOff+21]) << 8 | UInt32(pageData[cOff+22]) << 16 | UInt32(pageData[cOff+23]) << 24)
                let valOff = Int(UInt32(pageData[cOff+28]) | UInt32(pageData[cOff+29]) << 8 | UInt32(pageData[cOff+30]) << 16 | UInt32(pageData[cOff+31]) << 24)
                let url = readCString(pageData, from: cOff + urlOff)
                let name = readCString(pageData, from: cOff + nameOff)
                let val = readCString(pageData, from: cOff + valOff)
                if !name.isEmpty {
                    cookies.append((url, name, val))
                }
            }
        }
        return cookies
    }

    private static func readCString(_ buf: [UInt8], from start: Int) -> String {
        guard start < buf.count else { return "" }
        var end = start
        while end < buf.count && buf[end] != 0 { end += 1 }
        return String(bytes: buf[start..<end], encoding: .utf8) ?? ""
    }
}

enum CreditsBinary {
    static let names = [
        0: "3rd Party", 1: "API", 2: "Grok Build", 3: "Plugins",
        4: "Chat", 5: "Imagine", 6: "Voice", 7: "App Builder"
    ]

    static func parse(_ data: Data) -> [String: Any]? {
        let buf = [UInt8](data)
        if buf.count < 10 { return nil }
        let floats = headlineFloats(buf)
        var productUsage: [[String: Any]] = []
        var periodStart: String?
        var periodEnd: String?
        var i = 0
        while i < buf.count - 7 {
            if buf[i] == 0x3A && buf[i + 1] == 0x07 && buf[i + 2] == 0x08 {
                let product = Int(buf[i + 3])
                if buf[i + 4] == 0x15 {
                    let pct = (Double(float32(buf, i + 5)) * 10).rounded() / 10
                    if pct >= 0 && pct <= 100 {
                        productUsage.append([
                            "product": product,
                            "name": names[product] ?? "Product \(product)",
                            "usagePercent": pct
                        ])
                    }
                }
            }
            i += 1
        }
        i = 0
        while i < buf.count - 4 {
            if buf[i] == 0x42 && buf[i + 1] > 0 && buf[i + 1] < 40 {
                let blockLen = Int(buf[i + 1])
                let blockStart = i + 2
                let blockEnd = blockStart + blockLen
                if blockEnd <= buf.count {
                    var pos = blockStart
                    while pos < blockEnd - 1 {
                        let tag = buf[pos]
                        pos += 1
                        let field = Int(tag >> 3)
                        let wire = tag & 0x07
                        if wire == 2 {
                            let len = Int(buf[pos])
                            pos += 1
                            if field == 2 && periodStart == nil {
                                periodStart = protoTimestamp(buf, pos, len)
                            } else if field == 3 && periodEnd == nil {
                                periodEnd = protoTimestamp(buf, pos, len)
                            }
                            pos += len
                        } else if wire == 0 {
                            pos = varint(buf, pos).next
                        } else {
                            break
                        }
                    }
                    if periodStart != nil || periodEnd != nil { break }
                }
            }
            i += 1
        }
        let productSum = productUsage.reduce(0.0) { $0 + (($1["usagePercent"] as? Double) ?? 0) }
        let unique = Array(Set(floats.map { Int($0) }))
        var usagePercent: Double?
        if unique.count == 1 {
            usagePercent = Double(unique[0])
        } else if productSum > 0 && !unique.isEmpty {
            var best = Double(unique[0])
            var bestDist = Double.infinity
            for f in unique {
                for c in [Double(f), 100 - Double(f)] {
                    let dist = abs(c - productSum)
                    if dist < bestDist {
                        bestDist = dist
                        best = c
                    }
                }
            }
            usagePercent = best
        } else if let first = unique.first {
            usagePercent = Double(first)
        }
        if let used = usagePercent, productSum > 0,
           abs((100 - used) - productSum) <= 3, abs(used - productSum) > 3 {
            usagePercent = productSum
        }
        if usagePercent == nil && productSum > 0 {
            usagePercent = min(100, productSum)
        }
        if usagePercent == nil && productUsage.isEmpty && periodStart == nil && periodEnd == nil {
            return nil
        }
        var period: [String: Any] = ["type": "weekly"]
        if let periodStart { period["start"] = periodStart }
        if let periodEnd { period["end"] = periodEnd }
        return [
            "usagePercent": usagePercent ?? 0,
            "currentPeriod": period,
            "productUsage": productUsage
        ]
    }

    private static func float32(_ buf: [UInt8], _ i: Int) -> Float {
        let le = UInt32(buf[i])
            | UInt32(buf[i + 1]) << 8
            | UInt32(buf[i + 2]) << 16
            | UInt32(buf[i + 3]) << 24
        return Float(bitPattern: le)
    }

    private static func headlineFloats(_ buf: [UInt8]) -> [Double] {
        var out: [Double] = []
        var i = 0
        while i < buf.count - 5 {
            if buf[i] == 0x0D {
                let val = Double(float32(buf, i + 1)).rounded()
                if val >= 0 && val <= 100 { out.append(val) }
            }
            i += 1
        }
        return out
    }

    private static func varint(_ buf: [UInt8], _ offset: Int) -> (value: Int, next: Int) {
        var result = 0
        var shift = 0
        var pos = offset
        while pos < buf.count {
            let byte = Int(buf[pos])
            pos += 1
            result |= (byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return (result, pos)
    }

    private static func protoTimestamp(_ buf: [UInt8], _ offset: Int, _ length: Int) -> String? {
        let end = offset + length
        var pos = offset
        var seconds = 0
        var nanos = 0
        while pos < end {
            let tag = buf[pos]
            pos += 1
            let field = Int(tag >> 3)
            let wire = tag & 0x07
            if wire == 0 {
                let decoded = varint(buf, pos)
                pos = decoded.next
                if field == 1 { seconds = decoded.value }
                else if field == 2 { nanos = decoded.value }
            } else {
                break
            }
        }
        if seconds == 0 { return nil }
        let date = Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.string(from: date)
    }
}

// MARK: - Master Store

final class CombinedStore: ObservableObject {
    @Published var grok = SingleServiceStore(service: .grok, cacheDirName: ServiceKind.grok.cacheDirName)
    @Published var grokBot = SingleServiceStore(service: .grokBot, cacheDirName: ServiceKind.grokBot.cacheDirName)
    @Published var agy = SingleServiceStore(service: .agy, cacheDirName: ServiceKind.agy.cacheDirName)
    @Published var claudeGPT = SingleServiceStore(service: .claudeGPT, cacheDirName: ServiceKind.claudeGPT.cacheDirName)
    @Published var chatGPT = SingleServiceStore(service: .chatGPT, cacheDirName: ServiceKind.chatGPT.cacheDirName)

    private var fetchTimer: Timer?
    private var fetchInFlight = false
    private var pendingCards: Set<WidgetCardID>?

    init() {
        startLiveFetcher()
    }

    func store(_ kind: ServiceKind) -> SingleServiceStore {
        switch kind {
        case .grok: return grok
        case .grokBot: return grokBot
        case .agy: return agy
        case .claudeGPT: return claudeGPT
        case .chatGPT: return chatGPT
        }
    }

    func reloadAll() {
        grok.reloadFromDisk()
        grokBot.reloadFromDisk()
        agy.reloadFromDisk()
        claudeGPT.reloadFromDisk()
        chatGPT.reloadFromDisk()
    }

    func fetchLiveNow() {
        fetchCards(WidgetLayoutSettings.shared.enabledCards)
    }

    func fetchNow(_ kind: ServiceKind) {
        switch kind {
        case .grok: fetchCards([.grok])
        case .grokBot: fetchCards([.grokBot])
        case .agy, .claudeGPT: fetchCards([.agy, .claudeGPT])
        case .chatGPT: fetchCards([.chatGPT])
        }
    }

    func fetchCards(_ cards: Set<WidgetCardID>) {
        guard !cards.isEmpty else { return }
        if fetchInFlight {
            pendingCards = (pendingCards ?? []).union(cards)
            return
        }
        fetchInFlight = true
        LiveServiceFetcher.fetchEnabled(cards) { [weak self] outcomes in
            guard let self else { return }
            for (kind, outcome) in outcomes {
                self.store(kind).applyFetchOutcome(outcome)
            }
            self.fetchInFlight = false
            if let pending = self.pendingCards, !pending.isEmpty {
                self.pendingCards = nil
                self.fetchCards(pending)
            }
        }
    }

    private func startLiveFetcher() {
        fetchLiveNow()

        fetchTimer?.invalidate()
        let timer = Timer(timeInterval: 25.0, repeats: true) { [weak self] _ in
            self?.fetchLiveNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        fetchTimer = timer
    }
}

// MARK: - UI Components

struct RollingWheelNumberView: View {
    let value: Int
    let font: Font
    let color: Color
    let height: CGFloat

    @State private var prevValue: Int = 0

    var body: some View {
        let isIncreasing = value >= prevValue
        let enterY: CGFloat = isIncreasing ? height * 0.85 : -height * 0.85
        let exitY: CGFloat = isIncreasing ? -height * 0.85 : height * 0.85

        HStack(alignment: .firstTextBaseline, spacing: 0.5) {
            ZStack {
                Text("\(value)")
                    .font(font)
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .id(value)
                    .transition(
                        .asymmetric(
                            insertion: .offset(y: enterY).combined(with: .opacity),
                            removal: .offset(y: exitY).combined(with: .opacity)
                        )
                    )
            }
            .frame(height: height)
            .clipped()

            Text("%")
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .animation(.spring(response: 0.52, dampingFraction: 0.72), value: value)
        .onAppear {
            prevValue = value
        }
        .onChange(of: value) { newVal in
            prevValue = newVal
        }
    }
}

struct BlueQuotaProgressBar: View {
    let usedPercent: Double
    let gainPercent: Double

    var body: some View {
        let hasReset = gainPercent >= 0.5
        let totalCapacity = hasReset ? (100.0 + gainPercent) : 100.0
        let gainInt = Int(gainPercent.rounded())
        let clampedUsed = min(max(usedPercent, 0), totalCapacity)

        HStack(alignment: .center, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let fillW = totalCapacity > 0 ? (clampedUsed / totalCapacity) * w : 0

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: w, height: h)

                    if fillW > 0 {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: 0x1E88E5), Color(hex: 0x24C1E0)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(3, min(w, fillW)), height: h)
                    }
                }
            }
            .frame(height: 3.5)

            if hasReset {
                HStack(spacing: 0) {
                    Text("100%")
                        .foregroundStyle(Color.white.opacity(0.75))
                    Text(" + \(gainInt)%")
                        .foregroundStyle(Color(hex: 0x24C1E0))
                }
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            } else {
                Text("100%")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.60))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .help(
            hasReset
                ? "Weekly Quota Pool: 100% + \(gainInt)% gained from additional reset this week"
                : "Weekly Quota Pool: 100%"
        )
    }
}

struct SegmentedBar: View {
    let total: Double
    let slices: [UsageSlice]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let used = min(max(total, 0), 100)
            HStack(spacing: 1) {
                ForEach(slices) { slice in
                    let share = used > 0 ? slice.percent / used : 0
                    Capsule()
                        .fill(slice.color)
                        .frame(width: max(3, w * (used / 100) * share - 1))
                }
                Capsule()
                    .fill(Color.white.opacity(0.12))
            }
            .frame(width: w, height: h, alignment: .leading)
        }
    }
}

// MARK: - Delta Color Helper (Dynamic Drop Flash: Green / Orange -> Default Cyan)

enum DeltaColorHelper {
    static let lowGreen = Color(hex: 0x32D74B)     // Vibrant Apple HIG Green for low usage drop
    static let highOrange = Color(hex: 0xFF9500)   // Vibrant Apple HIG Orange for high usage drop
    static let defaultCyan = Color(hex: 0x24C1E0)  // Default signature cyan resting color

    static func dropColor(for delta: Double, service: ServiceKind? = nil) -> Color {
        if service == .grok {
            // Grok reports in integer increments (1%, 2%, ...)
            return delta > 1.0 ? highOrange : lowGreen
        } else {
            // AGY & Grok Bot report fractional deltas (0.01% - 1.5%+)
            // Below 0.20% is low (green), 0.20% and above is high (orange)
            return delta >= 0.20 ? highOrange : lowGreen
        }
    }
}

struct DeltaBubbleRow: View {
    let item: RecentDeltaItem
    let index: Int
    let now: Date
    var service: ServiceKind? = nil

    @State private var isLit: Bool = false

    var isTop: Bool { index == 0 }

    var body: some View {
        let opacities: [Double] = [1.0, 0.88, 0.76, 0.65]
        let op = opacities[min(index, opacities.count - 1)]
        let age = UsageParser.deltaAgeLabel(item.timestamp, now: now)

        let dropColor = DeltaColorHelper.dropColor(for: item.delta, service: service)
        let defaultColor = DeltaColorHelper.defaultCyan
        let activeColor = (isLit && isTop) ? dropColor : defaultColor

        let deltaText: String = {
            if item.delta.rounded() == item.delta {
                return "+\(Int(item.delta))%"
            } else if item.delta >= 10.0 {
                return String(format: "+%.1f%%", item.delta)
            } else {
                return String(format: "+%.2f%%", item.delta)
            }
        }()

        HStack(spacing: 3) {
            if !age.isEmpty {
                Text(age)
                    .font(.system(size: isTop ? 7.5 : 6.8, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.46 * op))
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(deltaText)
                .font(.system(size: isTop ? 10.5 : 8.5, weight: isTop ? .heavy : .semibold, design: .rounded))
                .foregroundStyle(activeColor.opacity(op))
                .padding(.horizontal, isTop ? 4.5 : 4)
                .padding(.vertical, isTop ? 1.8 : 1)
                .background(
                    RoundedRectangle(cornerRadius: isTop ? 4.5 : 3.5, style: .continuous)
                        .fill(activeColor.opacity(isTop ? (isLit ? 0.40 : 0.22) : (0.16 * op)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: isTop ? 4.5 : 3.5, style: .continuous)
                        .stroke(activeColor.opacity(isTop ? (isLit ? 0.85 : 0.40) : 0.0), lineWidth: isLit ? 1.2 : 0.8)
                )
                .shadow(color: isLit ? activeColor.opacity(0.65) : .clear, radius: isLit ? 6 : 0, x: 0, y: 0)
                .fixedSize(horizontal: true, vertical: false)
        }
        .task(id: item.id) {
            let isRecent = (now.timeIntervalSince1970 - item.timestamp) < 20
            if isTop && isRecent {
                isLit = true
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                withAnimation(.easeInOut(duration: 0.55)) {
                    isLit = false
                }
            } else {
                isLit = false
            }
        }
        .onChange(of: isTop) { newIsTop in
            if !newIsTop {
                isLit = false
            }
        }
        .help(isTop ? "Latest prompt usage delta (\(age)) · Click to view sessions & prompt history" : "Previous prompt delta (\(age))")
    }
}

struct DeltasStackView: View {
    let deltas: [RecentDeltaItem]
    let now: Date
    var service: ServiceKind? = nil
    var onOpenSessionHistory: (() -> Void)? = nil

    var body: some View {
        let visible = Array(deltas.prefix(4))
        VStack(alignment: .trailing, spacing: 2.5) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                DeltaBubbleRow(item: item, index: index, now: now, service: service)
                    .transition(
                        .asymmetric(
                            insertion: AnyTransition.offset(y: -14)
                                .combined(with: .scale(scale: 0.60, anchor: .trailing))
                                .combined(with: .opacity)
                                .animation(.spring(response: 0.42, dampingFraction: 0.72)),
                            removal: AnyTransition.offset(x: 48)
                                .combined(with: .scale(scale: 0.75, anchor: .trailing))
                                .combined(with: .opacity)
                                .animation(.easeInOut(duration: 0.68))
                        )
                    )
            }
        }
        .padding(.top, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenSessionHistory?()
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: deltas)
    }
}

struct WeekStripView: View {
    let days: [DayUse]
    let todayKey: String
    let resetAt: Date?
    var onOpenCalendar: (() -> Void)? = nil

    var body: some View {
        let resetGreen = Color(hex: 0x32D74B)
        let gold = Color(hex: 0xFFD700)

        // Only show the golden dot if the week hasn't ended yet (resetAt is still in the future)
        let weekStillActive: Bool = {
            guard let r = resetAt else { return true }
            return r > Date()
        }()

        HStack(spacing: 1) {
            ForEach(days) { day in
                let isToday = day.key == todayKey
                let isReset = UsageParser.isResetWeekday(day.key, reset: resetAt)
                let hasBonus = weekStillActive && day.accumulatedGain >= 0.5
                let gainInt = Int(day.accumulatedGain.rounded())

                VStack(spacing: 1.5) {
                    if hasBonus {
                        Text("+\(gainInt)")
                            .font(.system(size: 6.5, weight: .heavy, design: .rounded))
                            .foregroundStyle(gold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .shadow(color: gold.opacity(0.7), radius: 3)
                    } else {
                        Circle()
                            .fill(isToday ? Color.white : Color.clear)
                            .frame(width: 2.5, height: 2.5)
                    }

                    Text(day.label)
                        .font(.system(size: 8, weight: (isToday || isReset || hasBonus) ? .bold : .semibold))
                        .foregroundStyle(isReset ? resetGreen : Color.white.opacity(isToday ? 0.9 : 0.5))

                    Text("\(Int(day.percent.rounded()))%")
                        .font(.system(size: 8.8, weight: .semibold, design: .rounded))
                        .foregroundStyle(hasBonus ? gold : Color.white.opacity(isToday ? 0.86 : 0.62))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .help(hasBonus ? "Intra-week reset: +\(gainInt)% quota gained" : "Click to view usage calendar")
                .padding(.vertical, 2)
                .frame(width: 20)
                .background(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(isReset ? resetGreen.opacity(0.18) : (isToday ? Color.white.opacity(0.12) : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .stroke(isReset ? resetGreen.opacity(0.35) : (isToday ? Color.white.opacity(0.35) : Color.clear), lineWidth: 0.8)
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenCalendar?()
        }
        .help("Click to view usage calendar")
    }
}

struct MiniDeltaPill: View {
    let delta: RecentDeltaItem
    var service: ServiceKind? = nil
    var onOpenSessionHistory: (() -> Void)? = nil

    @State private var isLit: Bool = false

    var body: some View {
        let dropColor = DeltaColorHelper.dropColor(for: delta.delta, service: service)
        let defaultColor = DeltaColorHelper.defaultCyan
        let activeColor = isLit ? dropColor : defaultColor

        let deltaText: String = {
            if delta.delta.rounded() == delta.delta {
                return "+\(Int(delta.delta))%"
            } else if delta.delta >= 10.0 {
                return String(format: "+%.1f%%", delta.delta)
            } else {
                return String(format: "+%.2f%%", delta.delta)
            }
        }()

        Text(deltaText)
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .foregroundStyle(activeColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(activeColor.opacity(isLit ? 0.40 : 0.20))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(activeColor.opacity(isLit ? 0.85 : 0.0), lineWidth: isLit ? 1.0 : 0.0)
            )
            .shadow(color: isLit ? activeColor.opacity(0.60) : .clear, radius: isLit ? 5 : 0, x: 0, y: 0)
            .contentShape(Rectangle())
            .onTapGesture {
                onOpenSessionHistory?()
            }
            .help("Click to view prompt timestamps and session activity")
            .task(id: delta.id) {
                let isRecent = (Date().timeIntervalSince1970 - delta.timestamp) < 20
                if isRecent {
                    isLit = true
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    withAnimation(.easeInOut(duration: 0.55)) {
                        isLit = false
                    }
                } else {
                    isLit = false
                }
            }
    }
}

struct ServiceCardView: View {
    @ObservedObject var subStore: SingleServiceStore
    let now: Date
    var isMasterTop: Bool = false
    var onMasterMinimize: (() -> Void)? = nil
    var onMasterClose: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    var onOpenSessionHistory: (() -> Void)? = nil
    var onOpenCalendar: (() -> Void)? = nil
    var onRefresh: (() -> Void)? = nil
    var onSignIn: (() -> Void)? = nil

    @State private var isWeekHidden: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Section Header
            HStack(alignment: .center, spacing: 3) {
                Text(subStore.service.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let warn = subStore.fetchWarning {
                    let offline = warn == "offline"
                    Button(action: { offline ? onSignIn?() : onRefresh?() }) {
                        Text(offline ? "offline" : warn)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color(hex: offline ? 0xFF9F0A : 0xFF453A))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .buttonStyle(.plain)
                    .help(offline ? "Sign in" : "Click to refresh now")
                }
                Spacer(minLength: 1)

                // Collapse / expand toggle arrow for all cards (including Grok)
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        subStore.toggleCollapse()
                    }
                }) {
                    Image(systemName: subStore.isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(subStore.isCollapsed ? "Expand card" : "Collapse card")

                if isMasterTop {
                    // Settings button
                    Button(action: { onOpenSettings?() }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .frame(width: 18, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Widget Settings (Enable, Reorder, Dock / Undock)")

                    // Master control buttons on the top card
                    Button(action: { onMasterMinimize?() }) {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .frame(width: 18, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Minimize Dashboard to Dock")

                    Button(action: { onMasterClose?() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .frame(width: 18, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close Dashboard")
                }
            }

            // Body
            switch subStore.state {
            case .loading:
                Text("Loading…")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .padding(.vertical, 8)
            case .needsLogin:
                Button(action: { onSignIn?() }) {
                    Text("Sign in")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x24C1E0))
                }
                .buttonStyle(.plain)
                .help("Open sign-in window")
                .padding(.vertical, 6)
            case .error(let msg):
                Button(action: { onRefresh?() }) {
                    Text(msg)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.red.opacity(0.8))
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .help("Click to retry")
            case .ready(let snap):
                let wallNow = now
                let todayKey = String(format: "%04d-%02d-%02d",
                    Calendar.current.component(.year, from: wallNow),
                    Calendar.current.component(.month, from: wallNow),
                    Calendar.current.component(.day, from: wallNow))
                let todayUsed = subStore.usedPercent(on: todayKey)
                let status = UsageParser.calculateDailyStatus(
                    totalPercent: snap.totalPercent,
                    todayUsed: todayUsed,
                    resetsAt: snap.resetsAt,
                    now: wallNow
                )

                if subStore.isCollapsed {
                    // Compact mini view
                    HStack(alignment: .center, spacing: 4) {
                        // Left: Total used %
                        HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                            RollingWheelNumberView(
                                value: Int(snap.totalPercent.rounded()),
                                font: .system(size: snap.totalPercent >= 99.5 ? 12 : 13, weight: .bold, design: .rounded),
                                color: Color.white.opacity(0.90),
                                height: 16
                            )
                            Text("used")
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 2)

                        HStack(spacing: 4) {
                            Text("today: \(UsageParser.formatSoft(status.todayLeft)) left")
                                .foregroundStyle(Color.white.opacity(0.88))
                            if status.todayOverrun > 0.05 {
                                Text("\(UsageParser.formatOverrun(status.todayOverrun)) above")
                                    .foregroundStyle(Color(hex: 0xFF8B82))
                            }
                        }
                        .font(.system(size: 9.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                        Spacer(minLength: 2)

                        // Right: Delta Pill
                        if let firstDelta = snap.recentDeltas.first {
                            MiniDeltaPill(delta: firstDelta, service: subStore.service, onOpenSessionHistory: onOpenSessionHistory)
                                .id(firstDelta.id)
                                .transition(
                                    .asymmetric(
                                        insertion: .offset(y: -8).combined(with: .scale(scale: 0.70)).combined(with: .opacity),
                                        removal: .offset(x: 35).combined(with: .scale(scale: 0.70)).combined(with: .opacity)
                                    )
                                )
                                .animation(.spring(response: 0.42, dampingFraction: 0.72), value: firstDelta.id)
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            subStore.toggleCollapse()
                        }
                    }
                } else {
                    // Full expanded card
                    VStack(alignment: .leading, spacing: 2) {
                        // Top row: Big % and Deltas
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(alignment: .firstTextBaseline, spacing: 3) {
                                    RollingWheelNumberView(
                                        value: Int(snap.totalPercent.rounded()),
                                        font: .system(size: snap.totalPercent >= 99.5 ? 20 : 22, weight: .semibold, design: .rounded),
                                        color: Color.white.opacity(0.86),
                                        height: 27
                                    )
                                    Text("used")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.62))
                                }
                                .fixedSize(horizontal: true, vertical: false)
                                if let reset = snap.resetsAt {
                                    let parts = UsageParser.remainingParts(until: reset, now: now)
                                    let accent = UsageParser.resetCountdownColor(until: reset, now: now)
                                    let muted = Color.white.opacity(0.62)
                                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                                        Text("Resets in")
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .foregroundStyle(muted)
                                        if let days = parts.days {
                                            Text(days)
                                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                                                .foregroundStyle(accent)
                                                .monospacedDigit()
                                            Text(parts.rest)
                                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                                .foregroundStyle(muted)
                                                .monospacedDigit()
                                        } else {
                                            Text(parts.rest)
                                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                                .foregroundStyle(accent)
                                                .monospacedDigit()
                                        }
                                    }
                                    .fixedSize(horizontal: true, vertical: false)
                                    Text(UsageParser.formatResetOn(reset))
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.5))
                                        .fixedSize(horizontal: true, vertical: false)
                                } else {
                                    Text(snap.resetsLabel)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Color.white.opacity(0.72))
                                }
                            }

                            Spacer(minLength: 2)

                            if !snap.recentDeltas.isEmpty {
                                DeltasStackView(deltas: snap.recentDeltas, now: now, service: subStore.service, onOpenSessionHistory: onOpenSessionHistory)
                            }
                        }

                        // Quota Progress Bar (AGY, Grok Bot, Grok, Claude & GPT)
                        let showsFive = subStore.service.showsFiveHour && snap.fiveHourPercent != nil
                        let resetGain = subStore.currentWeekResetGain(now: wallNow, resetsAt: snap.resetsAt)
                        BlueQuotaProgressBar(usedPercent: snap.totalPercent, gainPercent: resetGain)
                            .padding(.top, showsFive ? 2 : 1)
                            .padding(.bottom, showsFive ? 2.0 : (isWeekHidden ? 2 : 6))

                        if isWeekHidden && !showsFive {
                            HStack {
                                Spacer(minLength: 0)
                                weekStripToggle
                            }
                            .padding(.top, -1)
                            .padding(.bottom, -2)
                            .frame(height: 14)
                        }

                        if showsFive, let fivePct = snap.fiveHourPercent {
                            let fiveScale: CGFloat = isWeekHidden ? 1 : 1.2
                            HStack(spacing: 3) {
                                Text("5h: \(Int(fivePct.rounded()))% used")
                                    .font(.system(size: 9.5 * fiveScale, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.90))
                                    .monospacedDigit()
                                if let fiveReset = snap.fiveHourResetsAt {
                                    let fParts = UsageParser.remainingParts(until: fiveReset, now: now)
                                    let fAccent = UsageParser.fiveHourCountdownColor(until: fiveReset, now: now)
                                    Text("· reset in")
                                        .font(.system(size: 9 * fiveScale, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.55))
                                    Text(fParts.rest)
                                        .font(.system(size: 9.5 * fiveScale, weight: .bold, design: .rounded))
                                        .foregroundStyle(fAccent)
                                        .monospacedDigit()
                                }
                                Spacer(minLength: 4)
                                if isWeekHidden { weekStripToggle }
                            }
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .padding(.vertical, 1.5)
                        }

                        if !isWeekHidden {
                            let weekDays = subStore.daysForDisplay(now: wallNow, resetsAt: snap.resetsAt)
                            WeekStripView(days: weekDays, todayKey: todayKey, resetAt: snap.resetsAt, onOpenCalendar: onOpenCalendar)
                                .padding(.top, showsFive ? 0 : 4)
                                .padding(.horizontal, 4)
                                .overlay(alignment: .topTrailing) {
                                    weekStripToggle
                                        .offset(x: 6, y: showsFive ? -11 : -6)
                                }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("today: \(UsageParser.formatSoft(status.todayLeft)) left")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.92))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                if status.todayOverrun > 0.05 {
                                    Text("\(UsageParser.formatOverrun(status.todayOverrun)) above")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Color(hex: 0xFF8B82))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                Spacer(minLength: 0)
                            }
                            HStack {
                                Spacer(minLength: 0)
                                Button(action: { onRefresh?() }) {
                                    Text(UsageParser.lastRefreshed(snap.fetchedAt, now: now))
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.42))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .buttonStyle(.plain)
                                .help("Click to refresh now")
                            }
                        }
                        .padding(.top, isWeekHidden ? 0 : 5)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                subStore.toggleCollapse()
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 5)
        .padding(.bottom, 6)
        .frame(width: 198)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(hex: 0x1C1C1E).opacity(0.48))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.55), radius: 8, y: 3)
        .onAppear {
            isWeekHidden = UserDefaults.standard.bool(forKey: subStore.service.hideWeekStripKey)
        }
    }

    private var weekStripToggle: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                isWeekHidden.toggle()
                UserDefaults.standard.set(isWeekHidden, forKey: subStore.service.hideWeekStripKey)
            }
        }) {
            Image(systemName: isWeekHidden ? "chevron.down" : "chevron.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(width: 32, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isWeekHidden ? "Show 7-day strip" : "Hide 7-day strip")
    }
}

// MARK: - Sessions, Window Grouping & Calendar Popup

enum SessionIntensity: String, CaseIterable {
    case high
    case moderate
    case singleQuery

    var label: String {
        switch self {
        case .high: return "High Intensity"
        case .moderate: return "Work Session"
        case .singleQuery: return "Single Query"
        }
    }

    var icon: String {
        switch self {
        case .high: return "flame.fill"
        case .moderate: return "bolt.fill"
        case .singleQuery: return "bubble.left.fill"
        }
    }

    var color: Color {
        switch self {
        case .high: return Color(hex: 0xFF5722)
        case .moderate: return Color(hex: 0x24C1E0)
        case .singleQuery: return Color(hex: 0x94A3B8)
        }
    }
}

enum SessionGroupingMode: Int, CaseIterable, Identifiable {
    case auto = 0
    case oneHour = 1
    case threeHours = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .auto: return "⚡ Auto Sessions"
        case .oneHour: return "⏱️ 1h Windows"
        case .threeHours: return "🕒 3h Windows"
        }
    }
}

struct UsageSession: Identifiable, Equatable {
    let id: String
    let title: String
    let dayLabel: String
    let isToday: Bool
    let isYesterday: Bool
    let sessionNumber: Int
    let startTime: Date
    let endTime: Date
    let totalDelta: Double
    let records: [SessionDeltaRecord]
    let mode: SessionGroupingMode
    let isSession: Bool

    var duration: TimeInterval {
        max(0, endTime.timeIntervalSince(startTime))
    }

    var durationFormatted: String {
        if !isSession || duration < 60 {
            return records.count == 1 ? "1 prompt" : "\(records.count) prompts"
        }
        let mins = Int(round(duration / 60.0))
        let h = mins / 60
        let m = mins % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    var timeRangeFormatted: String {
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        if !isSession || records.count <= 1 || duration < 60 {
            return df.string(from: startTime)
        }
        return "\(df.string(from: startTime)) – \(df.string(from: endTime))"
    }

    var intensity: SessionIntensity {
        if !isSession {
            return .singleQuery
        }
        if totalDelta >= 3.0 || records.count >= 15 {
            return .high
        } else {
            return .moderate
        }
    }
}

enum SessionGrouper {
    static func group(
        records: [SessionDeltaRecord],
        mode: SessionGroupingMode,
        calendar cal: Calendar = Calendar.current
    ) -> [UsageSession] {
        guard !records.isEmpty else { return [] }
        let ascending = records.sorted { $0.timestamp < $1.timestamp }

        switch mode {
        case .auto:
            return groupAuto(ascending: ascending, calendar: cal)
        case .oneHour:
            return groupOneHour(ascending: ascending, calendar: cal)
        case .threeHours:
            return groupThreeHours(ascending: ascending, calendar: cal)
        }
    }

    private static func groupAuto(ascending: [SessionDeltaRecord], calendar cal: Calendar) -> [UsageSession] {
        var clusters: [[SessionDeltaRecord]] = []
        var cur: [SessionDeltaRecord] = []

        for r in ascending {
            if let last = cur.last {
                let gap = r.timestamp - last.timestamp
                let lastDate = Date(timeIntervalSince1970: last.timestamp)
                let curDate = Date(timeIntervalSince1970: r.timestamp)
                let isSameDay = cal.isDate(lastDate, inSameDayAs: curDate)

                if gap >= 2100 || !isSameDay {
                    clusters.append(cur)
                    cur = [r]
                } else {
                    cur.append(r)
                }
            } else {
                cur.append(r)
            }
        }
        if !cur.isEmpty { clusters.append(cur) }

        var dayClusters: [Date: [[SessionDeltaRecord]]] = [:]
        for c in clusters {
            guard let first = c.first else { continue }
            let d = Date(timeIntervalSince1970: first.timestamp)
            let dayStart = cal.startOfDay(for: d)
            dayClusters[dayStart, default: []].append(c)
        }

        var sessions: [UsageSession] = []
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "EEE, MMM d"

        for (dayStart, list) in dayClusters {
            let isToday = cal.isDateInToday(dayStart)
            let isYesterday = cal.isDateInYesterday(dayStart)
            let dayLabel = isToday ? "Today" : (isYesterday ? "Yesterday" : dayFmt.string(from: dayStart))

            var sessionCounter = 0
            for c in list {
                guard let first = c.first, let last = c.last else { continue }
                let start = Date(timeIntervalSince1970: first.timestamp)
                let end = Date(timeIntervalSince1970: last.timestamp)
                let total = c.reduce(0.0) { $0 + $1.weeklyDelta }
                let durationMins = Int(round((last.timestamp - first.timestamp) / 60.0))

                // Condition: More than 2 prompts close to each other (or 2 prompts in quick succession <= 10m)
                let isSession = c.count > 2 || (c.count == 2 && durationMins <= 10)

                let title: String
                let sessNum: Int
                if isSession {
                    sessionCounter += 1
                    sessNum = sessionCounter
                    title = "Session \(sessNum)"
                } else {
                    sessNum = 0
                    title = c.count == 1 ? "Single Query" : "Quick Queries (\(c.count))"
                }

                let session = UsageSession(
                    id: "auto-\(Int(first.timestamp))",
                    title: title,
                    dayLabel: dayLabel,
                    isToday: isToday,
                    isYesterday: isYesterday,
                    sessionNumber: sessNum,
                    startTime: start,
                    endTime: end,
                    totalDelta: total,
                    records: c.reversed(),
                    mode: .auto,
                    isSession: isSession
                )
                sessions.append(session)
            }
        }

        return sessions.sorted { $0.startTime > $1.startTime }
    }

    private static func groupOneHour(ascending: [SessionDeltaRecord], calendar cal: Calendar) -> [UsageSession] {
        let buckets = Dictionary(grouping: ascending) { r -> Date in
            let d = Date(timeIntervalSince1970: r.timestamp)
            return cal.dateInterval(of: .hour, for: d)?.start ?? d
        }

        var sessions: [UsageSession] = []
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "EEE, MMM d"

        for (hourStart, records) in buckets {
            guard !records.isEmpty else { continue }
            let sortedBucket = records.sorted { $0.timestamp < $1.timestamp }
            guard let first = sortedBucket.first, let last = sortedBucket.last else { continue }

            let hourEnd = cal.date(byAdding: .hour, value: 1, to: hourStart) ?? hourStart
            let actualStart = Date(timeIntervalSince1970: first.timestamp)
            let actualEnd = Date(timeIntervalSince1970: last.timestamp)
            let total = sortedBucket.reduce(0.0) { $0 + $1.weeklyDelta }
            let durationMins = Int(round((last.timestamp - first.timestamp) / 60.0))

            // One usage in an hour is NOT a session!
            let isSession = sortedBucket.count > 2 || (sortedBucket.count == 2 && durationMins <= 10)

            let dayStart = cal.startOfDay(for: hourStart)
            let isToday = cal.isDateInToday(dayStart)
            let isYesterday = cal.isDateInYesterday(dayStart)
            let dayLabel = isToday ? "Today" : (isYesterday ? "Yesterday" : dayFmt.string(from: dayStart))

            let title = "\(timeFmt.string(from: hourStart)) – \(timeFmt.string(from: hourEnd))"

            let session = UsageSession(
                id: "1h-\(Int(hourStart.timeIntervalSince1970))",
                title: title,
                dayLabel: dayLabel,
                isToday: isToday,
                isYesterday: isYesterday,
                sessionNumber: 0,
                startTime: actualStart,
                endTime: actualEnd,
                totalDelta: total,
                records: sortedBucket.reversed(),
                mode: .oneHour,
                isSession: isSession
            )
            sessions.append(session)
        }

        return sessions.sorted { $0.startTime > $1.startTime }
    }

    private static func groupThreeHours(ascending: [SessionDeltaRecord], calendar cal: Calendar) -> [UsageSession] {
        let buckets = Dictionary(grouping: ascending) { r -> Date in
            let d = Date(timeIntervalSince1970: r.timestamp)
            let hour = cal.component(.hour, from: d)
            let blockHour = (hour / 3) * 3
            var comps = cal.dateComponents([.year, .month, .day], from: d)
            comps.hour = blockHour
            comps.minute = 0
            comps.second = 0
            return cal.date(from: comps) ?? d
        }

        var sessions: [UsageSession] = []
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "EEE, MMM d"

        for (threeHourStart, records) in buckets {
            guard !records.isEmpty else { continue }
            let sortedBucket = records.sorted { $0.timestamp < $1.timestamp }
            guard let first = sortedBucket.first, let last = sortedBucket.last else { continue }

            let threeHourEnd = cal.date(byAdding: .hour, value: 3, to: threeHourStart) ?? threeHourStart
            let actualStart = Date(timeIntervalSince1970: first.timestamp)
            let actualEnd = Date(timeIntervalSince1970: last.timestamp)
            let total = sortedBucket.reduce(0.0) { $0 + $1.weeklyDelta }
            let durationMins = Int(round((last.timestamp - first.timestamp) / 60.0))

            let isSession = sortedBucket.count > 2 || (sortedBucket.count == 2 && durationMins <= 10)

            let dayStart = cal.startOfDay(for: threeHourStart)
            let isToday = cal.isDateInToday(dayStart)
            let isYesterday = cal.isDateInYesterday(dayStart)
            let dayLabel = isToday ? "Today" : (isYesterday ? "Yesterday" : dayFmt.string(from: dayStart))

            let title = "\(timeFmt.string(from: threeHourStart)) – \(timeFmt.string(from: threeHourEnd))"

            let session = UsageSession(
                id: "3h-\(Int(threeHourStart.timeIntervalSince1970))",
                title: title,
                dayLabel: dayLabel,
                isToday: isToday,
                isYesterday: isYesterday,
                sessionNumber: 0,
                startTime: actualStart,
                endTime: actualEnd,
                totalDelta: total,
                records: sortedBucket.reversed(),
                mode: .threeHours,
                isSession: isSession
            )
            sessions.append(session)
        }

        return sessions.sorted { $0.startTime > $1.startTime }
    }
}

// MARK: - Interactive Usage Graph Engine & Models

enum GraphTimeframe: String, CaseIterable, Identifiable {
    case day = "Day (24h)"
    case week = "Week (7d)"
    case month = "Month (30d)"

    var id: String { rawValue }
    var title: String { rawValue }
}

struct HourlyUsageBin: Identifiable, Equatable {
    var id: Int { hour }
    let hour: Int
    let hourLabel: String
    let fullHourLabel: String
    let timeRange: String
    let delta: Double
    let promptCount: Int
    let cumulativeDelta: Double
    let isCurrentHour: Bool
    let isFutureHour: Bool
    let isPeakHour: Bool
    let records: [SessionDeltaRecord]
}

struct TodayGraphData {
    let targetDate: Date
    let isToday: Bool
    let bins: [HourlyUsageBin]
    let totalDelta: Double
    let totalPrompts: Int
    let activeHoursCount: Int
    let peakBin: HourlyUsageBin?
    let maxHourDelta: Double
    let allDayRecords: [SessionDeltaRecord]
}

enum TodayGraphEngine {
    static func compute(
        records: [SessionDeltaRecord],
        targetDate: Date,
        calendar: Calendar = Calendar.current
    ) -> TodayGraphData {
        let isToday = calendar.isDateInToday(targetDate)
        let now = Date()
        let currentHour = calendar.component(.hour, from: now)

        let dayRecords = records.filter { rec in
            let d = Date(timeIntervalSince1970: rec.timestamp)
            return calendar.isDate(d, inSameDayAs: targetDate)
        }

        var hourMap: [Int: [SessionDeltaRecord]] = [:]
        for h in 0...23 { hourMap[h] = [] }
        for rec in dayRecords {
            let d = Date(timeIntervalSince1970: rec.timestamp)
            let h = calendar.component(.hour, from: d)
            if h >= 0 && h <= 23 {
                hourMap[h]?.append(rec)
            }
        }

        var maxDelta: Double = 0.0
        for h in 0...23 {
            let sum = hourMap[h]?.reduce(0.0) { $0 + $1.weeklyDelta } ?? 0.0
            if sum > maxDelta { maxDelta = sum }
        }

        var runningCumulative: Double = 0.0
        var totalDelta: Double = 0.0
        var totalPrompts: Int = 0
        var activeHoursCount: Int = 0
        var bins: [HourlyUsageBin] = []
        var peakBin: HourlyUsageBin? = nil

        for h in 0...23 {
            let hourRecs = hourMap[h] ?? []
            let sortedNewestFirst = hourRecs.sorted { $0.timestamp > $1.timestamp }
            let binDelta = sortedNewestFirst.reduce(0.0) { $0 + $1.weeklyDelta }
            runningCumulative += binDelta
            totalDelta += binDelta
            totalPrompts += sortedNewestFirst.count
            if !sortedNewestFirst.isEmpty {
                activeHoursCount += 1
            }

            let isCurrent = isToday && (h == currentHour)
            let isFuture = isToday && (h > currentHour)
            let isPeak = maxDelta > 0.005 && abs(binDelta - maxDelta) < 0.0001

            let displayH = h % 12 == 0 ? 12 : h % 12
            let amPm = h < 12 ? "AM" : "PM"
            let shortAmPm = h < 12 ? "a" : "p"
            let nextH = (h + 1) % 24
            let nextDisplayH = nextH % 12 == 0 ? 12 : nextH % 12
            let nextAmPm = nextH < 12 ? "AM" : "PM"

            let shortLabel = "\(displayH)\(shortAmPm)"
            let fullLabel = "\(displayH) \(amPm)"
            let rangeLabel = "\(displayH):00 \(amPm) – \(nextDisplayH):00 \(nextAmPm)"

            let bin = HourlyUsageBin(
                hour: h,
                hourLabel: shortLabel,
                fullHourLabel: fullLabel,
                timeRange: rangeLabel,
                delta: binDelta,
                promptCount: sortedNewestFirst.count,
                cumulativeDelta: runningCumulative,
                isCurrentHour: isCurrent,
                isFutureHour: isFuture,
                isPeakHour: isPeak,
                records: sortedNewestFirst
            )
            bins.append(bin)
            if isPeak && (peakBin == nil || bin.delta > (peakBin?.delta ?? 0)) {
                peakBin = bin
            }
        }

        let allDaySorted = dayRecords.sorted { $0.timestamp > $1.timestamp }
        return TodayGraphData(
            targetDate: targetDate,
            isToday: isToday,
            bins: bins,
            totalDelta: totalDelta,
            totalPrompts: totalPrompts,
            activeHoursCount: activeHoursCount,
            peakBin: peakBin,
            maxHourDelta: max(0.1, maxDelta),
            allDayRecords: allDaySorted
        )
    }
}

// MARK: - Weekly & Monthly Graph Engine & Models

struct DailyUsageBin: Identifiable, Equatable {
    var id: String { dateKey }
    let dateKey: String
    let dayLabel: String
    let fullDateLabel: String
    let dayNumber: Int
    let delta: Double
    let promptCount: Int
    let cumulativeDelta: Double
    let isToday: Bool
    let isFuture: Bool
    let isPeakDay: Bool
    let records: [SessionDeltaRecord]
}

struct WeeklyGraphData {
    let weekStart: Date
    let weekEnd: Date
    let weekLabel: String
    let isCurrentWeek: Bool
    let bins: [DailyUsageBin]
    let totalDelta: Double
    let totalPrompts: Int
    let activeDaysCount: Int
    let peakBin: DailyUsageBin?
    let maxDayDelta: Double
    let allWeekRecords: [SessionDeltaRecord]
}

enum WeeklyGraphEngine {
    static func compute(
        records: [SessionDeltaRecord],
        subStore: SingleServiceStore,
        weekOffset: Int,
        calendar cal: Calendar = Calendar.current
    ) -> WeeklyGraphData {
        let now = Date()
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today)
        let isoMondayOffset = (weekday + 5) % 7
        let currentMonday = cal.date(byAdding: .day, value: -isoMondayOffset, to: today) ?? today
        let targetMonday = cal.date(byAdding: .day, value: weekOffset * 7, to: currentMonday) ?? currentMonday
        let targetSunday = cal.date(byAdding: .day, value: 6, to: targetMonday) ?? targetMonday

        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let shortFmt = DateFormatter()
        shortFmt.dateFormat = "MMM d"
        let fullFmt = DateFormatter()
        fullFmt.dateFormat = "EEEE, MMM d"

        var dayMap: [String: [SessionDeltaRecord]] = [:]
        for rec in records {
            let d = Date(timeIntervalSince1970: rec.timestamp)
            let k = fmt.string(from: d)
            dayMap[k, default: []].append(rec)
        }

        var maxDelta: Double = 0.0
        for i in 0..<7 {
            guard let d = cal.date(byAdding: .day, value: i, to: targetMonday) else { continue }
            let k = fmt.string(from: d)
            let recs = dayMap[k] ?? []
            let promptSum = recs.reduce(0.0) { $0 + $1.weeklyDelta }
            let dailyMapUsage = subStore.usedPercent(on: k)
            let used = max(dailyMapUsage, promptSum)
            if used > maxDelta { maxDelta = used }
        }

        var runningCumulative: Double = 0.0
        var totalDelta: Double = 0.0
        var totalPrompts: Int = 0
        var activeDaysCount: Int = 0
        var bins: [DailyUsageBin] = []
        var peakBin: DailyUsageBin? = nil
        var allWeekRecs: [SessionDeltaRecord] = []

        for i in 0..<7 {
            guard let d = cal.date(byAdding: .day, value: i, to: targetMonday) else { continue }
            let k = fmt.string(from: d)
            let recs = (dayMap[k] ?? []).sorted { $0.timestamp > $1.timestamp }
            allWeekRecs.append(contentsOf: recs)
            let promptSum = recs.reduce(0.0) { $0 + $1.weeklyDelta }
            let dailyMapUsage = subStore.usedPercent(on: k)
            let dayUsage = max(dailyMapUsage, promptSum)

            runningCumulative += dayUsage
            totalDelta += dayUsage
            totalPrompts += recs.count
            if dayUsage > 0.005 || !recs.isEmpty {
                activeDaysCount += 1
            }

            let isToday = cal.isDateInToday(d)
            let isFuture = cal.startOfDay(for: d) > today
            let isPeak = maxDelta > 0.005 && abs(dayUsage - maxDelta) < 0.0001
            let dayNum = cal.component(.day, from: d)

            let bin = DailyUsageBin(
                dateKey: k,
                dayLabel: dayLabels[i],
                fullDateLabel: fullFmt.string(from: d),
                dayNumber: dayNum,
                delta: dayUsage,
                promptCount: recs.count,
                cumulativeDelta: runningCumulative,
                isToday: isToday,
                isFuture: isFuture,
                isPeakDay: isPeak,
                records: recs
            )
            bins.append(bin)
            if isPeak && (peakBin == nil || bin.delta > (peakBin?.delta ?? 0)) {
                peakBin = bin
            }
        }

        let weekLabelStr = "\(shortFmt.string(from: targetMonday)) – \(shortFmt.string(from: targetSunday)), \(cal.component(.year, from: targetMonday))"

        return WeeklyGraphData(
            weekStart: targetMonday,
            weekEnd: targetSunday,
            weekLabel: weekLabelStr,
            isCurrentWeek: weekOffset == 0,
            bins: bins,
            totalDelta: totalDelta,
            totalPrompts: totalPrompts,
            activeDaysCount: activeDaysCount,
            peakBin: peakBin,
            maxDayDelta: max(0.1, maxDelta),
            allWeekRecords: allWeekRecs.sorted { $0.timestamp > $1.timestamp }
        )
    }
}

struct MonthlyGraphData {
    let monthStart: Date
    let monthEnd: Date
    let monthLabel: String
    let isCurrentMonth: Bool
    let bins: [DailyUsageBin]
    let totalDelta: Double
    let totalPrompts: Int
    let activeDaysCount: Int
    let peakBin: DailyUsageBin?
    let maxDayDelta: Double
    let allMonthRecords: [SessionDeltaRecord]
}

enum MonthlyGraphEngine {
    static func compute(
        records: [SessionDeltaRecord],
        subStore: SingleServiceStore,
        monthOffset: Int,
        calendar cal: Calendar = Calendar.current
    ) -> MonthlyGraphData {
        let now = Date()
        let today = cal.startOfDay(for: now)
        let targetMonthDate = cal.date(byAdding: .month, value: monthOffset, to: now) ?? now
        let comps = cal.dateComponents([.year, .month], from: targetMonthDate)
        let monthStart = cal.date(from: comps) ?? targetMonthDate
        let daysCount = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let monthEnd = cal.date(byAdding: .day, value: daysCount, to: monthStart) ?? monthStart

        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        let dayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let fullFmt = DateFormatter()
        fullFmt.dateFormat = "EEEE, MMM d"
        let monthTitleFmt = DateFormatter()
        monthTitleFmt.dateFormat = "MMMM yyyy"

        var dayMap: [String: [SessionDeltaRecord]] = [:]
        for rec in records {
            let d = Date(timeIntervalSince1970: rec.timestamp)
            let k = fmt.string(from: d)
            dayMap[k, default: []].append(rec)
        }

        var maxDelta: Double = 0.0
        for day in 1...daysCount {
            guard let d = cal.date(byAdding: .day, value: day - 1, to: monthStart) else { continue }
            let k = fmt.string(from: d)
            let recs = dayMap[k] ?? []
            let promptSum = recs.reduce(0.0) { $0 + $1.weeklyDelta }
            let dailyMapUsage = subStore.usedPercent(on: k)
            let used = max(dailyMapUsage, promptSum)
            if used > maxDelta { maxDelta = used }
        }

        var runningCumulative: Double = 0.0
        var totalDelta: Double = 0.0
        var totalPrompts: Int = 0
        var activeDaysCount: Int = 0
        var bins: [DailyUsageBin] = []
        var peakBin: DailyUsageBin? = nil
        var allMonthRecs: [SessionDeltaRecord] = []

        for day in 1...daysCount {
            guard let d = cal.date(byAdding: .day, value: day - 1, to: monthStart) else { continue }
            let k = fmt.string(from: d)
            let recs = (dayMap[k] ?? []).sorted { $0.timestamp > $1.timestamp }
            allMonthRecs.append(contentsOf: recs)
            let promptSum = recs.reduce(0.0) { $0 + $1.weeklyDelta }
            let dailyMapUsage = subStore.usedPercent(on: k)
            let dayUsage = max(dailyMapUsage, promptSum)

            runningCumulative += dayUsage
            totalDelta += dayUsage
            totalPrompts += recs.count
            if dayUsage > 0.005 || !recs.isEmpty {
                activeDaysCount += 1
            }

            let isToday = cal.isDateInToday(d)
            let isFuture = cal.startOfDay(for: d) > today
            let isPeak = maxDelta > 0.005 && abs(dayUsage - maxDelta) < 0.0001
            let weekdayIdx = cal.component(.weekday, from: d) - 1
            let label = (weekdayIdx >= 0 && weekdayIdx < 7) ? dayLabels[weekdayIdx] : ""

            let bin = DailyUsageBin(
                dateKey: k,
                dayLabel: label,
                fullDateLabel: fullFmt.string(from: d),
                dayNumber: day,
                delta: dayUsage,
                promptCount: recs.count,
                cumulativeDelta: runningCumulative,
                isToday: isToday,
                isFuture: isFuture,
                isPeakDay: isPeak,
                records: recs
            )
            bins.append(bin)
            if isPeak && (peakBin == nil || bin.delta > (peakBin?.delta ?? 0)) {
                peakBin = bin
            }
        }

        return MonthlyGraphData(
            monthStart: monthStart,
            monthEnd: monthEnd,
            monthLabel: monthTitleFmt.string(from: monthStart),
            isCurrentMonth: monthOffset == 0,
            bins: bins,
            totalDelta: totalDelta,
            totalPrompts: totalPrompts,
            activeDaysCount: activeDaysCount,
            peakBin: peakBin,
            maxDayDelta: max(0.1, maxDelta),
            allMonthRecords: allMonthRecs.sorted { $0.timestamp > $1.timestamp }
        )
    }
}

struct YearCalendarView: View {
    let serviceName: String
    @ObservedObject var subStore: SingleServiceStore
    var year: Int
    var initialTab: Int = 0
    var onClose: () -> Void

    private var isClaudeGPT: Bool { subStore.service == .claudeGPT }

    @State private var selectedTab: Int = 0
    @State private var groupingMode: SessionGroupingMode = .auto
    @State private var filterOnlySessions: Bool = false
    @State private var expandedSessionIds: Set<String> = []

    // Interactive Graphs States
    @State private var selectedTimeframe: GraphTimeframe = .day
    @State private var dayOffset: Int = 0
    @State private var weekOffset: Int = 0
    @State private var monthOffset: Int = 0

    @State private var hoveredHour: Int? = nil
    @State private var selectedHour: Int? = nil

    @State private var hoveredDayKey: String? = nil
    @State private var selectedDayKey: String? = nil

    // Quota Resets State
    @State private var isAddingManualReset: Bool = false
    @State private var newResetDateStr: String = ""
    @State private var newResetGainStr: String = "100.0"
    @State private var newResetTitle: String = "Google Manual Reset"
    @State private var newResetNote: String = "Manual quota refresh from Google"

    init(serviceName: String, subStore: SingleServiceStore, year: Int, initialTab: Int = 0, onClose: @escaping () -> Void) {
        self.serviceName = serviceName
        self.subStore = subStore
        self.year = year
        self.initialTab = initialTab
        self.onClose = onClose
        self._selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        let cal = Calendar.current
        let yearUsed = yearSum()
        let records = subStore.loadAllSessionDeltas()
        let sessions = SessionGrouper.group(records: records, mode: groupingMode, calendar: cal)
        let totalDeltas = records.reduce(0.0) { $0 + $1.weeklyDelta }
        let targetDate = cal.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
        let todayData = TodayGraphEngine.compute(records: records, targetDate: targetDate, calendar: cal)
        let weeklyData = WeeklyGraphEngine.compute(records: records, subStore: subStore, weekOffset: weekOffset, calendar: cal)
        let monthlyData = MonthlyGraphEngine.compute(records: records, subStore: subStore, monthOffset: monthOffset, calendar: cal)

        VStack(alignment: .leading, spacing: 10) {
            // Header Bar
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    Text(serviceName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.95))
                    if isClaudeGPT {
                        Text("3rd-Party Group")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(hex: 0xF28B82))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color(hex: 0xF28B82).opacity(0.18)))
                    }
                }
                .padding(.trailing, 4)

                Picker("", selection: $selectedTab) {
                    Text(isClaudeGPT ? "📊 Graphs" : "📊 Graphs").tag(0)
                    Text("⚡ Sessions").tag(1)
                    Text("📅 Calendar").tag(2)
                    Text("🔄 Resets").tag(4)
                    Text("📋 Prompts (\(records.count))").tag(3)
                }
                .pickerStyle(.segmented)
                .frame(width: 480)

                Spacer()

                if selectedTab == 2 {
                    Text("year \(PctFmt.total(yearUsed))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .monospacedDigit()
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            // Tab Content
            if selectedTab == 0 {
                interactiveGraphsView(todayData: todayData, weeklyData: weeklyData, monthlyData: monthlyData)
            } else if selectedTab == 1 {
                sessionsView(sessions: sessions, totalRecorded: totalDeltas)
            } else if selectedTab == 2 {
                calendarTabView(cal: cal)
            } else if selectedTab == 4 {
                resetsTabView(cal: cal)
            } else {
                promptActivityView(records: records, totalDeltas: totalDeltas)
            }
        }
        .padding(14)
        .frame(width: 632, height: 652)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: 0x1C1C1E).opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
    }

    // MARK: - Interactive Usage Graphs (Day, Week, Month)

    private func resetsQuickBanner() -> some View {
        let resets = subStore.loadQuotaResets()
        let manualCount = resets.filter { $0.type == "manual" || $0.type == "intraweek" }.count
        let latest = resets.first

        return HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(hex: 0xF59E0B))

            if let last = latest {
                Text("Last Reset: \(last.dateStr) (\(last.displayTitle))")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))

                Text("•")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.white.opacity(0.3))

                Text(String(format: "+%.1f%% Bonus Logged", last.gainedPercent))
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: 0xF59E0B))
            } else {
                Text("Past Quota Resets Ledger")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.80))
            }

            Spacer()

            Button(action: { selectedTab = 4 }) {
                HStack(spacing: 3) {
                    Text("Resets History (\(resets.count))")
                        .font(.system(size: 9, weight: .bold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .bold))
                }
                .foregroundStyle(Color(hex: 0xF59E0B))
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(hex: 0xF59E0B).opacity(0.14))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.8)
                )
        )
    }

    private func resetsTabView(cal: Calendar) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                quotaResetsCard(cal: cal)

                VStack(alignment: .leading, spacing: 6) {
                    Text("RECORDED QUOTA RESETS STORAGE")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.60))

                    Text("• This ledger only logs actual resets that have already occurred.\n• Because future manual resets are unpredictable and not guaranteed on a fixed schedule, upcoming dates are not estimated.\n• When Google grants a manual quota refresh or mid-week reset, it is stored here to track the bonus quota capacity gained.\n• You can log or adjust any previous reset at any time using 'Log Reset'.")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.50))
                        .lineSpacing(3)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.025))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.05), lineWidth: 0.8)
                        )
                )
            }
            .padding(.bottom, 12)
        }
    }

    private func interactiveGraphsView(
        todayData: TodayGraphData,
        weeklyData: WeeklyGraphData,
        monthlyData: MonthlyGraphData
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            resetsQuickBanner()

            if isClaudeGPT, case .ready(let snap) = subStore.state {
                claudeGPTQuotaHeroBanner(snap: snap)
            }

            // Unified Timeframe Switcher & Period Controls
            timeframeControlBar(todayData: todayData, weeklyData: weeklyData, monthlyData: monthlyData)

            if selectedTimeframe == .day {
                todayStatsBanner(data: todayData)
                todayHourlyBarChart(data: todayData)
                inspectorHudBanner(data: todayData)
                todayPromptsList(data: todayData)
            } else if selectedTimeframe == .week {
                weeklyStatsBanner(data: weeklyData)
                weeklyBarChart(data: weeklyData)
                weeklyInspectorHudBanner(data: weeklyData)
                weeklyPromptsList(data: weeklyData)
            } else {
                monthlyStatsBanner(data: monthlyData)
                monthlyBarChart(data: monthlyData)
                monthlyInspectorHudBanner(data: monthlyData)
                monthlyPromptsList(data: monthlyData)
            }
        }
    }

    private func claudeGPTQuotaHeroBanner(snap: UsageSnapshot) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                // Weekly Limit Card
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("WEEKLY 3RD-PARTY QUOTA")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.60))
                        Spacer()
                        Text(String(format: "%.1f%% used", snap.totalPercent))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(hex: 0xF28B82))
                            .monospacedDigit()
                    }

                    // Progress bar
                    GeometryReader { geo in
                        let w = geo.size.width
                        let fillW = max(3, min(w, (snap.totalPercent / 100.0) * w))
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.10)).frame(height: 5)
                            Capsule()
                                .fill(LinearGradient(colors: [Color(hex: 0xF28B82), Color(hex: 0xFF9500)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: fillW, height: 5)
                        }
                    }
                    .frame(height: 5)

                    HStack {
                        if let r = snap.resetsAt {
                            let parts = UsageParser.remainingParts(until: r)
                            Text("Resets in \(parts.days != nil ? "\(parts.days!) " : "")\(parts.rest) · \(snap.resetsLabel)")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.48))
                        } else {
                            Text(snap.resetsLabel)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.48))
                        }
                        Spacer()
                        Text(String(format: "%.1f%% left", max(0, 100.0 - snap.totalPercent)))
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(hex: 0xF28B82).opacity(0.25), lineWidth: 0.8))
                )

                // 5-Hour Limit Card
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("5-HOUR ROLLING LIMIT")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.60))
                        Spacer()
                        if let fh = snap.fiveHourPercent {
                            Text(String(format: "%.1f%% used", fh))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(hex: 0xFF9500))
                                .monospacedDigit()
                        }
                    }

                    // Progress bar
                    GeometryReader { geo in
                        let w = geo.size.width
                        let val = snap.fiveHourPercent ?? 0
                        let fillW = max(3, min(w, (val / 100.0) * w))
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.10)).frame(height: 5)
                            Capsule()
                                .fill(LinearGradient(colors: [Color(hex: 0xFF9500), Color(hex: 0xFF5722)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: fillW, height: 5)
                        }
                    }
                    .frame(height: 5)

                    HStack {
                        if let r = snap.fiveHourResetsAt {
                            let parts = UsageParser.remainingParts(until: r)
                            Text("Resets in \(parts.rest) · \(snap.fiveHourResetsLabel ?? "")")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.48))
                        } else {
                            Text(snap.fiveHourResetsLabel ?? "Active window")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.48))
                        }
                        Spacer()
                        if let fh = snap.fiveHourPercent {
                            Text(String(format: "%.1f%% left", max(0, 100.0 - fh)))
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.72))
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(hex: 0xFF9500).opacity(0.25), lineWidth: 0.8))
                )
            }

            // Models Included strip
            HStack(spacing: 5) {
                Text("MODELS:")
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.40))

                ForEach(UsageParser.claudeGPTModels, id: \.self) { m in
                    let isGpt = m.contains("GPT")
                    let c = isGpt ? Color(hex: 0x34A853) : Color(hex: 0xF28B82)
                    HStack(spacing: 2.5) {
                        Circle().fill(c).frame(width: 3.5, height: 3.5)
                        Text(m)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(c.opacity(0.14)))
                }

                Spacer()

                Text("Shared Proportional Quota")
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .padding(.horizontal, 2)
        }
        .padding(.bottom, 2)
    }

    private func timeframeControlBar(
        todayData: TodayGraphData,
        weeklyData: WeeklyGraphData,
        monthlyData: MonthlyGraphData
    ) -> some View {
        HStack(spacing: 8) {
            // Segmented picker for Day / Week / Month
            Picker("", selection: $selectedTimeframe) {
                ForEach(GraphTimeframe.allCases) { tf in
                    Text(tf.title).tag(tf)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 255)

            // Period Navigation Buttons
            HStack(spacing: 3) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        switch selectedTimeframe {
                        case .day:
                            dayOffset -= 1
                            selectedHour = nil
                            hoveredHour = nil
                        case .week:
                            weekOffset -= 1
                            selectedDayKey = nil
                            hoveredDayKey = nil
                        case .month:
                            monthOffset -= 1
                            selectedDayKey = nil
                            hoveredDayKey = nil
                        }
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        switch selectedTimeframe {
                        case .day:
                            dayOffset = 0
                            selectedHour = nil
                            hoveredHour = nil
                        case .week:
                            weekOffset = 0
                            selectedDayKey = nil
                            hoveredDayKey = nil
                        case .month:
                            monthOffset = 0
                            selectedDayKey = nil
                            hoveredDayKey = nil
                        }
                    }
                }) {
                    Text(currentPeriodLabel(todayData: todayData, weeklyData: weeklyData, monthlyData: monthlyData))
                        .font(.system(size: 10, weight: isCurrentPeriodActive ? .bold : .medium))
                        .foregroundStyle(isCurrentPeriodActive ? Color.white : Color.white.opacity(0.65))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isCurrentPeriodActive ? Color(hex: 0x24C1E0).opacity(0.20) : Color.white.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        switch selectedTimeframe {
                        case .day:
                            if dayOffset < 0 { dayOffset += 1 }
                            selectedHour = nil
                            hoveredHour = nil
                        case .week:
                            if weekOffset < 0 { weekOffset += 1 }
                            selectedDayKey = nil
                            hoveredDayKey = nil
                        case .month:
                            if monthOffset < 0 { monthOffset += 1 }
                            selectedDayKey = nil
                            hoveredDayKey = nil
                        }
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.white.opacity(isCurrentPeriodActive ? 0.25 : 0.65))
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(isCurrentPeriodActive)
            }

            // Descriptive date text
            Text(periodSubtitle(todayData: todayData, weeklyData: weeklyData, monthlyData: monthlyData))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.80))
                .lineLimit(1)

            Spacer()

            // Clear filter button
            if hasActiveFilter {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedHour = nil
                        hoveredHour = nil
                        selectedDayKey = nil
                        hoveredDayKey = nil
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .font(.system(size: 9))
                        Text("Clear Filter")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: 0x24C1E0))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(hex: 0x24C1E0).opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var hasActiveFilter: Bool {
        if selectedTimeframe == .day { return selectedHour != nil }
        return selectedDayKey != nil
    }

    private var isCurrentPeriodActive: Bool {
        switch selectedTimeframe {
        case .day: return dayOffset == 0
        case .week: return weekOffset == 0
        case .month: return monthOffset == 0
        }
    }

    private func currentPeriodLabel(
        todayData: TodayGraphData,
        weeklyData: WeeklyGraphData,
        monthlyData: MonthlyGraphData
    ) -> String {
        switch selectedTimeframe {
        case .day: return dayOffset == 0 ? "Today" : "Reset"
        case .week: return weekOffset == 0 ? "This Week" : "Reset"
        case .month: return monthOffset == 0 ? "This Month" : "Reset"
        }
    }

    private func periodSubtitle(
        todayData: TodayGraphData,
        weeklyData: WeeklyGraphData,
        monthlyData: MonthlyGraphData
    ) -> String {
        let df = DateFormatter()
        switch selectedTimeframe {
        case .day:
            df.dateFormat = "EEE, MMM d, yyyy"
            return df.string(from: todayData.targetDate)
        case .week:
            return weeklyData.weekLabel
        case .month:
            return monthlyData.monthLabel
        }
    }

    // MARK: - Day (24h) Graph Subviews

    private func todayStatsBanner(data: TodayGraphData) -> some View {
        HStack(spacing: 8) {
            statTile(
                title: data.isToday ? "USAGE TODAY" : "USAGE YESTERDAY",
                value: String(format: "+%.2f%%", data.totalDelta),
                subtext: "\(data.allDayRecords.count) prompts recorded",
                icon: "chart.line.uptrend.xyaxis",
                accentColor: Color(hex: 0x24C1E0)
            )
            statTile(
                title: "PEAK BURST HOUR",
                value: data.peakBin != nil ? "\(data.peakBin!.hourLabel) (\(String(format: "+%.2f%%", data.peakBin!.delta)))" : "None",
                subtext: data.peakBin != nil ? "\(data.peakBin!.promptCount) prompts in hour" : "No burst yet",
                icon: "flame.fill",
                accentColor: Color(hex: 0xFF5722)
            )
            statTile(
                title: "ACTIVE HOURS",
                value: "\(data.activeHoursCount) hr\(data.activeHoursCount == 1 ? "" : "s")",
                subtext: "\(24 - data.activeHoursCount) idle hours",
                icon: "bolt.fill",
                accentColor: Color(hex: 0xF59E0B)
            )
            statTile(
                title: "PROMPT VOLUME",
                value: "\(data.totalPrompts)",
                subtext: data.totalPrompts > 0 ? String(format: "avg +%.2f%% / prompt", data.totalDelta / Double(max(1, data.totalPrompts))) : "0 queries",
                icon: "bubble.left.and.bubble.right.fill",
                accentColor: Color(hex: 0x34D399)
            )
        }
    }

    private func todayHourlyBarChart(data: TodayGraphData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2.2) {
                ForEach(data.bins) { bin in
                    hourlyBarColumn(bin: bin, maxDelta: data.maxHourDelta)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 0.8)
                    )
            )
            .onHover { hovering in
                if !hovering {
                    hoveredHour = nil
                }
            }
        }
    }

    private func hourlyBarColumn(bin: HourlyUsageBin, maxDelta: Double) -> some View {
        let isSelected = selectedHour == bin.hour
        let isHovered = hoveredHour == bin.hour
        let isHoveredOrSelected = isSelected || isHovered

        return VStack(spacing: 2) {
            if bin.delta > 0.005 {
                Text(String(format: "+%.1f%%", bin.delta))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(bin.isPeakHour ? Color(hex: 0xFF5722) : Color(hex: 0x24C1E0))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            } else {
                Text(" ")
                    .font(.system(size: 14))
            }

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(
                        bin.isFutureHour
                            ? Color.white.opacity(0.012)
                            : (isHoveredOrSelected ? Color.white.opacity(0.07) : Color.white.opacity(0.03))
                    )
                    .frame(width: 12, height: 90)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .stroke(
                                isSelected
                                    ? Color(hex: 0x24C1E0)
                                    : (isHovered
                                        ? Color(hex: 0x24C1E0).opacity(0.6)
                                        : (bin.isCurrentHour ? Color(hex: 0x24C1E0).opacity(0.35) : Color.white.opacity(0.04))),
                                lineWidth: isSelected ? 1.5 : (isHovered ? 1.0 : 0.6)
                            )
                    )

                if bin.delta > 0.001 {
                    let barH = max(6.0, (bin.delta / maxDelta) * 86.0)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: bin.isPeakHour
                                    ? [Color(hex: 0xFF5722), Color(hex: 0xF59E0B)]
                                    : [Color(hex: 0x1E88E5), Color(hex: 0x24C1E0)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 10, height: barH)
                        .padding(.bottom, 2)
                        .shadow(
                            color: isHoveredOrSelected
                                ? (bin.isPeakHour ? Color(hex: 0xFF5722).opacity(0.65) : Color(hex: 0x24C1E0).opacity(0.65))
                                : .clear,
                            radius: 4
                        )
                } else if !bin.isFutureHour {
                    Rectangle()
                        .fill(bin.isCurrentHour ? Color(hex: 0x24C1E0).opacity(0.4) : Color.white.opacity(0.08))
                        .frame(width: 6, height: 2)
                        .padding(.bottom, 2)
                }
            }
            .frame(width: 14, height: 90)

            if bin.isCurrentHour {
                Text("NOW")
                    .font(.system(size: 6, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(hex: 0x24C1E0))
                    .padding(.horizontal, 2)
                    .padding(.vertical, 0.5)
                    .background(Capsule().fill(Color(hex: 0x24C1E0).opacity(0.18)))
            } else {
                Text(" ")
                    .font(.system(size: 6))
                    .padding(.vertical, 0.5)
            }

            if bin.hour % 3 == 0 || isHoveredOrSelected {
                Text(bin.hourLabel)
                    .font(.system(size: 7.5, weight: isHoveredOrSelected ? .bold : .medium, design: .monospaced))
                    .foregroundStyle(
                        isSelected
                            ? Color(hex: 0x24C1E0)
                            : (isHovered
                                ? Color.white
                                : (bin.isCurrentHour ? Color(hex: 0x24C1E0) : Color.white.opacity(0.50)))
                    )
            } else {
                Circle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 2.5, height: 2.5)
                    .frame(height: 9)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.12)) {
                if h {
                    hoveredHour = bin.hour
                } else if hoveredHour == bin.hour {
                    hoveredHour = nil
                }
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if selectedHour == bin.hour {
                    selectedHour = nil
                } else {
                    selectedHour = bin.hour
                }
            }
        }
    }

    private func inspectorHudBanner(data: TodayGraphData) -> some View {
        let activeHourIndex = hoveredHour ?? selectedHour
        return Group {
            if let h = activeHourIndex, h < data.bins.count {
                let bin = data.bins[h]
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color(hex: 0x24C1E0))
                            Text(bin.timeRange)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.white)

                            if bin.isPeakHour {
                                Text("PEAK BURST")
                                    .font(.system(size: 7.5, weight: .heavy))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color(hex: 0xFF5722)))
                            }
                            if bin.isCurrentHour {
                                Text("NOW")
                                    .font(.system(size: 7.5, weight: .heavy))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color(hex: 0x24C1E0)))
                            }
                            if selectedHour == bin.hour {
                                Text("PINNED")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(Color(hex: 0x24C1E0))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color(hex: 0x24C1E0).opacity(0.18)))
                            }
                        }

                        Text(bin.promptCount > 0
                            ? "\(bin.promptCount) \(bin.promptCount == 1 ? "prompt" : "prompts") recorded in this hour • Click bar to pin/unpin"
                            : (bin.isFutureHour ? "Upcoming hour" : "No prompt activity in this hour")
                        )
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.white.opacity(0.50))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(String(format: "+%.2f%%", bin.delta))
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                            .foregroundStyle(bin.isPeakHour ? Color(hex: 0xFF5722) : Color(hex: 0x24C1E0))

                        Text(String(format: "Cumulative: +%.2f%%", bin.cumulativeDelta))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    selectedHour == h ? Color(hex: 0x24C1E0).opacity(0.55) : Color.white.opacity(0.10),
                                    lineWidth: 1
                                )
                        )
                )
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "cursorarrow.rays")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0x24C1E0).opacity(0.75))
                    Text("Hover or scrub over 24h timeline to inspect bursts • Click any hour to filter prompt log")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.50))
                    Spacer()
                    Text(String(format: "Day Total: +%.2f%%", data.totalDelta))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x24C1E0).opacity(0.85))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.025))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.06), lineWidth: 0.8)
                        )
                )
            }
        }
    }

    private func todayPromptsList(data: TodayGraphData) -> some View {
        let promptsToShow: [SessionDeltaRecord] = {
            if let sel = selectedHour, sel < data.bins.count {
                return data.bins[sel].records
            }
            if let hov = hoveredHour, hov < data.bins.count, !data.bins[hov].records.isEmpty {
                return data.bins[hov].records
            }
            return data.allDayRecords
        }()

        let isFiltered = selectedHour != nil || (hoveredHour != nil && !promptsToShow.isEmpty)
        let title: String = {
            if let sel = selectedHour, sel < data.bins.count {
                return data.bins[sel].timeRange.uppercased()
            }
            if let hov = hoveredHour, hov < data.bins.count, !data.bins[hov].records.isEmpty {
                return "PREVIEW: \(data.bins[hov].timeRange.uppercased())"
            }
            return data.isToday ? "TODAY'S PROMPT TIMELINE" : "YESTERDAY'S PROMPT TIMELINE"
        }()

        return dayOrRangePromptsList(
            title: title,
            prompts: promptsToShow,
            isFiltered: isFiltered,
            emptyMessage: selectedHour != nil ? "No queries in this hour" : "No queries recorded for this day",
            onClearFilter: {
                selectedHour = nil
                hoveredHour = nil
            }
        )
    }

    // MARK: - Week (7d) Graph Subviews

    private func weeklyStatsBanner(data: WeeklyGraphData) -> some View {
        HStack(spacing: 8) {
            statTile(
                title: data.isCurrentWeek ? "THIS WEEK'S USAGE" : "WEEKLY USAGE",
                value: String(format: "+%.2f%%", data.totalDelta),
                subtext: "\(data.allWeekRecords.count) prompts recorded",
                icon: "calendar",
                accentColor: Color(hex: 0x24C1E0)
            )
            statTile(
                title: "PEAK USAGE DAY",
                value: data.peakBin != nil ? "\(data.peakBin!.dayLabel) (\(String(format: "+%.2f%%", data.peakBin!.delta)))" : "None",
                subtext: data.peakBin != nil ? "\(data.peakBin!.promptCount) prompts on \(data.peakBin!.dayLabel)" : "No activity",
                icon: "flame.fill",
                accentColor: Color(hex: 0xFF5722)
            )
            statTile(
                title: "ACTIVE DAYS",
                value: "\(data.activeDaysCount) of 7 days",
                subtext: "\(7 - data.activeDaysCount) zero usage days",
                icon: "bolt.fill",
                accentColor: Color(hex: 0xF59E0B)
            )
            statTile(
                title: "PROMPT VOLUME",
                value: "\(data.totalPrompts)",
                subtext: data.totalPrompts > 0 ? String(format: "avg +%.2f%% / prompt", data.totalDelta / Double(max(1, data.totalPrompts))) : "0 queries",
                icon: "bubble.left.and.bubble.right.fill",
                accentColor: Color(hex: 0x34D399)
            )
        }
    }

    private func weeklyBarChart(data: WeeklyGraphData) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(data.bins) { bin in
                weeklyDayColumn(bin: bin, maxDelta: data.maxDayDelta)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.8)
                )
        )
        .onHover { hovering in
            if !hovering { hoveredDayKey = nil }
        }
    }

    private func weeklyDayColumn(bin: DailyUsageBin, maxDelta: Double) -> some View {
        let isSelected = selectedDayKey == bin.dateKey
        let isHovered = hoveredDayKey == bin.dateKey
        let isHoveredOrSelected = isSelected || isHovered

        return VStack(spacing: 3) {
            if bin.delta > 0.005 {
                Text(String(format: "+%.1f%%", bin.delta))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(bin.isPeakDay ? Color(hex: 0xFF5722) : Color(hex: 0x24C1E0))
            } else {
                Text(" ")
                    .font(.system(size: 17))
            }

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        bin.isFuture
                            ? Color.white.opacity(0.012)
                            : (isHoveredOrSelected ? Color.white.opacity(0.08) : Color.white.opacity(0.035))
                    )
                    .frame(width: 32, height: 90)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                isSelected
                                    ? Color(hex: 0x24C1E0)
                                    : (isHovered
                                        ? Color(hex: 0x24C1E0).opacity(0.6)
                                        : (bin.isToday ? Color(hex: 0x24C1E0).opacity(0.35) : Color.white.opacity(0.05))),
                                lineWidth: isSelected ? 1.5 : (isHovered ? 1.0 : 0.7)
                            )
                    )

                if bin.delta > 0.001 {
                    let barH = max(6.0, (bin.delta / maxDelta) * 84.0)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: bin.isPeakDay
                                    ? [Color(hex: 0xFF5722), Color(hex: 0xF59E0B)]
                                    : [Color(hex: 0x1E88E5), Color(hex: 0x24C1E0)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 26, height: barH)
                        .padding(.bottom, 3)
                        .shadow(
                            color: isHoveredOrSelected
                                ? (bin.isPeakDay ? Color(hex: 0xFF5722).opacity(0.6) : Color(hex: 0x24C1E0).opacity(0.6))
                                : .clear,
                            radius: 4
                        )
                } else if !bin.isFuture {
                    Rectangle()
                        .fill(bin.isToday ? Color(hex: 0x24C1E0).opacity(0.4) : Color.white.opacity(0.08))
                        .frame(width: 14, height: 2)
                        .padding(.bottom, 3)
                }
            }
            .frame(width: 38, height: 90)

            if bin.isToday {
                Text("TODAY")
                    .font(.system(size: 6.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(hex: 0x24C1E0))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0.5)
                    .background(Capsule().fill(Color(hex: 0x24C1E0).opacity(0.18)))
            } else {
                Text(" ")
                    .font(.system(size: 6.5))
                    .padding(.vertical, 0.5)
            }

            VStack(spacing: 0.5) {
                Text(bin.dayLabel)
                    .font(.system(size: 9.5, weight: isHoveredOrSelected ? .bold : .semibold))
                    .foregroundStyle(
                        isSelected ? Color(hex: 0x24C1E0) : (isHovered ? Color.white : (bin.isToday ? Color(hex: 0x24C1E0) : Color.white.opacity(0.75)))
                    )
                Text("\(bin.dayNumber)")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.40))
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.12)) {
                if h { hoveredDayKey = bin.dateKey }
                else if hoveredDayKey == bin.dateKey { hoveredDayKey = nil }
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if selectedDayKey == bin.dateKey {
                    selectedDayKey = nil
                } else {
                    selectedDayKey = bin.dateKey
                }
            }
        }
    }

    private func weeklyInspectorHudBanner(data: WeeklyGraphData) -> some View {
        let activeKey = hoveredDayKey ?? selectedDayKey
        let activeBin = data.bins.first(where: { $0.dateKey == activeKey })

        return Group {
            if let bin = activeBin {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: "calendar")
                                .font(.system(size: 9))
                                .foregroundStyle(Color(hex: 0x24C1E0))
                            Text(bin.fullDateLabel)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.white)

                            if bin.isPeakDay {
                                Text("PEAK DAY")
                                    .font(.system(size: 7.5, weight: .heavy))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color(hex: 0xFF5722)))
                            }
                            if bin.isToday {
                                Text("TODAY")
                                    .font(.system(size: 7.5, weight: .heavy))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color(hex: 0x24C1E0)))
                            }
                            if selectedDayKey == bin.dateKey {
                                Text("PINNED")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(Color(hex: 0x24C1E0))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color(hex: 0x24C1E0).opacity(0.18)))
                            }
                        }

                        Text(bin.promptCount > 0
                            ? "\(bin.promptCount) \(bin.promptCount == 1 ? "prompt" : "prompts") recorded on this day • Click to pin/unpin"
                            : (bin.isFuture ? "Upcoming day" : "No prompts recorded on this day")
                        )
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.white.opacity(0.50))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(String(format: "+%.2f%%", bin.delta))
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                            .foregroundStyle(bin.isPeakDay ? Color(hex: 0xFF5722) : Color(hex: 0x24C1E0))

                        Text(String(format: "Cumulative this week: +%.2f%%", bin.cumulativeDelta))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    selectedDayKey == bin.dateKey ? Color(hex: 0x24C1E0).opacity(0.55) : Color.white.opacity(0.10),
                                    lineWidth: 1
                                )
                        )
                )
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "cursorarrow.rays")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0x24C1E0).opacity(0.75))
                    Text("Hover or click any day bar to inspect usage breakdown • Click to filter prompt log")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.50))
                    Spacer()
                    Text(String(format: "Week Total: +%.2f%%", data.totalDelta))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x24C1E0).opacity(0.85))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.025))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.06), lineWidth: 0.8)
                        )
                )
            }
        }
    }

    private func weeklyPromptsList(data: WeeklyGraphData) -> some View {
        let activeKey = selectedDayKey ?? hoveredDayKey
        let activeBin = data.bins.first(where: { $0.dateKey == activeKey })
        let promptsToShow: [SessionDeltaRecord] = {
            if let bin = activeBin, !bin.records.isEmpty {
                return bin.records
            }
            if selectedDayKey != nil {
                return []
            }
            return data.allWeekRecords
        }()

        return dayOrRangePromptsList(
            title: activeBin != nil ? activeBin!.fullDateLabel.uppercased() : (data.isCurrentWeek ? "THIS WEEK'S PROMPTS" : "WEEK PROMPT LOG"),
            prompts: promptsToShow,
            isFiltered: activeBin != nil,
            emptyMessage: activeBin != nil ? "No prompt records for \(activeBin!.dayLabel)" : "No prompt activity this week",
            onClearFilter: {
                selectedDayKey = nil
            }
        )
    }

    // MARK: - Month (30d) Graph Subviews

    private func monthlyStatsBanner(data: MonthlyGraphData) -> some View {
        HStack(spacing: 8) {
            statTile(
                title: data.isCurrentMonth ? "THIS MONTH'S USAGE" : "MONTHLY USAGE",
                value: String(format: "+%.2f%%", data.totalDelta),
                subtext: "\(data.allMonthRecords.count) prompts recorded",
                icon: "calendar.badge.clock",
                accentColor: Color(hex: 0x24C1E0)
            )
            statTile(
                title: "PEAK DAY",
                value: data.peakBin != nil ? "\(data.peakBin!.dayLabel) \(data.peakBin!.dayNumber) (\(String(format: "+%.2f%%", data.peakBin!.delta)))" : "None",
                subtext: data.peakBin != nil ? "\(data.peakBin!.promptCount) prompts on \(data.peakBin!.dayLabel) \(data.peakBin!.dayNumber)" : "No activity",
                icon: "flame.fill",
                accentColor: Color(hex: 0xFF5722)
            )
            statTile(
                title: "ACTIVE DAYS",
                value: "\(data.activeDaysCount) days active",
                subtext: "\(data.bins.count - data.activeDaysCount) idle days",
                icon: "bolt.fill",
                accentColor: Color(hex: 0xF59E0B)
            )
            statTile(
                title: "PROMPT VOLUME",
                value: "\(data.totalPrompts)",
                subtext: data.totalPrompts > 0 ? String(format: "avg +%.2f%% / prompt", data.totalDelta / Double(max(1, data.totalPrompts))) : "0 queries",
                icon: "bubble.left.and.bubble.right.fill",
                accentColor: Color(hex: 0x34D399)
            )
        }
    }

    private func monthlyBarChart(data: MonthlyGraphData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 1.8) {
                ForEach(data.bins) { bin in
                    monthlyDayColumn(bin: bin, maxDelta: data.maxDayDelta)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 0.8)
                    )
            )
            .onHover { hovering in
                if !hovering { hoveredDayKey = nil }
            }
        }
    }

    private func monthlyDayColumn(bin: DailyUsageBin, maxDelta: Double) -> some View {
        let isSelected = selectedDayKey == bin.dateKey
        let isHovered = hoveredDayKey == bin.dateKey
        let isHoveredOrSelected = isSelected || isHovered

        return VStack(spacing: 2) {
            if bin.delta > 0.05 {
                Text(String(format: "+%.1f%%", bin.delta))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(bin.isPeakDay ? Color(hex: 0xFF5722) : Color(hex: 0x24C1E0))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            } else {
                Text(" ")
                    .font(.system(size: 13))
            }

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        bin.isFuture
                            ? Color.white.opacity(0.012)
                            : (isHoveredOrSelected ? Color.white.opacity(0.07) : Color.white.opacity(0.03))
                    )
                    .frame(width: 13, height: 90)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(
                                isSelected
                                    ? Color(hex: 0x24C1E0)
                                    : (isHovered
                                        ? Color(hex: 0x24C1E0).opacity(0.6)
                                        : (bin.isToday ? Color(hex: 0x24C1E0).opacity(0.35) : Color.white.opacity(0.04))),
                                lineWidth: isSelected ? 1.5 : (isHovered ? 1.0 : 0.6)
                            )
                    )

                if bin.delta > 0.001 {
                    let barH = max(6.0, (bin.delta / maxDelta) * 86.0)
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: bin.isPeakDay
                                    ? [Color(hex: 0xFF5722), Color(hex: 0xF59E0B)]
                                    : [Color(hex: 0x1E88E5), Color(hex: 0x24C1E0)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 10, height: barH)
                        .padding(.bottom, 2)
                        .shadow(
                            color: isHoveredOrSelected
                                ? (bin.isPeakDay ? Color(hex: 0xFF5722).opacity(0.65) : Color(hex: 0x24C1E0).opacity(0.65))
                                : .clear,
                            radius: 3
                        )
                } else if !bin.isFuture {
                    Rectangle()
                        .fill(bin.isToday ? Color(hex: 0x24C1E0).opacity(0.4) : Color.white.opacity(0.08))
                        .frame(width: 6, height: 2)
                        .padding(.bottom, 2)
                }
            }
            .frame(width: 15, height: 90)

            if bin.isToday {
                Text("NOW")
                    .font(.system(size: 6, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(hex: 0x24C1E0))
                    .padding(.horizontal, 2)
                    .padding(.vertical, 0.5)
                    .background(Capsule().fill(Color(hex: 0x24C1E0).opacity(0.18)))
            } else {
                Text(" ")
                    .font(.system(size: 6))
                    .padding(.vertical, 0.5)
            }

            if bin.dayNumber == 1 || bin.dayNumber % 5 == 0 || isHoveredOrSelected {
                Text("\(bin.dayNumber)")
                    .font(.system(size: 7.5, weight: isHoveredOrSelected ? .bold : .medium, design: .monospaced))
                    .foregroundStyle(
                        isSelected
                            ? Color(hex: 0x24C1E0)
                            : (isHovered
                                ? Color.white
                                : (bin.isToday ? Color(hex: 0x24C1E0) : Color.white.opacity(0.50)))
                    )
            } else {
                Circle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 2.2, height: 2.2)
                    .frame(height: 9)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.12)) {
                if h { hoveredDayKey = bin.dateKey }
                else if hoveredDayKey == bin.dateKey { hoveredDayKey = nil }
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if selectedDayKey == bin.dateKey {
                    selectedDayKey = nil
                } else {
                    selectedDayKey = bin.dateKey
                }
            }
        }
    }

    private func monthlyInspectorHudBanner(data: MonthlyGraphData) -> some View {
        let activeKey = hoveredDayKey ?? selectedDayKey
        let activeBin = data.bins.first(where: { $0.dateKey == activeKey })

        return Group {
            if let bin = activeBin {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.system(size: 9))
                                .foregroundStyle(Color(hex: 0x24C1E0))
                            Text(bin.fullDateLabel)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.white)

                            if bin.isPeakDay {
                                Text("PEAK DAY")
                                    .font(.system(size: 7.5, weight: .heavy))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color(hex: 0xFF5722)))
                            }
                            if bin.isToday {
                                Text("TODAY")
                                    .font(.system(size: 7.5, weight: .heavy))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color(hex: 0x24C1E0)))
                            }
                            if selectedDayKey == bin.dateKey {
                                Text("PINNED")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(Color(hex: 0x24C1E0))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color(hex: 0x24C1E0).opacity(0.18)))
                            }
                        }

                        Text(bin.promptCount > 0
                            ? "\(bin.promptCount) \(bin.promptCount == 1 ? "prompt" : "prompts") recorded on this day • Click to pin/unpin"
                            : (bin.isFuture ? "Upcoming day" : "No prompts recorded on this day")
                        )
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.white.opacity(0.50))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(String(format: "+%.2f%%", bin.delta))
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                            .foregroundStyle(bin.isPeakDay ? Color(hex: 0xFF5722) : Color(hex: 0x24C1E0))

                        Text(String(format: "Cumulative this month: +%.2f%%", bin.cumulativeDelta))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    selectedDayKey == bin.dateKey ? Color(hex: 0x24C1E0).opacity(0.55) : Color.white.opacity(0.10),
                                    lineWidth: 1
                                )
                        )
                )
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "cursorarrow.rays")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0x24C1E0).opacity(0.75))
                    Text("Hover or click any day bar to inspect daily usage • Click to filter prompt log")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.50))
                    Spacer()
                    Text(String(format: "Month Total: +%.2f%%", data.totalDelta))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x24C1E0).opacity(0.85))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.025))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.06), lineWidth: 0.8)
                        )
                )
            }
        }
    }

    private func monthlyPromptsList(data: MonthlyGraphData) -> some View {
        let activeKey = selectedDayKey ?? hoveredDayKey
        let activeBin = data.bins.first(where: { $0.dateKey == activeKey })
        let promptsToShow: [SessionDeltaRecord] = {
            if let bin = activeBin, !bin.records.isEmpty {
                return bin.records
            }
            if selectedDayKey != nil {
                return []
            }
            return data.allMonthRecords
        }()

        return dayOrRangePromptsList(
            title: activeBin != nil ? activeBin!.fullDateLabel.uppercased() : "MONTH PROMPT TIMELINE (\(promptsToShow.count))",
            prompts: promptsToShow,
            isFiltered: activeBin != nil,
            emptyMessage: activeBin != nil ? "No prompt records for \(activeBin!.dayLabel) \(activeBin!.dayNumber)" : "No prompt activity this month",
            onClearFilter: {
                selectedDayKey = nil
            }
        )
    }

    // MARK: - Shared Prompts Log View

    private func dayOrRangePromptsList(
        title: String,
        prompts: [SessionDeltaRecord],
        isFiltered: Bool,
        emptyMessage: String,
        onClearFilter: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(title) (\(prompts.count))")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(isFiltered ? Color(hex: 0x24C1E0) : Color.white.opacity(0.65))

                Spacer()

                if isFiltered {
                    Text("Filtered day")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.4))
                } else {
                    Text("Chronological stream")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 2)

            HStack {
                Text("TIME")
                    .frame(width: 80, alignment: .leading)
                Text("INTERVAL")
                    .frame(width: 65, alignment: .leading)
                Text("CONTEXT / POOL")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("DELTA")
                    .frame(width: 70, alignment: .trailing)
            }
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.40))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.02))
            .cornerRadius(4)

            if prompts.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bubble.left.and.exclamationmark")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.white.opacity(0.25))
                    Text(emptyMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                    if isFiltered {
                        Button("Show All In Timeframe") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                onClearFilter()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(prompts.enumerated()), id: \.element.id) { (idx, rec) in
                            let prevTs = idx + 1 < prompts.count ? prompts[idx + 1].timestamp : nil
                            promptRow(rec: rec, prevTimestamp: prevTs)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Sessions Tab

    private func sessionsView(sessions: [UsageSession], totalRecorded: Double) -> some View {
        let realSessionsCount = sessions.filter { $0.isSession }.count
        let displayedSessions = (filterOnlySessions && realSessionsCount > 0)
            ? sessions.filter { $0.isSession }
            : sessions

        return VStack(alignment: .leading, spacing: 10) {
            // Sub-bar: Mode picker + Filter Segments + Expand/Collapse toggle
            HStack(spacing: 8) {
                Picker("", selection: $groupingMode) {
                    ForEach(SessionGroupingMode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                Picker("", selection: $filterOnlySessions) {
                    Text("All (\(sessions.count))").tag(false)
                    Text("⚡ Sessions (\(realSessionsCount))").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 175)

                Spacer()

                if !displayedSessions.isEmpty {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if expandedSessionIds.count == displayedSessions.count {
                                expandedSessionIds.removeAll()
                            } else {
                                expandedSessionIds = Set(displayedSessions.map { $0.id })
                            }
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: expandedSessionIds.count == displayedSessions.count ? "chevron.up.circle" : "chevron.down.circle")
                                .font(.system(size: 10, weight: .semibold))
                            Text(expandedSessionIds.count == displayedSessions.count ? "Collapse All" : "Expand All")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Color.white.opacity(0.65))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Summary KPI Banner
            sessionStatsBanner(sessions: sessions, totalRecorded: totalRecorded)

            if sessions.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "bolt.badge.clock")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.white.opacity(0.25))
                    Text("No session activity recorded yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                    Text("As you send queries with \(serviceName), active work sessions and intense bursts will be automatically tracked and shown here.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedSessions.isEmpty && filterOnlySessions {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.white.opacity(0.28))
                    Text("No multi-prompt sessions yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                    Text("\(sessions.count) single queries recorded. Toggle to 'All (\(sessions.count))' above to view individual prompt usages.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                    Button("Show All Activity") {
                        filterOnlySessions = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(displayedSessions) { session in
                            sessionCard(session)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func sessionStatsBanner(sessions: [UsageSession], totalRecorded: Double) -> some View {
        let realSessions = sessions.filter { $0.isSession }
        let activeSessionsCount = realSessions.count
        let todaySessionsCount = realSessions.filter { Calendar.current.isDateInToday($0.startTime) }.count
        let singleCount = sessions.filter { !$0.isSession }.reduce(0) { $0 + $1.records.count }
        let peakSession = realSessions.max(by: { $0.totalDelta < $1.totalDelta }) ?? sessions.max(by: { $0.totalDelta < $1.totalDelta })

        return HStack(spacing: 8) {
            statTile(
                title: "RECORDED USAGE",
                value: String(format: "+%.2f%%", totalRecorded),
                subtext: "\(sessions.reduce(0) { $0 + $1.records.count }) prompts tracked",
                icon: "chart.line.uptrend.xyaxis",
                accentColor: Color(hex: 0x24C1E0)
            )
            statTile(
                title: "ACTIVE SESSIONS",
                value: "\(activeSessionsCount)",
                subtext: "\(todaySessionsCount) today • \(singleCount) single \(singleCount == 1 ? "query" : "queries")",
                icon: "bolt.horizontal.fill",
                accentColor: Color(hex: 0xF59E0B)
            )
            statTile(
                title: "PEAK BURST",
                value: peakSession != nil ? String(format: "+%.2f%%", peakSession!.totalDelta) : "0.00%",
                subtext: peakSession != nil ? "\(peakSession!.durationFormatted) • \(peakSession!.records.count) prompts" : "No bursts",
                icon: "flame.fill",
                accentColor: Color(hex: 0xFF5722)
            )
        }
    }

    private func statTile(title: String, value: String, subtext: String, icon: String, accentColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.95))
            Text(subtext)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.40))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                )
        )
    }

    private func sessionCard(_ session: UsageSession) -> some View {
        let isExpanded = expandedSessionIds.contains(session.id)
        let avgPerPrompt = session.records.isEmpty ? 0.0 : session.totalDelta / Double(session.records.count)
        let isReal = session.isSession

        return VStack(alignment: .leading, spacing: 0) {
            // Card Header (Clickable to toggle)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded {
                        expandedSessionIds.remove(session.id)
                    } else {
                        expandedSessionIds.insert(session.id)
                    }
                }
            }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(session.dayLabel)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(session.isToday ? Color.white : Color.white.opacity(0.70))
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(session.isToday ? (isReal ? Color(hex: 0x24C1E0).opacity(0.22) : Color.white.opacity(0.12)) : Color.white.opacity(0.08))
                            )

                        Text(session.title)
                            .font(.system(size: isReal ? 13 : 11.5, weight: isReal ? .bold : .semibold, design: .rounded))
                            .foregroundStyle(isReal ? Color.white.opacity(0.95) : Color.white.opacity(0.75))

                        HStack(spacing: 3) {
                            Image(systemName: session.intensity.icon)
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(session.intensity.label)
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(session.intensity.color)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(session.intensity.color.opacity(isReal ? 0.14 : 0.08))
                        )

                        Spacer()

                        Text(String(format: "+%.2f%%", session.totalDelta))
                            .font(.system(size: isReal ? 13.5 : 12, weight: isReal ? .heavy : .bold, design: .rounded))
                            .foregroundStyle(isReal ? session.intensity.color : Color(hex: 0x24C1E0).opacity(0.85))

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.35))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 14, height: 14)
                    }

                    HStack(spacing: 10) {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.white.opacity(0.40))
                            Text(session.timeRangeFormatted)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.70))
                        }

                        if isReal {
                            HStack(spacing: 3) {
                                Image(systemName: "hourglass")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.white.opacity(0.40))
                                Text(session.durationFormatted)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.70))
                            }
                        }

                        HStack(spacing: 3) {
                            Image(systemName: "number")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.white.opacity(0.40))
                            Text("\(session.records.count) \(session.records.count == 1 ? "prompt" : "prompts")")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.70))
                        }

                        Spacer()

                        if session.records.count > 1 && isReal {
                            Text(String(format: "avg +%.2f%% / prompt", avgPerPrompt))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.40))
                        }
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, isReal ? 9 : 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    Divider()
                        .background(Color.white.opacity(0.08))

                    HStack {
                        Text("TIME")
                            .frame(width: 80, alignment: .leading)
                        Text("INTERVAL")
                            .frame(width: 65, alignment: .leading)
                        Text("CONTEXT")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("DELTA")
                            .frame(width: 70, alignment: .trailing)
                    }
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.40))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.02))

                    Divider()
                        .background(Color.white.opacity(0.05))

                    VStack(spacing: 2) {
                        ForEach(Array(session.records.enumerated()), id: \.element.id) { (idx, rec) in
                            let prevTs = idx + 1 < session.records.count ? session.records[idx + 1].timestamp : nil
                            promptRow(rec: rec, prevTimestamp: prevTs)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(Color.black.opacity(0.20))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isReal ? Color.white.opacity(0.035) : Color.white.opacity(0.018))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isReal ? (session.intensity == .high ? Color(hex: 0xFF5722).opacity(0.28) : Color(hex: 0x24C1E0).opacity(0.18)) : Color.white.opacity(0.05),
                            lineWidth: 0.8
                        )
                )
        )
    }

    // MARK: - Model & Token Helpers

    private var modelBadgeLabel: String {
        if isClaudeGPT {
            return "Claude & GPT"
        } else if serviceName == "AGY" {
            return "Gemini Pro/Flash"
        } else if serviceName == "Grok Bot" {
            return "Grok 3 (Bot)"
        } else {
            return "Grok 3"
        }
    }

    private var modelBadgeColor: Color {
        if isClaudeGPT {
            return Color(hex: 0xF28B82)
        } else if serviceName == "AGY" {
            return Color(hex: 0x24C1E0)
        } else {
            return Color(hex: 0x1E88E5)
        }
    }

    private func estimatedTokensLabel(delta: Double) -> String {
        let tokensPerPercent: Double = {
            if isClaudeGPT {
                return 25_000.0
            } else if serviceName == "AGY" {
                return 75_000.0
            } else {
                return 100_000.0
            }
        }()
        let tokens = delta * tokensPerPercent
        if tokens >= 1_000_000 {
            return String(format: "~%.2fM tokens", tokens / 1_000_000.0)
        } else if tokens >= 1_000 {
            return String(format: "~%.1fk tokens", tokens / 1_000.0)
        } else {
            return "~\(Int(tokens.rounded())) tokens"
        }
    }

    private func promptRow(rec: SessionDeltaRecord, prevTimestamp: Double?) -> some View {
        let timeStr: String = {
            let d = Date(timeIntervalSince1970: rec.timestamp)
            let df = DateFormatter()
            df.dateFormat = "h:mm:ss a"
            return df.string(from: d)
        }()

        let (intervalStr, isBurst): (String, Bool) = {
            guard let prev = prevTimestamp else { return ("Start", false) }
            let gap = max(0, rec.timestamp - prev)
            if gap < 60 { return ("+\(Int(gap))s", true) }
            let mins = Int(gap / 60)
            if mins < 60 { return ("+\(mins)m", false) }
            return ("+\(mins / 60)h", false)
        }()

        return HStack(spacing: 0) {
            Text(timeStr)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 78, alignment: .leading)

            HStack(spacing: 2) {
                if isBurst {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(Color(hex: 0xF59E0B))
                }
                Text(intervalStr)
                    .font(.system(size: 9.5, weight: isBurst ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(isBurst ? Color(hex: 0xF59E0B) : Color.white.opacity(0.45))
            }
            .frame(width: 58, alignment: .leading)

            HStack(spacing: 6) {
                // Model Badge
                Text(modelBadgeLabel)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(modelBadgeColor)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(modelBadgeColor.opacity(0.14))
                    )

                // Estimated Tokens
                Text(estimatedTokensLabel(delta: rec.weeklyDelta))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.60))

                Text("•")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.white.opacity(0.25))

                Text(String(format: "Tot %.1f%%", rec.weeklyTotal))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.40))
                if let five = rec.fiveHourPercent {
                    Text(String(format: "5h %.1f%%", five))
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(String(format: "+%.2f%%", rec.weeklyDelta))
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(modelBadgeColor)
                .frame(width: 65, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3.5)
    }

    // MARK: - Calendar Tab

    private func manualResetFormView() -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DATE (YYYY-MM-DD)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.50))
                TextField("2026-09-06", text: $newResetDateStr)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(4)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)
            }
            .frame(width: 120)

            VStack(alignment: .leading, spacing: 2) {
                Text("QUOTA GAIN %")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.50))
                TextField("100.0", text: $newResetGainStr)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(4)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)
            }
            .frame(width: 80)

            VStack(alignment: .leading, spacing: 2) {
                Text("LABEL / TITLE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.50))
                TextField("Google Manual Reset", text: $newResetTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .padding(4)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)
            }

            Button("Save") {
                let gain = Double(newResetGainStr) ?? 100.0
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.dateFormat = "yyyy-MM-dd"
                let ts = fmt.date(from: newResetDateStr)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                let rec = QuotaResetRecord(
                    timestamp: ts,
                    dateStr: newResetDateStr,
                    displayTitle: newResetTitle.isEmpty ? "Google Manual Reset" : newResetTitle,
                    gainedPercent: gain,
                    type: "manual",
                    note: newResetNote.isEmpty ? nil : newResetNote
                )
                subStore.saveQuotaReset(rec)
                withAnimation(.easeInOut(duration: 0.18)) {
                    isAddingManualReset = false
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 12)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func resetRowView(r: QuotaResetRecord) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: r.type == "manual" ? "hand.tap.fill" : "sparkles")
                .font(.system(size: 9.5))
                .foregroundStyle(Color(hex: 0xF59E0B))

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 5) {
                    Text(r.dateStr)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.92))
                    Text("•")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.white.opacity(0.3))
                    Text(r.displayTitle)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.80))
                }
                if let note = r.note {
                    Text(note)
                        .font(.system(size: 8.5, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.50))
                }
            }

            Spacer()

            Text(String(format: "+%.1f%% Bonus", r.gainedPercent))
                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(hex: 0xF59E0B))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color(hex: 0xF59E0B).opacity(0.14))
                )

            if r.type == "manual" {
                Button(action: {
                    withAnimation {
                        subStore.deleteQuotaReset(id: r.id)
                    }
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.025))
        )
    }

    private func quotaResetsCard(cal: Calendar) -> some View {
        let resets = subStore.loadQuotaResets()

        return VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: 0xF59E0B))
                Text("PAST QUOTA RESETS STORAGE")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.90))

                Spacer()

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if newResetDateStr.isEmpty {
                            let todayFmt = DateFormatter()
                            todayFmt.dateFormat = "yyyy-MM-dd"
                            newResetDateStr = todayFmt.string(from: Date())
                        }
                        isAddingManualReset.toggle()
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: isAddingManualReset ? "xmark.circle.fill" : "plus.circle.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(isAddingManualReset ? "Close" : "Log Reset")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: 0xF59E0B))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(hex: 0xF59E0B).opacity(0.14))
                    )
                }
                .buttonStyle(.plain)
            }

            // Inline Add Form
            if isAddingManualReset {
                manualResetFormView()
            }

            // Stored Resets List
            if !resets.isEmpty {
                VStack(spacing: 4) {
                    ForEach(resets) { r in
                        resetRowView(r: r)
                    }
                }
            } else {
                Text("No previous resets recorded yet. Click 'Log Reset' to add past manual quota refreshes.")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.40))
                    .padding(.vertical, 4)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                )
        )
    }

    private func calendarTabView(cal: Calendar) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Each day is % of that week’s \(serviceName) pool. Weeks and months are the sum of those days.")
                .font(.system(size: 9))
                .foregroundStyle(Color.white.opacity(0.45))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        quotaResetsCard(cal: cal)

                        ForEach(1...12, id: \.self) { month in
                            monthBlock(month, calendar: cal)
                                .id("month-\(month)")
                        }
                        weeksBlock(calendar: cal)
                            .id("weeks")
                        monthsSummary(calendar: cal)
                    }
                    .padding(.bottom, 12)
                }
                .onAppear {
                    Self.scrollToCurrentMonth(proxy)
                }
            }
        }
    }

    // MARK: - Raw Prompts Tab

    private func promptActivityView(records: [SessionDeltaRecord], totalDeltas: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(modelBadgeColor)
                    Text("\(records.count) prompt delta records")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("Total recorded usage:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                    Text(String(format: "+%.2f%%", totalDeltas))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(modelBadgeColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )

            if records.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.white.opacity(0.3))
                    Text("No prompt deltas recorded yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(records) { rec in
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rec.dateStr)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.white.opacity(0.92))
                                    HStack(spacing: 4) {
                                        Text(timeAgo(rec.timestamp))
                                            .font(.system(size: 9.5, weight: .medium))
                                            .foregroundStyle(Color.white.opacity(0.45))
                                        Text("•")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Color.white.opacity(0.30))
                                        Text(modelBadgeLabel)
                                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                            .foregroundStyle(modelBadgeColor)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(
                                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                                    .fill(modelBadgeColor.opacity(0.14))
                                            )
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(estimatedTokensLabel(delta: rec.weeklyDelta))
                                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.white.opacity(0.85))
                                    HStack(spacing: 3) {
                                        Text(String(format: "Weekly: %.2f%%", rec.weeklyTotal))
                                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                                            .foregroundStyle(Color.white.opacity(0.45))
                                        if let five = rec.fiveHourPercent {
                                            Text(String(format: "• 5h: %.1f%%", five))
                                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                                .foregroundStyle(Color.white.opacity(0.40))
                                        }
                                    }
                                }

                                Text(String(format: "+%.2f%%", rec.weeklyDelta))
                                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                                    .foregroundStyle(modelBadgeColor)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .frame(minWidth: 70)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(modelBadgeColor.opacity(0.18))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(modelBadgeColor.opacity(0.35), lineWidth: 0.8)
                                    )
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.04))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.white.opacity(0.07), lineWidth: 0.8)
                                    )
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func timeAgo(_ ts: Double) -> String {
        let diff = max(0, Date().timeIntervalSince1970 - ts)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h \(Int((diff.truncatingRemainder(dividingBy: 3600)) / 60))m ago" }
        return "\(Int(diff / 86400))d ago"
    }

    private static func scrollToCurrentMonth(_ proxy: ScrollViewProxy) {
        let current = Calendar.current.component(.month, from: Date())
        let go = { proxy.scrollTo("month-\(current)", anchor: UnitPoint.top) }
        DispatchQueue.main.async(execute: go)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: go)
    }

    private func yearSum() -> Double {
        subStore.dailyMap.reduce(0) { acc, kv in
            kv.key.hasPrefix(String(year)) ? acc + subStore.usedPercent(on: kv.key) : acc
        }
    }

    private func monthBlock(_ month: Int, calendar cal: Calendar) -> some View {
        let comps = DateComponents(year: year, month: month, day: 1)
        guard let start = cal.date(from: comps),
              let interval = cal.dateInterval(of: .month, for: start) else {
            return AnyView(EmptyView())
        }
        let monthSum = subStore.sumUsed(from: interval.start, to: interval.end)
        let name = DateFormatter().monthSymbols[month - 1]
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let todayKey = fmt.string(from: Date())
        let weekday = cal.component(.weekday, from: start)
        let mondayOffset = (weekday + 5) % 7
        let daysInMonth = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        let cells = mondayOffset + daysInMonth
        let rows = Int(ceil(Double(cells) / 7.0))

        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.88))
                    Spacer()
                    Text(PctFmt.total(monthSum))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .monospacedDigit()
                }
                HStack(spacing: 2) {
                    ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, d in
                        Text(d)
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                    }
                    Text("week")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .frame(width: 56, alignment: .trailing)
                }
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<7, id: \.self) { col in
                            let idx = row * 7 + col
                            let dayNum = idx - mondayOffset + 1
                            if dayNum >= 1 && dayNum <= daysInMonth,
                               let date = cal.date(byAdding: .day, value: dayNum - 1, to: start) {
                                let key = fmt.string(from: date)
                                dayCell(dayNum: dayNum, key: key, isToday: key == todayKey)
                            } else {
                                Color.clear.frame(height: 32)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        weekTotal(row: row, mondayOffset: mondayOffset, start: start, daysInMonth: daysInMonth, cal: cal, fmt: fmt)
                    }
                }
            }
        )
    }

    private func dayCell(dayNum: Int, key: String, isToday: Bool) -> some View {
        let p = subStore.usedPercent(on: key)
        return VStack(spacing: 1) {
            Text("\(dayNum)")
                .font(.system(size: 8, weight: isToday ? .bold : .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(isToday ? 0.95 : 0.55))
            Text(PctFmt.day(p))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: 0x6EA8FF).opacity(p > 0 ? 1 : 0.35))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isToday ? Color.white.opacity(0.08) : Color.clear)
        )
    }

    private func weekTotal(row: Int, mondayOffset: Int, start: Date, daysInMonth: Int, cal: Calendar, fmt: DateFormatter) -> some View {
        var sum = 0.0
        for col in 0..<7 {
            let idx = row * 7 + col
            let dayNum = idx - mondayOffset + 1
            if dayNum >= 1 && dayNum <= daysInMonth,
               let date = cal.date(byAdding: .day, value: dayNum - 1, to: start) {
                sum += subStore.usedPercent(on: fmt.string(from: date))
            }
        }
        return Text(PctFmt.total(sum))
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.55))
            .monospacedDigit()
            .frame(width: 56, alignment: .trailing)
    }

    private func weeksBlock(calendar cal: Calendar) -> some View {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = cal.timeZone
        guard let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let dec31 = cal.date(from: DateComponents(year: year, month: 12, day: 31)) else {
            return AnyView(EmptyView())
        }
        var rows: [(id: Int, label: String, used: Double)] = []
        var cursor = iso.dateInterval(of: .weekOfYear, for: jan1)?.start ?? jan1
        var i = 0
        while cursor <= dec31 {
            let end = iso.date(byAdding: .day, value: 7, to: cursor) ?? cursor
            let used = subStore.sumUsed(from: cursor, to: end)
            let weekNo = iso.component(.weekOfYear, from: cursor.addingTimeInterval(3 * 86400))
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            let label = "W\(weekNo)  \(f.string(from: cursor))–\(f.string(from: end.addingTimeInterval(-86400)))"
            rows.append((i, label, used))
            cursor = end
            i += 1
            if i > 54 { break }
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                Text("Weeks")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .padding(.top, 6)
                ForEach(rows, id: \.id) { row in
                    HStack {
                        Text(row.label)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.65))
                        Spacer()
                        Text(PctFmt.total(row.used))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.8))
                            .monospacedDigit()
                    }
                }
            }
        )
    }

    private func monthsSummary(calendar cal: Calendar) -> some View {
        AnyView(
            VStack(alignment: .leading, spacing: 4) {
                Text("Months")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .padding(.top, 6)
                ForEach(1...12, id: \.self) { month in
                    let comps = DateComponents(year: year, month: month, day: 1)
                    if let start = cal.date(from: comps),
                       let interval = cal.dateInterval(of: .month, for: start) {
                        let used = subStore.sumUsed(from: interval.start, to: interval.end)
                        HStack {
                            Text(DateFormatter().monthSymbols[month - 1])
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.65))
                            Spacer()
                            Text(PctFmt.total(used))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.8))
                                .monospacedDigit()
                        }
                    }
                }
            }
        )
    }
}

// MARK: - Sign-in WebView (shares WKWebsiteDataStore.default with fetchers)

struct CookieWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != url {
            nsView.load(URLRequest(url: url))
        }
    }
}

enum LoginHubSection: String, CaseIterable, Identifiable {
    case grok
    case cursor
    case agy
    case chatGPT
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        case .agy: return "AGY / Claude"
        case .chatGPT: return "ChatGPT"
        case .other: return "Other models"
        }
    }

    var subtitle: String {
        switch self {
        case .grok: return "grok.com quota"
        case .cursor: return "Grok Bot in Cursor"
        case .agy: return "Gemini + Claude via Antigravity"
        case .chatGPT: return "chatgpt.com quota"
        case .other: return "Not tracked yet"
        }
    }

    var service: ServiceKind? {
        switch self {
        case .grok: return .grok
        case .cursor: return .grokBot
        case .agy: return .agy
        case .chatGPT: return .chatGPT
        case .other: return nil
        }
    }

    static func section(for service: ServiceKind) -> LoginHubSection {
        switch service {
        case .grok: return .grok
        case .grokBot: return .cursor
        case .agy, .claudeGPT: return .agy
        case .chatGPT: return .chatGPT
        }
    }
}

private struct OtherModelInfo: Identifiable {
    let id: String
    let name: String
    let note: String
}

struct ServiceLoginView: View {
    let initialService: ServiceKind
    var onCancel: () -> Void
    var onFinished: (ServiceKind) -> Void

    @State private var selected: LoginHubSection
    @State private var tokenText = ""

    init(service: ServiceKind, startOnOther: Bool = false, onCancel: @escaping () -> Void, onFinished: @escaping (ServiceKind) -> Void) {
        self.initialService = service
        self.onCancel = onCancel
        self.onFinished = onFinished
        self._selected = State(initialValue: startOnOther ? .other : LoginHubSection.section(for: service))
    }

    private let otherModels: [OtherModelInfo] = [
        OtherModelInfo(id: "claude", name: "Claude.ai", note: "Anthropic’s web app doesn’t expose a weekly % like Antigravity’s Claude group."),
        OtherModelInfo(id: "gemini", name: "Gemini (google.com)", note: "Different from Antigravity. This card tracks Gemini inside AGY only."),
        OtherModelInfo(id: "copilot", name: "GitHub Copilot", note: "Copilot usage is on GitHub, not in these quota endpoints."),
        OtherModelInfo(id: "perplexity", name: "Perplexity", note: "No documented personal quota feed to poll."),
        OtherModelInfo(id: "openrouter", name: "OpenRouter", note: "Has its own dashboard/credits; not wired here.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sign in")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.95))
                Text("only the services you use")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.45))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .padding(5)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(LoginHubSection.allCases) { section in
                        Button(action: { selected = section }) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(section.title)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(selected == section ? 0.95 : 0.7))
                                Text(section.subtitle)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.white.opacity(0.42))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(selected == section ? Color.white.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .frame(width: 168)

                VStack(alignment: .leading, spacing: 8) {
                    if let service = selected.service {
                        Text(service.loginHint)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)

                        CookieWebView(url: service.loginURL)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            )
                            .id(selected)

                        if selected == .agy {
                            HStack(spacing: 8) {
                                TextField("Paste Antigravity access token (optional)", text: $tokenText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                Button("Save token") {
                                    KeychainTokenHelper.saveAccessToken(tokenText)
                                    onFinished(.agy)
                                }
                                .disabled(tokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    } else {
                        otherModelsPanel
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.white.opacity(0.7))
                if let service = selected.service {
                    Button("I’m signed in") { onFinished(service) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: 0x24C1E0))
                }
            }
        }
        .padding(14)
        .frame(width: 860, height: 660)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: 0x18181A).opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
        )
    }

    private var otherModelsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tap a provider to add it. ChatGPT can be added now. The rest are listed because people ask — they are not wired yet.")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            Button(action: {
                WidgetLayoutSettings.shared.enableCard(.chatGPT)
                selected = .chatGPT
            }) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ChatGPT / OpenAI")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.92))
                        Text("Adds a ChatGPT card. Sign in on chatgpt.com, then I’m signed in.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color(hex: 0x24C1E0))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(hex: 0x24C1E0).opacity(0.12))
                )
            }
            .buttonStyle(.plain)

            ForEach(otherModels) { model in
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.88))
                    Text(model.note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
            }

            Text("Hide unused cards in Settings so they are not fetched. If a provider you use publishes a quota API later, it can be added as a real card.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.42))
                .padding(.top, 4)

            Spacer()
        }
    }
}

// MARK: - Widget Layout & Card Configuration Settings

enum WidgetCardID: String, CaseIterable, Identifiable {
    case grok = "Grok"
    case grokBot = "Grok Bot"
    case agy = "AGY"
    case claudeGPT = "Claude & GPT"
    case chatGPT = "ChatGPT"

    var id: String { rawValue }

    var storageKey: String {
        switch self {
        case .grok: return "Grok"
        case .grokBot: return "GrokBot"
        case .agy: return "AGY"
        case .claudeGPT: return "ClaudeGPT"
        case .chatGPT: return "ChatGPT"
        }
    }

    var defaultTitle: String { displayName }

    var displayName: String {
        switch self {
        case .claudeGPT: return "Claude & GPT (from AGY)"
        default: return rawValue
        }
    }

    var serviceKind: ServiceKind {
        switch self {
        case .grok: return .grok
        case .grokBot: return .grokBot
        case .agy: return .agy
        case .claudeGPT: return .claudeGPT
        case .chatGPT: return .chatGPT
        }
    }
}

final class WidgetLayoutSettings: ObservableObject {
    static let shared = WidgetLayoutSettings()

    var onLayoutChange: (() -> Void)? = nil
    var onCardsEnabled: ((Set<WidgetCardID>) -> Void)? = nil

    @Published var cardOrder: [WidgetCardID] {
        didSet {
            save()
            onLayoutChange?()
        }
    }
    @Published var enabledCards: Set<WidgetCardID> {
        didSet {
            save()
            onLayoutChange?()
            let added = enabledCards.subtracting(oldValue)
            if !added.isEmpty {
                onCardsEnabled?(added)
            }
        }
    }
    @Published var dockedCards: Set<WidgetCardID> {
        didSet {
            save()
            onLayoutChange?()
        }
    }
    @Published var cardScales: [String: Double] {
        didSet {
            save()
            onLayoutChange?()
        }
    }

    private let orderKey = "bigu.settings.cardOrder"
    private let enabledKey = "bigu.settings.enabledCards"
    private let dockedKey = "bigu.settings.dockedCards"
    private let scaleKey = "bigu.settings.cardScales"
    private let updatePolicyKey = "bigu.settings.updatePolicy"

    @Published var updatePolicy: UpdatePolicy {
        didSet {
            UserDefaults.standard.set(updatePolicy.rawValue, forKey: updatePolicyKey)
        }
    }

    init() {
        // Load Order
        if let savedOrder = UserDefaults.standard.stringArray(forKey: orderKey) {
            var loaded = savedOrder.compactMap { raw in WidgetCardID(rawValue: raw) }
            for card in WidgetCardID.allCases where !loaded.contains(card) {
                loaded.append(card)
            }
            self.cardOrder = loaded
        } else {
            self.cardOrder = [.grok, .grokBot, .agy, .claudeGPT]
        }

        // Load Enabled Cards (ChatGPT is opt-in via Add provider)
        if let savedEnabled = UserDefaults.standard.stringArray(forKey: enabledKey) {
            self.enabledCards = Set(savedEnabled.compactMap { raw in WidgetCardID(rawValue: raw) })
        } else {
            self.enabledCards = [.grok, .grokBot, .agy, .claudeGPT]
        }

        // Load Docked Cards (default all docked true)
        if let savedDocked = UserDefaults.standard.stringArray(forKey: dockedKey) {
            self.dockedCards = Set(savedDocked.compactMap { raw in WidgetCardID(rawValue: raw) })
        } else {
            self.dockedCards = Set(WidgetCardID.allCases)
        }

        if let raw = UserDefaults.standard.string(forKey: updatePolicyKey),
           let policy = UpdatePolicy(rawValue: raw) {
            self.updatePolicy = policy
        } else {
            self.updatePolicy = .prompt
        }

        if let saved = UserDefaults.standard.dictionary(forKey: scaleKey) {
            var out: [String: Double] = [:]
            for (k, v) in saved {
                if let d = v as? Double { out[k] = d }
                else if let n = v as? NSNumber { out[k] = n.doubleValue }
            }
            self.cardScales = out
        } else {
            self.cardScales = [:]
        }
    }

    func scale(for card: WidgetCardID) -> Double {
        min(2.0, max(0.5, cardScales[card.rawValue] ?? 1.0))
    }

    func setScale(_ value: Double, for card: WidgetCardID) {
        let clamped = min(2.0, max(0.5, (value * 10).rounded() / 10))
        var next = cardScales
        next[card.rawValue] = clamped
        cardScales = next
    }

    func nudgeScale(_ card: WidgetCardID, by delta: Double) {
        setScale(scale(for: card) + delta, for: card)
    }

    func isEnabled(_ id: WidgetCardID) -> Bool {
        enabledCards.contains(id)
    }

    func toggleEnabled(_ id: WidgetCardID) {
        if enabledCards.contains(id) {
            enabledCards.remove(id)
        } else {
            enabledCards.insert(id)
        }
    }

    func isDocked(_ id: WidgetCardID) -> Bool {
        dockedCards.contains(id)
    }

    func toggleDocked(_ id: WidgetCardID) {
        if dockedCards.contains(id) {
            dockedCards.remove(id)
        } else {
            dockedCards.insert(id)
        }
    }

    func moveUp(_ id: WidgetCardID) {
        guard let idx = cardOrder.firstIndex(of: id), idx > 0 else { return }
        cardOrder.swapAt(idx, idx - 1)
    }

    func moveDown(_ id: WidgetCardID) {
        guard let idx = cardOrder.firstIndex(of: id), idx < cardOrder.count - 1 else { return }
        cardOrder.swapAt(idx, idx + 1)
    }

    func move(from: Int, to: Int) {
        guard from != to, cardOrder.indices.contains(from), cardOrder.indices.contains(to) else { return }
        var order = cardOrder
        let item = order.remove(at: from)
        order.insert(item, at: to)
        cardOrder = order
    }

    func enableCard(_ id: WidgetCardID) {
        if !cardOrder.contains(id) {
            cardOrder.append(id)
        }
        enabledCards.insert(id)
        if !dockedCards.contains(id) {
            dockedCards.insert(id)
        }
    }

    private func save() {
        UserDefaults.standard.set(cardOrder.map { $0.rawValue }, forKey: orderKey)
        UserDefaults.standard.set(Array(enabledCards).map { $0.rawValue }, forKey: enabledKey)
        UserDefaults.standard.set(Array(dockedCards).map { $0.rawValue }, forKey: dockedKey)
        UserDefaults.standard.set(cardScales, forKey: scaleKey)
    }
}

// MARK: - Widget Settings Sheet / Panel View

private struct SettingsReorderDropDelegate: DropDelegate {
    let target: WidgetCardID
    @Binding var dragging: WidgetCardID?
    let settings: WidgetLayoutSettings

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        guard let from = settings.cardOrder.firstIndex(of: dragging),
              let to = settings.cardOrder.firstIndex(of: target) else { return }
        if from != to {
            withAnimation(.easeInOut(duration: 0.18)) {
                settings.move(from: from, to: to)
            }
        }
    }
}

struct WidgetSettingsView: View {
    @ObservedObject var settings = WidgetLayoutSettings.shared
    var onClose: () -> Void
    var onSignIn: ((ServiceKind) -> Void)? = nil
    var onDonate: (() -> Void)? = nil
    var onAddProvider: (() -> Void)? = nil

    @State private var draggingCard: WidgetCardID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: 0x24C1E0))
                Text("Widget Settings")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .padding(5)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 2)

            Text("Toggle visibility, order, dock, and size (50%–200%).")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .background(Color.white.opacity(0.15))

            // Card List
            VStack(spacing: 7) {
                ForEach(settings.cardOrder) { card in
                    let isEn = settings.isEnabled(card)
                    let isDoc = settings.isDocked(card)

                    VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .frame(width: 16, height: 22)
                            .contentShape(Rectangle())
                            .help("Drag to reorder")
                            .onDrag {
                                draggingCard = card
                                return NSItemProvider(object: card.rawValue as NSString)
                            }

                        // Card Name & Status
                        VStack(alignment: .leading, spacing: 1) {
                            Text(card.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isEn ? Color.white.opacity(0.92) : Color.white.opacity(0.40))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Text(isDoc ? "Docked" : "Floating Window")
                                .font(.system(size: 8.5))
                                .foregroundStyle(isDoc ? Color(hex: 0x24C1E0).opacity(0.85) : Color(hex: 0xFBBC04).opacity(0.85))
                        }

                        Spacer()

                        // Dock / Undock Toggle Button
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                settings.toggleDocked(card)
                            }
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: isDoc ? "link" : "link.badge.plus")
                                    .font(.system(size: 9))
                                Text(isDoc ? "Docked" : "Floating")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3.5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isDoc ? Color.white.opacity(0.12) : Color(hex: 0xFBBC04).opacity(0.22))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(isDoc ? Color.white.opacity(0.2) : Color(hex: 0xFBBC04).opacity(0.45), lineWidth: 0.8)
                            )
                            .foregroundStyle(isDoc ? Color.white.opacity(0.8) : Color(hex: 0xFBBC04))
                        }
                        .buttonStyle(.plain)
                        .help(isDoc ? "Click to Undock into independent floating window" : "Click to Dock back into combined widget")

                        Button(action: { onSignIn?(card.serviceKind) }) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .help("Sign in to \(card.rawValue)")

                        // Enable / Disable Toggle
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                settings.toggleEnabled(card)
                            }
                        }) {
                            Image(systemName: isEn ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(isEn ? Color(hex: 0x32D74B) : Color.white.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        .help(isEn ? "Hide Widget" : "Show Widget")
                    }
                    HStack(spacing: 6) {
                        Text("Size")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.42))
                        Button(action: { settings.nudgeScale(card, by: -0.1) }) {
                            Text("−")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.8))
                                .frame(width: 22, height: 20)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        .disabled(settings.scale(for: card) <= 0.5)
                        Text("\(Int((settings.scale(for: card) * 100).rounded()))%")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.88))
                            .frame(width: 42)
                        Button(action: { settings.nudgeScale(card, by: 0.1) }) {
                            Text("+")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.8))
                                .frame(width: 22, height: 20)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        .disabled(settings.scale(for: card) >= 2.0)
                        if abs(settings.scale(for: card) - 1.0) > 0.01 {
                            Button("100%") {
                                settings.setScale(1.0, for: card)
                            }
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x24C1E0))
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(.top, 2)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(draggingCard == card ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
                    )
                    .onDrop(of: [.text], delegate: SettingsReorderDropDelegate(
                        target: card,
                        dragging: $draggingCard,
                        settings: settings
                    ))
                }

                Button(action: { onAddProvider?() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(hex: 0x24C1E0))
                            .frame(width: 16, height: 22)
                        Text("Add provider")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.78))
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            .foregroundStyle(Color.white.opacity(0.22))
                    )
                }
                .buttonStyle(.plain)
                .help("See other AI providers (not tracked yet)")
            }

            Divider()
                .background(Color.white.opacity(0.15))

            VStack(alignment: .leading, spacing: 6) {
                Text("Updates")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                Text("Checks GitHub. Prompt asks first. Auto downloads, replaces this app, and relaunches.")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(UpdatePolicy.allCases, id: \.self) { policy in
                        let on = settings.updatePolicy == policy
                        Button(action: { settings.updatePolicy = policy }) {
                            Text(policy == .off ? "Off" : policy == .prompt ? "Prompt" : "Auto")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(on ? Color(hex: 0x24C1E0).opacity(0.28) : Color.white.opacity(0.08))
                                )
                                .foregroundStyle(on ? Color(hex: 0x24C1E0) : Color.white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Button(action: { UpdateChecker.shared.checkNow() }) {
                        Text("Check")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 4)

            // Bottom action
            HStack {
                if onDonate != nil {
                    Button(action: { onDonate?() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 9))
                            Text("Donate")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color(hex: 0xFF8B82))
                    }
                    .buttonStyle(.plain)
                    .help("Support BigUwidget")
                }
                Spacer()
                Button(action: onClose) {
                    Text("Done")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(hex: 0x24C1E0))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 320, height: 620)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: 0x18181A).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.7), radius: 16, y: 6)
    }
}

// MARK: - Root Combined Widget View

struct RootCombinedWidgetView: View {
    @ObservedObject var masterStore: CombinedStore
    @ObservedObject var settings = WidgetLayoutSettings.shared
    var onClose: () -> Void
    var onMinimize: () -> Void
    var onOpenSettings: () -> Void
    var onOpenSessionHistory: (SingleServiceStore) -> Void
    var onOpenCalendar: (SingleServiceStore) -> Void
    var onOpenLogin: (ServiceKind) -> Void

    private var dockedCards: [WidgetCardID] {
        settings.cardOrder.filter { settings.isEnabled($0) && settings.isDocked($0) }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            VStack(spacing: 3.5) {
                if dockedCards.isEmpty {
                    // Empty placeholder when all cards are undocked or hidden
                    VStack(spacing: 8) {
                        HStack {
                            Text("BigUwidget")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.85))
                            Spacer()
                            Button(action: onOpenSettings) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)

                            Button(action: onMinimize) {
                                Image(systemName: "minus")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)

                            Button(action: onClose) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 2)

                        Text("All widgets are floating or hidden.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 8)
                    }
                    .padding(.all, 8)
                    .frame(width: 206)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(hex: 0x1C1C1E).opacity(0.48))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            )
                    )
                } else {
                    ForEach(dockedCards) { card in
                        let isFirst = card == dockedCards.first
                        LayoutScale(scale: CGFloat(settings.scale(for: card))) {
                            dockedServiceCard(card, now: context.date, isFirst: isFirst)
                                .frame(width: 206)
                        }
                    }
                }
            }
            .padding(.all, 4)
        }
    }

    @ViewBuilder
    private func dockedServiceCard(_ card: WidgetCardID, now: Date, isFirst: Bool) -> some View {
        switch card {
        case .grok:
            ServiceCardView(
                subStore: masterStore.grok,
                now: now,
                isMasterTop: isFirst,
                onMasterMinimize: onMinimize,
                onMasterClose: onClose,
                onOpenSettings: onOpenSettings,
                onOpenSessionHistory: { onOpenSessionHistory(masterStore.grok) },
                onOpenCalendar: { onOpenCalendar(masterStore.grok) },
                onRefresh: { masterStore.fetchNow(.grok) },
                onSignIn: { onOpenLogin(.grok) }
            )
        case .grokBot:
            ServiceCardView(
                subStore: masterStore.grokBot,
                now: now,
                isMasterTop: isFirst,
                onMasterMinimize: onMinimize,
                onMasterClose: onClose,
                onOpenSettings: onOpenSettings,
                onOpenSessionHistory: { onOpenSessionHistory(masterStore.grokBot) },
                onOpenCalendar: { onOpenCalendar(masterStore.grokBot) },
                onRefresh: { masterStore.fetchNow(.grokBot) },
                onSignIn: { onOpenLogin(.grokBot) }
            )
        case .agy:
            ServiceCardView(
                subStore: masterStore.agy,
                now: now,
                isMasterTop: isFirst,
                onMasterMinimize: onMinimize,
                onMasterClose: onClose,
                onOpenSettings: onOpenSettings,
                onOpenSessionHistory: { onOpenSessionHistory(masterStore.agy) },
                onOpenCalendar: { onOpenCalendar(masterStore.agy) },
                onRefresh: { masterStore.fetchNow(.agy) },
                onSignIn: { onOpenLogin(.agy) }
            )
        case .claudeGPT:
            ServiceCardView(
                subStore: masterStore.claudeGPT,
                now: now,
                isMasterTop: isFirst,
                onMasterMinimize: onMinimize,
                onMasterClose: onClose,
                onOpenSettings: onOpenSettings,
                onOpenSessionHistory: { onOpenSessionHistory(masterStore.claudeGPT) },
                onOpenCalendar: { onOpenCalendar(masterStore.claudeGPT) },
                onRefresh: { masterStore.fetchNow(.claudeGPT) },
                onSignIn: { onOpenLogin(.claudeGPT) }
            )
        case .chatGPT:
            ServiceCardView(
                subStore: masterStore.chatGPT,
                now: now,
                isMasterTop: isFirst,
                onMasterMinimize: onMinimize,
                onMasterClose: onClose,
                onOpenSettings: onOpenSettings,
                onOpenSessionHistory: { onOpenSessionHistory(masterStore.chatGPT) },
                onOpenCalendar: { onOpenCalendar(masterStore.chatGPT) },
                onRefresh: { masterStore.fetchNow(.chatGPT) },
                onSignIn: { onOpenLogin(.chatGPT) }
            )
        }
    }
}

// MARK: - Standalone Undocked Floating Card Container View

struct StandaloneCardWindowView: View {
    let cardID: WidgetCardID
    @ObservedObject var masterStore: CombinedStore
    @ObservedObject var settings = WidgetLayoutSettings.shared
    var onRedock: () -> Void
    var onClose: () -> Void
    var onOpenSessionHistory: (SingleServiceStore) -> Void
    var onOpenCalendar: (SingleServiceStore) -> Void
    var onOpenLogin: (ServiceKind) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            VStack(alignment: .leading, spacing: 3) {
                // Minimal title bar (Option B)
                HStack(alignment: .center, spacing: 4) {
                    Image(systemName: "circle.grid.2x1.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.white.opacity(0.35))
                    Text(cardID.displayName)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer()

                    // Re-dock button
                    Button(action: onRedock) {
                        Image(systemName: "link")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dock back into combined BigUwidget")

                    // Close button
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide Widget")
                }
                .padding(.horizontal, 6)
                .padding(.top, 3)

                LayoutScale(scale: CGFloat(settings.scale(for: cardID))) {
                    Group {
                        switch cardID {
                        case .grok:
                            ServiceCardView(
                                subStore: masterStore.grok,
                                now: context.date,
                                isMasterTop: false,
                                onOpenSessionHistory: { onOpenSessionHistory(masterStore.grok) },
                                onOpenCalendar: { onOpenCalendar(masterStore.grok) },
                                onRefresh: { masterStore.fetchNow(.grok) },
                                onSignIn: { onOpenLogin(.grok) }
                            )
                        case .grokBot:
                            ServiceCardView(
                                subStore: masterStore.grokBot,
                                now: context.date,
                                isMasterTop: false,
                                onOpenSessionHistory: { onOpenSessionHistory(masterStore.grokBot) },
                                onOpenCalendar: { onOpenCalendar(masterStore.grokBot) },
                                onRefresh: { masterStore.fetchNow(.grokBot) },
                                onSignIn: { onOpenLogin(.grokBot) }
                            )
                        case .agy:
                            ServiceCardView(
                                subStore: masterStore.agy,
                                now: context.date,
                                isMasterTop: false,
                                onOpenSessionHistory: { onOpenSessionHistory(masterStore.agy) },
                                onOpenCalendar: { onOpenCalendar(masterStore.agy) },
                                onRefresh: { masterStore.fetchNow(.agy) },
                                onSignIn: { onOpenLogin(.agy) }
                            )
                        case .claudeGPT:
                            ServiceCardView(
                                subStore: masterStore.claudeGPT,
                                now: context.date,
                                isMasterTop: false,
                                onOpenSessionHistory: { onOpenSessionHistory(masterStore.claudeGPT) },
                                onOpenCalendar: { onOpenCalendar(masterStore.claudeGPT) },
                                onRefresh: { masterStore.fetchNow(.claudeGPT) },
                                onSignIn: { onOpenLogin(.claudeGPT) }
                            )
                        case .chatGPT:
                            ServiceCardView(
                                subStore: masterStore.chatGPT,
                                now: context.date,
                                isMasterTop: false,
                                onOpenSessionHistory: { onOpenSessionHistory(masterStore.chatGPT) },
                                onOpenCalendar: { onOpenCalendar(masterStore.chatGPT) },
                                onRefresh: { masterStore.fetchNow(.chatGPT) },
                                onSignIn: { onOpenLogin(.chatGPT) }
                            )
                        }
                    }
                    .frame(width: 206)
                }
            }
            .padding(.all, 4)
        }
    }
}

// MARK: - Floating Panel & App Delegate

final class AutoFitHostingView<Content: View>: NSHostingView<Content> {
    var onFittingHeight: ((CGFloat) -> Void)?
    var onFittingSize: ((CGSize) -> Void)?
    private var lastHeight: CGFloat = -1
    private var lastWidth: CGFloat = -1

    override func layout() {
        super.layout()
        let s = fittingSize
        guard s.height > 0 else { return }
        if abs(s.height - lastHeight) <= 1, abs(s.width - lastWidth) <= 1 { return }
        lastHeight = s.height
        lastWidth = s.width
        onFittingSize?(s)
        onFittingHeight?(s.height)
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let masterStore = CombinedStore()
    let settings = WidgetLayoutSettings.shared

    var panel: FloatingPanel!
    var calendarPanel: FloatingPanel?
    var settingsPanel: FloatingPanel?
    var loginWindow: NSWindow?
    private var restoreSettingsAfterLogin = false
    var hosting: AutoFitHostingView<RootCombinedWidgetView>!

    // Undocked card panels dictionary
    var undockedPanels: [WidgetCardID: FloatingPanel] = [:]

    private let frameOriginXKey = "bigu.widget.origin.x"
    private let frameTopYKey = "bigu.widget.frame.maxY"

    func openSettingsWindow() {
        if let existing = settingsPanel {
            existing.orderFrontRegardless()
            return
        }
        let size = NSSize(width: 320, height: 620)
        let view = WidgetSettingsView(
            onClose: { [weak self] in
                self?.settingsPanel?.orderOut(nil)
                self?.settingsPanel = nil
                self?.syncUndockedWindows()
            },
            onSignIn: { [weak self] kind in
                self?.openLoginWindow(for: kind)
            },
            onDonate: { [weak self] in
                self?.openDonate()
            },
            onAddProvider: { [weak self] in
                self?.openLoginWindow(for: .agy, startOnOther: true)
            }
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let win = FloatingPanel(
            contentRect: host.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.collectionBehavior = [.managed, .fullScreenNone]
        win.isMovableByWindowBackground = true
        win.hidesOnDeactivate = false
        win.contentView = host
        win.setContentSize(size)

        if let screen = panel.screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            win.setFrameOrigin(NSPoint(
                x: vis.midX - size.width / 2,
                y: vis.midY - size.height / 2
            ))
        }
        settingsPanel = win
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func openLoginWindow(for service: ServiceKind, startOnOther: Bool = false) {
        loginWindow?.orderOut(nil)
        loginWindow = nil
        if let settingsPanel, settingsPanel.isVisible {
            restoreSettingsAfterLogin = true
            settingsPanel.orderOut(nil)
        }
        let size = NSSize(width: 860, height: 660)
        let view = ServiceLoginView(
            service: service,
            startOnOther: startOnOther,
            onCancel: { [weak self] in self?.closeLoginWindow() },
            onFinished: { [weak self] kind in
                self?.closeLoginWindow()
                self?.masterStore.fetchNow(kind)
            }
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Sign in to BigUwidget"
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.delegate = self
        win.contentView = host
        win.setContentSize(size)
        win.center()
        loginWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeLoginWindow() {
        loginWindow?.delegate = nil
        loginWindow?.orderOut(nil)
        loginWindow = nil
        if restoreSettingsAfterLogin {
            restoreSettingsAfterLogin = false
            settingsPanel?.orderFrontRegardless()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win === loginWindow else { return }
        loginWindow = nil
        if restoreSettingsAfterLogin {
            restoreSettingsAfterLogin = false
            settingsPanel?.orderFrontRegardless()
        }
    }

    func openDonate() {
        if let url = BigUwidgetConfig.donateURL {
            NSWorkspace.shared.open(url)
        }
    }

    func openCalendarWindow(for subStore: SingleServiceStore, initialTab: Int) {
        if let existing = calendarPanel {
            existing.orderOut(nil)
            calendarPanel = nil
        }
        let year = Calendar.current.component(.year, from: Date())
        let size = NSSize(width: 660, height: 680)
        let view = YearCalendarView(
            serviceName: subStore.service.rawValue,
            subStore: subStore,
            year: year,
            initialTab: initialTab,
            onClose: { [weak self] in
                self?.calendarPanel?.orderOut(nil)
                self?.calendarPanel = nil
            }
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let win = FloatingPanel(
            contentRect: host.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.collectionBehavior = [.managed, .fullScreenNone]
        win.isMovableByWindowBackground = true
        win.hidesOnDeactivate = false
        win.contentView = host
        win.setContentSize(size)
        if let screen = panel.screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            win.setFrameOrigin(NSPoint(
                x: vis.midX - size.width / 2,
                y: vis.midY - size.height / 2
            ))
        }
        calendarPanel = win
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupDockIcon()

        let root = RootCombinedWidgetView(
            masterStore: masterStore,
            onClose: { [weak self] in
                self?.calendarPanel?.orderOut(nil)
                self?.calendarPanel = nil
                self?.settingsPanel?.orderOut(nil)
                self?.settingsPanel = nil
                self?.panel.orderOut(nil)
            },
            onMinimize: { [weak self] in
                self?.calendarPanel?.orderOut(nil)
                self?.calendarPanel = nil
                self?.settingsPanel?.orderOut(nil)
                self?.settingsPanel = nil
                self?.panel.miniaturize(nil)
            },
            onOpenSettings: { [weak self] in
                self?.openSettingsWindow()
            },
            onOpenSessionHistory: { [weak self] sub in
                self?.openCalendarWindow(for: sub, initialTab: 0)
            },
            onOpenCalendar: { [weak self] sub in
                self?.openCalendarWindow(for: sub, initialTab: 2)
            },
            onOpenLogin: { [weak self] kind in
                self?.openLoginWindow(for: kind)
            }
        )

        hosting = AutoFitHostingView(rootView: root)
        hosting.onFittingSize = { [weak self] s in
            guard let self, let panel = self.panel else { return }
            self.applyFittedHeight(panel, height: s.height, width: max(160, s.width))
        }

        let defaultSize = NSSize(width: 206, height: 600)
        let initialFrame = NSRect(origin: NSPoint(x: 1476, y: 100), size: defaultSize)
        panel = FloatingPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "BigUwidget"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 1
        panel.hasShadow = false
        if #available(macOS 11.0, *) {
            panel.titlebarSeparatorStyle = .none
        }
        panel.level = .floating
        panel.collectionBehavior = [.managed, .fullScreenNone]
        panel.sharingType = .readOnly
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.setContentSize(defaultSize)

        restoreFrame()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowMoved),
            name: NSWindow.didMoveNotification,
            object: panel
        )

        // Initial sync of undocked floating windows
        syncUndockedWindows()

        // Hook settings changes directly to sync windows without infinite notification recursion
        settings.onLayoutChange = { [weak self] in
            DispatchQueue.main.async {
                self?.syncUndockedWindows()
            }
        }
        settings.onCardsEnabled = { [weak self] added in
            DispatchQueue.main.async {
                self?.masterStore.fetchCards(added)
            }
        }

        UpdateChecker.shared.checkSoon()
    }

    func syncUndockedWindows() {
        for card in WidgetCardID.allCases {
            let isEn = settings.isEnabled(card)
            let isDoc = settings.isDocked(card)

            if isEn && !isDoc {
                // Should have an undocked floating window
                if undockedPanels[card] == nil {
                    createUndockedWindow(for: card)
                }
            } else {
                // Close if docked or hidden
                if let win = undockedPanels[card] {
                    persistUndockedFrame(for: card, panel: win)
                    NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: win)
                    win.orderOut(nil)
                    undockedPanels.removeValue(forKey: card)
                }
            }
        }
    }

    private func createUndockedWindow(for card: WidgetCardID) {
        let view = StandaloneCardWindowView(
            cardID: card,
            masterStore: masterStore,
            onRedock: { [weak self] in
                withAnimation(.easeInOut(duration: 0.2)) {
                    self?.settings.toggleDocked(card)
                }
            },
            onClose: { [weak self] in
                withAnimation(.easeInOut(duration: 0.2)) {
                    self?.settings.toggleEnabled(card)
                }
            },
            onOpenSessionHistory: { [weak self] sub in
                self?.openCalendarWindow(for: sub, initialTab: 0)
            },
            onOpenCalendar: { [weak self] sub in
                self?.openCalendarWindow(for: sub, initialTab: 2)
            },
            onOpenLogin: { [weak self] kind in
                self?.openLoginWindow(for: kind)
            }
        )

        let host = AutoFitHostingView(rootView: view)
        let defaultSize = NSSize(width: 206, height: 260)
        let initialFrame = NSRect(origin: NSPoint(x: 1200, y: 300), size: defaultSize)

        let win = FloatingPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.title = card.rawValue
        win.isOpaque = false
        win.backgroundColor = .clear
        win.alphaValue = 1
        win.hasShadow = false
        if #available(macOS 11.0, *) {
            win.titlebarSeparatorStyle = .none
        }
        win.level = .floating
        win.collectionBehavior = [.managed, .fullScreenNone]
        win.sharingType = .readOnly
        win.isMovableByWindowBackground = true
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.hidesOnDeactivate = false
        win.contentView = host
        win.setContentSize(defaultSize)
        host.onFittingSize = { [weak self, weak win] s in
            guard let self, let win else { return }
            self.applyFittedHeight(win, height: s.height, width: max(160, s.width))
        }

        restoreUndockedFrame(for: card, panel: win)
        win.orderFrontRegardless()
        DispatchQueue.main.async { [weak self, weak win, weak host] in
            guard let self, let win, let host else { return }
            let s = host.fittingSize
            if s.height > 0 {
                self.applyFittedHeight(win, height: s.height, width: max(160, s.width))
            }
        }

        undockedPanels[card] = win

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(undockedWindowMoved(_:)),
            name: NSWindow.didMoveNotification,
            object: win
        )
    }

    @objc func undockedWindowMoved(_ notif: Notification) {
        guard let win = notif.object as? FloatingPanel else { return }
        for (card, panel) in undockedPanels where panel === win {
            persistUndockedFrame(for: card, panel: win)
            break
        }
    }

    private func applyFittedHeight(_ panel: NSPanel, height: CGFloat, width: CGFloat) {
        let screenH = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let h = min(screenH, max(80, height))
        let frame = panel.frame
        if abs(frame.height - h) < 1, abs(frame.width - width) < 1 { return }
        let top = frame.maxY
        let size = NSSize(width: width, height: h)
        var origin = NSPoint(x: frame.origin.x, y: top - h)
        origin = clampedOrigin(origin, size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func persistUndockedFrame(for card: WidgetCardID, panel: FloatingPanel) {
        let frame = panel.frame
        UserDefaults.standard.set(frame.origin.x, forKey: "bigu.floatOrigin.\(card.storageKey).x")
        UserDefaults.standard.set(frame.maxY, forKey: "bigu.floatTop.\(card.storageKey).y")
    }

    private func restoreUndockedFrame(for card: WidgetCardID, panel: FloatingPanel) {
        let defaults = UserDefaults.standard
        let currentSize = NSSize(width: 206, height: 260)
        let topKey = "bigu.floatTop.\(card.storageKey).y"
        let xKey = "bigu.floatOrigin.\(card.storageKey).x"

        var origin: NSPoint
        if defaults.object(forKey: topKey) != nil {
            let top = defaults.double(forKey: topKey)
            origin = NSPoint(
                x: defaults.double(forKey: xKey),
                y: top - currentSize.height
            )
        } else {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            origin = NSPoint(x: screen.maxX - currentSize.width - 240, y: screen.maxY - currentSize.height - 50)
        }
        origin = clampedOrigin(origin, size: currentSize)
        panel.setFrame(NSRect(origin: origin, size: currentSize), display: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        calendarPanel?.orderOut(nil)
        settingsPanel?.orderOut(nil)
        loginWindow?.orderOut(nil)
        for (card, win) in undockedPanels {
            persistUndockedFrame(for: card, panel: win)
            win.orderOut(nil)
        }
        persistFrame()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.orderFrontRegardless()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show BigUwidget", action: #selector(showFromDock), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh All", action: #selector(refreshFromDock), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Sign in to Grok…", action: #selector(loginGrok), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Sign in to Cursor…", action: #selector(loginGrokBot), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Sign in to AGY…", action: #selector(loginAGY), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Sign in to ChatGPT…", action: #selector(loginChatGPT), keyEquivalent: ""))
        if BigUwidgetConfig.donateURL != nil {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Donate", action: #selector(donateFromDock), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit BigUwidget", action: #selector(quitWidget), keyEquivalent: "q"))
        return menu
    }

    private func setupDockIcon() {
        let size: CGFloat = 512
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            img.unlockFocus()
            return
        }
        let pad = size * 0.08
        let rect = CGRect(x: pad, y: pad, width: size - 2 * pad, height: size - 2 * pad)
        let cornerRadius = size * 0.22
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // Dark gradient background
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            NSColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1.0).cgColor,
            NSColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1.0).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
            ctx.restoreGState()
        }

        // Cyan / Blue stroke rim
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(size * 0.035)
        ctx.setStrokeColor(NSColor(red: 0.14, green: 0.76, blue: 0.88, alpha: 0.90).cgColor)
        ctx.strokePath()
        ctx.restoreGState()

        // Buw Letters in bold typography
        let font = NSFont.systemFont(ofSize: size * 0.36, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: "Buw", attributes: attrs)
        let strSize = str.size()
        let strRect = CGRect(
            x: (size - strSize.width) / 2.0,
            y: (size - strSize.height) / 2.0 - size * 0.02,
            width: strSize.width,
            height: strSize.height
        )
        str.draw(in: strRect)

        img.unlockFocus()
        NSApp.applicationIconImage = img
    }

    @objc func showFromDock() {
        panel?.orderFrontRegardless()
    }

    @objc func refreshFromDock() {
        masterStore.fetchLiveNow()
    }

    @objc func loginGrok() { openLoginWindow(for: .grok) }
    @objc func loginGrokBot() { openLoginWindow(for: .grokBot) }
    @objc func loginAGY() { openLoginWindow(for: .agy) }
    @objc func loginChatGPT() { openLoginWindow(for: .chatGPT) }
    @objc func donateFromDock() { openDonate() }

    @objc func quitWidget() {
        NSApp.terminate(nil)
    }

    @objc func windowMoved() {
        persistFrame()
    }

    private func persistFrame() {
        guard let panel = panel else { return }
        let frame = panel.frame
        UserDefaults.standard.set(frame.origin.x, forKey: frameOriginXKey)
        UserDefaults.standard.set(frame.maxY, forKey: frameTopYKey)
    }

    private func restoreFrame() {
        guard let panel = panel else { return }
        let defaults = UserDefaults.standard
        let fitH = hosting.fittingSize.height
        let currentSize = NSSize(width: 206, height: max(80, fitH > 0 ? fitH : 450))
        var origin: NSPoint
        if defaults.object(forKey: frameTopYKey) != nil {
            let top = defaults.double(forKey: frameTopYKey)
            origin = NSPoint(
                x: defaults.double(forKey: frameOriginXKey),
                y: top - currentSize.height
            )
        } else {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            origin = NSPoint(x: screen.maxX - currentSize.width - 16, y: screen.maxY - currentSize.height - 10)
        }
        origin = clampedOrigin(origin, size: currentSize)
        panel.setFrame(NSRect(origin: origin, size: currentSize), display: true)
    }

    private func clampedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let screens = NSScreen.screens
        let targetRect = NSRect(origin: origin, size: size)
        let screen = screens.first(where: { $0.frame.intersects(targetRect) }) ?? NSScreen.main
        guard let s = screen else { return origin }
        let full = s.frame
        let vis = s.visibleFrame
        let minX = full.minX
        let maxX = max(minX, full.maxX - size.width)
        let minY = vis.minY
        // Allow widget to reach the absolute top of the screen (flush with menu bar / screen top)
        let maxY = max(minY, full.maxY - size.height)
        let x = min(max(origin.x, minX), maxX)
        let y = min(max(origin.y, minY), maxY)
        return NSPoint(x: x, y: y)
    }
}

// MARK: - Main & Single Instance

@main
enum BigUwidgetMain {
    static func main() {
        guard SingleInstance.claim() else { return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        _ = Unmanaged.passRetained(delegate)
        app.run()
    }
}

enum SingleInstance {
    static func claim() -> Bool {
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != mine &&
            ($0.bundleIdentifier == "com.jakubsokolowski.BigUwidget"
             || $0.executableURL?.lastPathComponent == "BigUwidget")
        }
        if !others.isEmpty {
            others.first?.activate(options: [.activateIgnoringOtherApps])
            return false
        }

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BigUwidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("instance.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        return true
    }
}
