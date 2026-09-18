import Cocoa
import SwiftUI
import WebKit

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

