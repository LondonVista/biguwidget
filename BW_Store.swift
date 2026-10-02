import Cocoa
import SwiftUI
import WebKit

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
        let url = directoryURL.appendingPathComponent("claude-deltas.json")
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Double]] else { return [] }
        return Array(list.compactMap { d -> RecentDeltaItem? in
            guard let delta = d["delta"], let ts = d["timestamp"], abs(delta) < 30.0, delta > 0.005 else { return nil }
            return RecentDeltaItem(delta: delta, timestamp: ts)
        }.prefix(4))
    }

    private func yesterdayClose(before key: String) -> Double? {
        guard let day = UsageParser.dayKeyDate(key),
              let prev = Calendar.current.date(byAdding: .day, value: -1, to: day) else { return nil }
        return dailyMap[UsageParser.dayKey(for: prev)]?["close"]
    }

    /// The strip shows the whole calendar day. `currentPoolOnly` drops usage banked before
    /// the reset that opened the current period, so today's budget and "above" warning
    /// only see the new pool.
    func usedPercent(on key: String, currentPoolOnly: Bool = false) -> Double {
        let e = dailyMap[key] ?? [:]
        guard let open = e["open"], var close = e["close"] else { return 0.0 }

        if key == UsageParser.dayKey(for: Date()), case .ready(let snap) = state, !snap.rolledOver {
            close = snap.totalPercent
        }

        let resetsAt: Date? = {
            if case .ready(let snap) = state { return snap.resetsAt }
            return nil
        }()
        let bonus = effectiveAccumulated(on: key, resetsAt: resetsAt)
        let prevClose = yesterdayClose(before: key)
        let resetDay = UsageParser.isResetWeekday(key, reset: resetsAt)

        var effectiveOpen = open
        // A one-sample 0% reading used to freeze open at 0, so the strip showed the
        // whole weekly total. Borrow yesterday when the close never really left it.
        // A reset weekday that landed well below yesterday keeps open at 0.
        if effectiveOpen < 0.5, bonus < 0.5, let prevClose, prevClose > 0, close + 15 >= prevClose {
            let keptGoing = !resetDay || close + 0.5 >= prevClose
            if keptGoing {
                effectiveOpen = min(prevClose, close)
            }
        }
        // First post-reset sample was stored as both open and close, so the day showed 0.
        if resetDay, open > 0.5, abs(open - close) < 1, let prevClose, prevClose > close + 15 {
            effectiveOpen = 0
        }

        // Usage before a mid-day weekly reset, banked when the drop was recorded.
        var preReset = e["preReset"] ?? 0
        if currentPoolOnly, let resetsAt,
           let periodStart = Calendar.current.date(byAdding: .day, value: -7, to: resetsAt),
           UsageParser.dayKey(for: periodStart) == key {
            preReset = 0
        }
        return max(0, close - effectiveOpen) + preReset
    }

    /// Intra-week extra pool only. A scheduled weekly reset, a day that closed
    /// empty, and the old "copy yesterday's close as gain" bug are not bonus quota.
    func effectiveAccumulated(on key: String, resetsAt: Date?) -> Double {
        let entry = dailyMap[key] ?? [:]
        let acc = entry["accumulated"] ?? 0
        if acc < 0.5 { return 0 }
        if UsageParser.isResetWeekday(key, reset: resetsAt) { return 0 }

        let open = entry["open"] ?? 0
        let close = entry["close"] ?? 0
        if close < 0.5 { return 0 }
        if let prevClose = yesterdayClose(before: key),
           abs(acc - prevClose) < 1.5, open < 0.5 {
            return 0
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

    func daysForDisplay(now: Date = Date(), resetsAt: Date? = nil, centerToday: Bool = false) -> [DayUse] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)

        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        let dayLabels = ["", "S", "M", "T", "W", "T", "F", "S"]

        if centerToday {
            // [-3, -2, -1, 0, +1, +2, +3] so today is always in the center (index 3)
            return (-3...3).compactMap { offset -> DayUse? in
                guard let d = cal.date(byAdding: .day, value: offset, to: today) else { return nil }
                let key = fmt.string(from: d)
                let gain = effectiveAccumulated(on: key, resetsAt: resetsAt)
                let weekdayIdx = cal.component(.weekday, from: d)
                let label = (weekdayIdx >= 1 && weekdayIdx <= 7) ? dayLabels[weekdayIdx] : "?"
                return DayUse(key: key, label: label, percent: usedPercent(on: key), accumulatedGain: gain)
            }
        } else {
            let weekday = cal.component(.weekday, from: today)
            let isoMondayOffset = (weekday + 5) % 7
            guard let monday = cal.date(byAdding: .day, value: -isoMondayOffset, to: today) else {
                return placeholderWeek()
            }

            let labels = ["M", "T", "W", "T", "F", "S", "S"]
            return (0..<7).compactMap { i -> DayUse? in
                guard let d = cal.date(byAdding: .day, value: i, to: monday) else { return nil }
                let key = fmt.string(from: d)
                let gain = effectiveAccumulated(on: key, resetsAt: resetsAt)
                return DayUse(key: key, label: labels[i], percent: usedPercent(on: key), accumulatedGain: gain)
            }
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
        fmt.timeZone = cal.timeZone
        fmt.dateFormat = "yyyy-MM-dd"

        var gain = 0.0
        for i in 0..<7 {
            if let d = cal.date(byAdding: .day, value: i, to: monday) {
                let key = fmt.string(from: d)
                gain += effectiveAccumulated(on: key, resetsAt: resetsAt)
            }
        }

        // This calendar week already includes its own days. Only pull bonus from
        // the part of the quota cycle that started before Monday.
        if gain < 0.1, let reset = resetsAt {
            let cycleStart = cal.date(byAdding: .day, value: -7, to: reset) ?? today.addingTimeInterval(-7 * 86400)
            var cur = cal.startOfDay(for: cycleStart)
            while cur < monday {
                gain += effectiveAccumulated(on: fmt.string(from: cur), resetsAt: resetsAt)
                guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
                cur = next
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
        // Only a drop that still counts as extra quota. A weekly reset observed
        // the next morning used to be stored here, labeled as an Antigravity reset.
        let resetAt: Date? = {
            if case .ready(let snap) = state { return snap.resetsAt }
            return nil
        }()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        for dayKey in dailyMap.keys {
            let gain = effectiveAccumulated(on: dayKey, resetsAt: resetAt)
            if gain >= 0.5, !records.contains(where: { $0.dateStr == dayKey }) {
                let ts = (fmt.date(from: dayKey)?.timeIntervalSince1970) ?? Date().timeIntervalSince1970
                let autoRec = QuotaResetRecord(
                    timestamp: ts,
                    dateStr: dayKey,
                    displayTitle: "Intra-Week Reset",
                    gainedPercent: gain,
                    type: "intraweek",
                    note: "\(service.displayName) quota dropped. \(Int(gain.rounded()))% was counted as an extra reset."
                )
                records.append(autoRec)
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
            var e: [String: Double] = [
                "open": (v["open"] as? NSNumber)?.doubleValue ?? 0,
                "close": (v["close"] as? NSNumber)?.doubleValue ?? 0,
                "accumulated": (v["accumulated"] as? NSNumber)?.doubleValue ?? 0
            ]
            if let pre = (v["preReset"] as? NSNumber)?.doubleValue { e["preReset"] = pre }
            out[k] = e
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
                return directoryURL.appendingPathComponent("claude-deltas.json")
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
            df.locale = Locale(identifier: "en_US_POSIX")
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
        records = Self.withoutPhantomDeltas(records)
        records.sort { $0.timestamp < $1.timestamp }
        cachedSessionDeltas = records.reversed()
        sessionCacheValid = true
        sessionCacheStamp = stamp
        return cachedSessionDeltas
    }

    /// A prompt whose size is the whole total, and that total was already logged, is a wiped baseline.
    private static func withoutPhantomDeltas(_ records: [SessionDeltaRecord]) -> [SessionDeltaRecord] {
        let ordered = records.sorted { $0.timestamp < $1.timestamp }
        var kept: [SessionDeltaRecord] = []
        var lastTotal = 0.0
        for rec in ordered {
            let phantom = rec.weeklyTotal > 1
                && abs(rec.weeklyDelta - rec.weeklyTotal) < 0.05
                && abs(lastTotal - rec.weeklyTotal) < 0.05
            if phantom { continue }
            kept.append(rec)
            if rec.weeklyTotal > 0.5 { lastTotal = rec.weeklyTotal }
        }
        return kept
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
        var rLabel = d["resetsLabel"] as? String ?? ""

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
        var official = (d["officialPercent"] as? NSNumber)?.doubleValue
        var rDate = (d["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        if service == .agy, let gemini = quotaGroup(namedContains: "gemini") {
            applyQuotaGroup(gemini, total: &total, resetsAt: &rDate, fiveUsed: &fiveUsed, fiveReset: &fiveReset, slices: &slices, sliceName: "Gemini")
        }
        if service == .claudeGPT, slices.contains(where: { $0.name.contains("Claude") }) == false,
           let claude = quotaGroup(namedContains: "claude") ?? quotaGroup(namedContains: "gpt") {
            applyQuotaGroup(claude, total: &total, resetsAt: &rDate, fiveUsed: &fiveUsed, fiveReset: &fiveReset, slices: &slices, sliceName: "Claude & GPT")
        }

        // A reset has passed but no reading of the new period has landed yet (offline,
        // signed out, or an empty reply). Last week's number is no longer true: the pool is fresh.
        var rolledOver = false
        if let r = rDate, r <= Date() {
            rolledOver = true
            total = 0
            official = official.map { _ in 0 }
            slices = slices.map { UsageSlice(name: $0.name, percent: 0, color: $0.color) }
            rDate = nil
            rLabel = "Reset — waiting for new data"
        }
        var fiveLabelShown = fiveLabel
        if let f = fiveReset, f <= Date() {
            fiveUsed = 0
            fiveReset = nil
            fiveLabelShown = nil
        }

        var recentDeltas: [RecentDeltaItem] = []
        if let rawDeltaList = d["recentDeltas"] as? [[String: Any]] {
            recentDeltas = rawDeltaList.compactMap { item in
                guard let delta = (item["delta"] as? NSNumber)?.doubleValue,
                      let ts = (item["timestamp"] as? NSNumber)?.doubleValue,
                      delta > 0.005 else { return nil }
                return RecentDeltaItem(delta: delta, timestamp: ts)
            }
        }
        if recentDeltas.isEmpty {
            recentDeltas = loadRecentDeltasFromDisk()
        }
        if recentDeltas.isEmpty && service == .agy {
            recentDeltas = loadGeminiDeltas()
        }
        if recentDeltas.isEmpty && service == .claudeGPT {
            recentDeltas = loadLegacyClaudeDeltas()
        }

        let prepaidBalance = (d["prepaidBalance"] as? NSNumber)?.doubleValue
        let onDemandEligible = (d["onDemandEligible"] as? NSNumber)?.boolValue ?? (d["onDemandEligible"] as? Bool ?? false)
        let onDemandUsed = (d["onDemandUsed"] as? NSNumber)?.doubleValue

        return UsageSnapshot(
            totalPercent: total,
            resetsAt: rDate,
            resetsLabel: rLabel,
            slices: slices,
            daily: daysForDisplay(now: Date(), resetsAt: rDate),
            yesterdayUsed: nil,
            fiveHourPercent: fiveUsed,
            fiveHourResetsAt: fiveReset,
            fiveHourResetsLabel: fiveLabelShown,
            planLabel: plan,
            fetchedAt: fDate,
            recentDeltas: recentDeltas,
            prepaidBalance: prepaidBalance,
            onDemandEligible: onDemandEligible,
            onDemandUsed: onDemandUsed,
            rolledOver: rolledOver,
            officialPercent: official
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
            guard let rem = (b["remainingFraction"] as? NSNumber)?.doubleValue else { continue }
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

