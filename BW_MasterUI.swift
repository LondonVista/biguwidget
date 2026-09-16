import Cocoa
import SwiftUI
import WebKit

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
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .frame(width: isMasterTop ? 28 : 36, height: 28)
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
                                        .offset(x: -5, y: showsFive ? -14 : -9)
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
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(width: 20, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isWeekHidden ? "Show 7-day strip" : "Hide 7-day strip")
    }
}

