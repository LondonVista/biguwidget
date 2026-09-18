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
        // yesterday's close when this day is a real reset (weekly reset or intra-week reset to ~0).
        var effectiveOpen = open
        if effectiveOpen == 0 && bonus < 0.5 && !UsageParser.isResetWeekday(key, reset: resetsAt) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd"
            if let d = fmt.date(from: key),
               let prevD = Calendar.current.date(byAdding: .day, value: -1, to: d) {
                let prevKey = fmt.string(from: prevD)
                if let prevEntry = dailyMap[prevKey], let prevClose = prevEntry["close"], prevClose > 0, close >= prevClose {
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

