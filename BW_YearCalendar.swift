import Cocoa
import SwiftUI
import WebKit

struct YearCalendarView: View {
    let serviceName: String
    @ObservedObject var subStore: SingleServiceStore
    var year: Int
    var initialTab: Int = 0
    var onClose: () -> Void

    var isClaudeGPT: Bool { subStore.service == .claudeGPT }

    @State var selectedTab: Int = 0
    @State var groupingMode: SessionGroupingMode = .auto
    @State var filterOnlySessions: Bool = false
    @State var expandedSessionIds: Set<String> = []

    // Interactive Graphs States
    @State var selectedTimeframe: GraphTimeframe = .day
    @State var dayOffset: Int = 0
    @State var weekOffset: Int = 0
    @State var monthOffset: Int = 0

    @State var hoveredHour: Int? = nil
    @State var selectedHour: Int? = nil

    @State var hoveredDayKey: String? = nil
    @State var selectedDayKey: String? = nil

    // Quota Resets State
    @State var isAddingManualReset: Bool = false
    @State var newResetDateStr: String = ""
    @State var newResetGainStr: String = "100.0"
    @State var newResetTitle: String = "Google Manual Reset"
    @State var newResetNote: String = "Manual quota refresh from Google"

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

    func resetsQuickBanner() -> some View {
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

    func resetsTabView(cal: Calendar) -> some View {
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

    func interactiveGraphsView(
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

    func claudeGPTQuotaHeroBanner(snap: UsageSnapshot) -> some View {
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

    func timeframeControlBar(
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

    var hasActiveFilter: Bool {
        if selectedTimeframe == .day { return selectedHour != nil }
        return selectedDayKey != nil
    }

    var isCurrentPeriodActive: Bool {
        switch selectedTimeframe {
        case .day: return dayOffset == 0
        case .week: return weekOffset == 0
        case .month: return monthOffset == 0
        }
    }

    func currentPeriodLabel(
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

    func periodSubtitle(
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

    func todayStatsBanner(data: TodayGraphData) -> some View {
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

    func todayHourlyBarChart(data: TodayGraphData) -> some View {
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

    func hourlyBarColumn(bin: HourlyUsageBin, maxDelta: Double) -> some View {
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

    func inspectorHudBanner(data: TodayGraphData) -> some View {
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

    func todayPromptsList(data: TodayGraphData) -> some View {
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

    func weeklyStatsBanner(data: WeeklyGraphData) -> some View {
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

    func weeklyBarChart(data: WeeklyGraphData) -> some View {
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

    func weeklyDayColumn(bin: DailyUsageBin, maxDelta: Double) -> some View {
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

    func weeklyInspectorHudBanner(data: WeeklyGraphData) -> some View {
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

    func weeklyPromptsList(data: WeeklyGraphData) -> some View {
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

}
