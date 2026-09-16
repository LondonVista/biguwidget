import Cocoa
import SwiftUI
import WebKit

// MARK: - Public links (edit before you ship)

enum BigUwidgetConfig {
    /// Ko-fi / GitHub Sponsors / PayPal. Donate is hidden if this is nil.
    static let donateURL = URL(string: "https://ko-fi.com/london_vista")
    static let feedbackURL = URL(string: "https://github.com/LondonVista/biguwidget/issues/new?title=%5BFeedback%2FBug%5D+v1.1.6&body=%2A%2AOS%2A%2A%3A+macOS%0A%2A%2AVersion%2A%2A%3A+v1.1.6%0A%0A%2A%2ADescribe+the+issue+or+feedback%2A%2A%3A%0A")
    static let appVersion = "1.1.6"
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
        if hours <= 24 { return Color(hex: 0x32D74B) } // Near reset (< 24h) -> Vibrant Green
        if hours <= 48 { return Color(hex: 0xFFD60A) } // Moderate (24h - 48h) -> Gold / Yellow
        return Color(hex: 0xFF9F0A)                    // Far away (> 48h) -> Orange
    }

    static func fiveHourCountdownColor(until date: Date, now: Date = Date()) -> Color {
        let minutes = date.timeIntervalSince(now) / 60
        if minutes <= 60 { return Color(hex: 0x32D74B) } // Close to 5h reset (<= 1h) -> Vibrant Green
        if minutes <= 120 { return Color(hex: 0xFFD60A) } // Medium (1h - 2h) -> Gold / Yellow
        return Color(hex: 0xFF9F0A)                      // Far away (> 2h) -> Orange
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
