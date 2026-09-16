import Cocoa
import SwiftUI
import WebKit


extension YearCalendarView {
    // MARK: - Month (30d) Graph Subviews

    func monthlyStatsBanner(data: MonthlyGraphData) -> some View {
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

    func monthlyBarChart(data: MonthlyGraphData) -> some View {
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

    func monthlyDayColumn(bin: DailyUsageBin, maxDelta: Double) -> some View {
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

    func monthlyInspectorHudBanner(data: MonthlyGraphData) -> some View {
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

    func monthlyPromptsList(data: MonthlyGraphData) -> some View {
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

    func dayOrRangePromptsList(
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

    func sessionsView(sessions: [UsageSession], totalRecorded: Double) -> some View {
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

    func sessionStatsBanner(sessions: [UsageSession], totalRecorded: Double) -> some View {
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

    func statTile(title: String, value: String, subtext: String, icon: String, accentColor: Color) -> some View {
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

    func sessionCard(_ session: UsageSession) -> some View {
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

    var modelBadgeLabel: String {
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

    var modelBadgeColor: Color {
        if isClaudeGPT {
            return Color(hex: 0xF28B82)
        } else if serviceName == "AGY" {
            return Color(hex: 0x24C1E0)
        } else {
            return Color(hex: 0x1E88E5)
        }
    }

    func estimatedTokensLabel(delta: Double) -> String {
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

    func promptRow(rec: SessionDeltaRecord, prevTimestamp: Double?) -> some View {
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

    func manualResetFormView() -> some View {
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

    func resetRowView(r: QuotaResetRecord) -> some View {
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

    func quotaResetsCard(cal: Calendar) -> some View {
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

    func calendarTabView(cal: Calendar) -> some View {
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

    func promptActivityView(records: [SessionDeltaRecord], totalDeltas: Double) -> some View {
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

    func timeAgo(_ ts: Double) -> String {
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

    func yearSum() -> Double {
        subStore.dailyMap.reduce(0) { acc, kv in
            kv.key.hasPrefix(String(year)) ? acc + subStore.usedPercent(on: kv.key) : acc
        }
    }

    func monthBlock(_ month: Int, calendar cal: Calendar) -> some View {
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

    func dayCell(dayNum: Int, key: String, isToday: Bool) -> some View {
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

    func weekTotal(row: Int, mondayOffset: Int, start: Date, daysInMonth: Int, cal: Calendar, fmt: DateFormatter) -> some View {
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

    func weeksBlock(calendar cal: Calendar) -> some View {
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

    func monthsSummary(calendar cal: Calendar) -> some View {
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
