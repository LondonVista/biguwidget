import Cocoa
import SwiftUI
import WebKit

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

    @Published var globalScale: Double {
        didSet {
            UserDefaults.standard.set(globalScale, forKey: globalScaleKey)
            onLayoutChange?()
        }
    }

    @Published var backgroundOpacity: Double {
        didSet {
            UserDefaults.standard.set(backgroundOpacity, forKey: opacityKey)
            onLayoutChange?()
        }
    }

    @Published var centerTodayInWeekStrip: Bool {
        didSet {
            UserDefaults.standard.set(centerTodayInWeekStrip, forKey: centerTodayKey)
            onLayoutChange?()
        }
    }

    @Published var showProjectedFutureDays: Bool {
        didSet {
            UserDefaults.standard.set(showProjectedFutureDays, forKey: projectedKey)
            onLayoutChange?()
        }
    }

    private let orderKey = "bigu.settings.cardOrder"
    private let enabledKey = "bigu.settings.enabledCards"
    private let dockedKey = "bigu.settings.dockedCards"
    private let scaleKey = "bigu.settings.cardScales"
    private let globalScaleKey = "bigu.settings.globalScale"
    private let opacityKey = "bigu.settings.backgroundOpacity"
    private let updatePolicyKey = "bigu.settings.updatePolicy"
    private let centerTodayKey = "bigu.settings.centerTodayInWeekStrip"
    private let projectedKey = "bigu.settings.showProjectedFutureDays"

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

        self.centerTodayInWeekStrip = UserDefaults.standard.bool(forKey: centerTodayKey)
        self.showProjectedFutureDays = UserDefaults.standard.bool(forKey: projectedKey)

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

        if UserDefaults.standard.object(forKey: globalScaleKey) != nil {
            let val = UserDefaults.standard.double(forKey: globalScaleKey)
            self.globalScale = min(2.0, max(0.5, val))
        } else {
            self.globalScale = 1.0
        }

        if UserDefaults.standard.object(forKey: opacityKey) != nil {
            self.backgroundOpacity = UserDefaults.standard.double(forKey: opacityKey)
        } else {
            self.backgroundOpacity = 0.48
        }
    }

    func scale(for card: WidgetCardID) -> Double {
        let base = cardScales[card.rawValue] ?? 1.0
        return min(2.5, max(0.4, ((base * globalScale) * 100).rounded() / 100))
    }

    func setScale(_ value: Double, for card: WidgetCardID) {
        let clamped = min(2.0, max(0.5, (value * 10).rounded() / 10))
        var next = cardScales
        next[card.rawValue] = clamped
        cardScales = next
    }

    func nudgeScale(_ card: WidgetCardID, by delta: Double) {
        let current = cardScales[card.rawValue] ?? 1.0
        setScale(current + delta, for: card)
    }

    func setGlobalScale(_ value: Double) {
        let clamped = min(2.0, max(0.5, (value * 20).rounded() / 20))
        globalScale = clamped
    }

    func nudgeGlobalScale(by delta: Double) {
        setGlobalScale(globalScale + delta)
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
        VStack(spacing: 0) {
            // HEADER
            HStack(alignment: .center) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: 0x24C1E0))
                Text("Widget Settings")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.95))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .padding(4.5)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 13)
            .padding(.top, 11)
            .padding(.bottom, 7)

            Divider()
                .background(Color.white.opacity(0.15))

            // MAIN CONTENT (NO SCROLLVIEW - ALL COMPACT AND VISIBLE)
            VStack(alignment: .leading, spacing: 9) {
                // 1. Widget Size & Scale
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Color(hex: 0x24C1E0))
                        Text("Widget Size & Scale")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.92))
                        Spacer()
                        let zoomPct = Int((settings.globalScale * 100).rounded())
                        Text("\(zoomPct)%")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(hex: 0x24C1E0))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule().fill(Color(hex: 0x24C1E0).opacity(0.18))
                            )
                    }

                    HStack(spacing: 5) {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                settings.nudgeGlobalScale(by: -0.05)
                            }
                        }) {
                            Text("−")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.85))
                                .frame(width: 22, height: 20)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.10)))
                        }
                        .buttonStyle(.plain)
                        .disabled(settings.globalScale <= 0.5)

                        Slider(value: $settings.globalScale, in: 0.5...2.0, step: 0.05)
                            .tint(Color(hex: 0x24C1E0))
                            .controlSize(.small)

                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                settings.nudgeGlobalScale(by: 0.05)
                            }
                        }) {
                            Text("+")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.85))
                                .frame(width: 22, height: 20)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.10)))
                        }
                        .buttonStyle(.plain)
                        .disabled(settings.globalScale >= 2.0)

                        if abs(settings.globalScale - 1.0) > 0.01 {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    settings.setGlobalScale(1.0)
                                }
                            }) {
                                Text("100%")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color(hex: 0x24C1E0))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(hex: 0x24C1E0).opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Keyboard Shortcuts Description (single ultra-clean line)
                    HStack(spacing: 4) {
                        Image(systemName: "command")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color(hex: 0x24C1E0))
                        Text("⌘+ In")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.88))
                        Text("·")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.3))
                        Text("⌘− Out")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.88))
                        Text("·")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.3))
                        Text("⌘0 Reset")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.88))
                        Spacer()
                        Text("(when widget active)")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                }

                Divider()
                    .background(Color.white.opacity(0.10))

                // 2. Sections & Cards
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Color(hex: 0x24C1E0))
                        Text("Sections & Cards")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.92))
                        Spacer()
                        Text("Drag to reorder")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }

                    VStack(spacing: 3.5) {
                        ForEach(settings.cardOrder) { card in
                            let isEn = settings.isEnabled(card)
                            let isDoc = settings.isDocked(card)

                            HStack(spacing: 6) {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.40))
                                    .frame(width: 14, height: 18)
                                    .contentShape(Rectangle())
                                    .help("Drag to reorder")
                                    .onDrag {
                                        draggingCard = card
                                        return NSItemProvider(object: card.rawValue as NSString)
                                    }

                                // Card Name & Status
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(card.displayName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(isEn ? Color.white.opacity(0.92) : Color.white.opacity(0.40))
                                        .lineLimit(1)
                                    Text(isDoc ? "Docked" : "Floating Window")
                                        .font(.system(size: 8.5))
                                        .foregroundStyle(isDoc ? Color(hex: 0x24C1E0).opacity(0.85) : Color(hex: 0xFBBC04).opacity(0.85))
                                }

                                Spacer()

                                // Dock / Undock Toggle Button
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        settings.toggleDocked(card)
                                    }
                                }) {
                                    HStack(spacing: 2.5) {
                                        Image(systemName: isDoc ? "link" : "link.badge.plus")
                                            .font(.system(size: 9))
                                        Text(isDoc ? "Docked" : "Floating")
                                            .font(.system(size: 9, weight: .medium))
                                    }
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(isDoc ? Color.white.opacity(0.10) : Color(hex: 0xFBBC04).opacity(0.20))
                                    )
                                    .foregroundStyle(isDoc ? Color.white.opacity(0.75) : Color(hex: 0xFBBC04))
                                }
                                .buttonStyle(.plain)
                                .help(isDoc ? "Click to Undock into independent floating window" : "Click to Dock back into combined widget")

                                Button(action: { onSignIn?(card.serviceKind) }) {
                                    Image(systemName: "person.crop.circle")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.white.opacity(0.50))
                                }
                                .buttonStyle(.plain)
                                .help("Sign in to \(card.rawValue)")

                                // Enable / Disable Toggle
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        settings.toggleEnabled(card)
                                    }
                                }) {
                                    Image(systemName: isEn ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(isEn ? Color(hex: 0x32D74B) : Color.white.opacity(0.3))
                                }
                                .buttonStyle(.plain)
                                .help(isEn ? "Hide Widget" : "Show Widget")
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(draggingCard == card ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
                            )
                            .onDrop(of: [.text], delegate: SettingsReorderDropDelegate(
                                target: card,
                                dragging: $draggingCard,
                                settings: settings
                            ))

                            if card == .grokBot {
                                Button(action: { onSignIn?(.grokBot) }) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.system(size: 8.5, weight: .bold))
                                            .foregroundStyle(Color(hex: 0x24C1E0))
                                        Image(systemName: "key.fill")
                                            .font(.system(size: 8.5))
                                            .foregroundStyle(Color(hex: 0x24C1E0))
                                        Text("Cursor Login")
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .foregroundStyle(Color.white.opacity(0.90))
                                        Spacer()
                                        Text("cursor.com/login")
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundStyle(Color.white.opacity(0.45))
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 7.5, weight: .bold))
                                            .foregroundStyle(Color.white.opacity(0.4))
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3.5)
                                    .padding(.leading, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(Color(hex: 0x24C1E0).opacity(0.09))
                                    )
                                }
                                .buttonStyle(.plain)
                                .help("Sign in to Cursor (cursor.com/login) to track Grok Bot quota")
                            }
                        }

                        Button(action: { onAddProvider?() }) {
                            HStack(spacing: 5) {
                                Image(systemName: "plus")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(Color(hex: 0x24C1E0))
                                Text("Add provider")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.75))
                                Spacer()
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 0.7, dash: [4, 3]))
                                    .foregroundStyle(Color.white.opacity(0.20))
                            )
                        }
                        .buttonStyle(.plain)
                        .help("See other AI providers (not tracked yet)")
                    }
                }

                Divider()
                    .background(Color.white.opacity(0.10))

                // 3. Weekly Strip & Calendar Options
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Color(hex: 0x24C1E0))
                        Text("Weekly 7-Day Strip")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.92))
                    }

                    VStack(alignment: .leading, spacing: 3.5) {
                        // Toggle 1: Center Today
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                settings.centerTodayInWeekStrip.toggle()
                            }
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: settings.centerTodayInWeekStrip ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(settings.centerTodayInWeekStrip ? Color(hex: 0x24C1E0) : Color.white.opacity(0.35))
                                Text("Center Today (3 days past · Today · 3 days ahead)")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.85))
                                Spacer()
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(settings.centerTodayInWeekStrip ? Color(hex: 0x24C1E0).opacity(0.10) : Color.white.opacity(0.04))
                            )
                        }
                        .buttonStyle(.plain)

                        // Toggle 2: Show Future Projected Budget in Green
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                settings.showProjectedFutureDays.toggle()
                            }
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: settings.showProjectedFutureDays ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(settings.showProjectedFutureDays ? Color(hex: 0x32D74B) : Color.white.opacity(0.35))
                                Text("Show Future Days Projected Budget (in Green)")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.85))
                                Spacer()
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(settings.showProjectedFutureDays ? Color(hex: 0x32D74B).opacity(0.10) : Color.white.opacity(0.04))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()
                    .background(Color.white.opacity(0.10))

                // 4. Appearance & Glass Transparency
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Color(hex: 0x24C1E0))
                        Text("Appearance & Glass Transparency")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.92))
                        Spacer()
                        let clearPct = Int(((1.0 - settings.backgroundOpacity) * 100).rounded())
                        Text("\(clearPct)% Clear")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(hex: 0x32D74B))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule().fill(Color(hex: 0x32D74B).opacity(0.18))
                            )
                    }

                    HStack(spacing: 6) {
                        Slider(value: $settings.backgroundOpacity, in: 0.05...0.98, step: 0.01)
                            .tint(Color(hex: 0x32D74B))
                            .controlSize(.small)

                        Text("\(Int((settings.backgroundOpacity * 100).rounded()))%")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.75))
                            .frame(width: 30, alignment: .trailing)
                    }

                    HStack(spacing: 3) {
                        Text("Presets:")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.45))
                        
                        let presets: [(name: String, val: Double)] = [
                            ("Ghost 10%", 0.10),
                            ("Clear 28%", 0.28),
                            ("BigU 48%", 0.48),
                            ("Dark 75%", 0.75),
                            ("Solid 95%", 0.95)
                        ]
                        
                        ForEach(presets, id: \.name) { preset in
                            let isSelected = abs(settings.backgroundOpacity - preset.val) < 0.03
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    settings.backgroundOpacity = preset.val
                                }
                            }) {
                                Text(preset.name)
                                    .font(.system(size: 8.2, weight: isSelected ? .bold : .medium))
                                    .padding(.horizontal, 3.5)
                                    .padding(.vertical, 2.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                            .fill(isSelected ? Color(hex: 0x32D74B).opacity(0.28) : Color.white.opacity(0.08))
                                    )
                                    .foregroundStyle(isSelected ? Color(hex: 0x32D74B) : Color.white.opacity(0.75))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider()
                    .background(Color.white.opacity(0.10))

                // 4. Updates
                VStack(alignment: .leading, spacing: 3.5) {
                    HStack {
                        Text("Updates")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.88))
                        Spacer()
                        Button(action: { UpdateChecker.shared.checkNow() }) {
                            Text("Check Now")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x24C1E0))
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 4) {
                        ForEach(UpdatePolicy.allCases, id: \.self) { policy in
                            let on = settings.updatePolicy == policy
                            Button(action: { settings.updatePolicy = policy }) {
                                Text(policy == .off ? "Off" : policy == .prompt ? "Prompt" : "Auto")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(on ? Color(hex: 0x24C1E0).opacity(0.28) : Color.white.opacity(0.08))
                                    )
                                    .foregroundStyle(on ? Color(hex: 0x24C1E0) : Color.white.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)

            Divider()
                .background(Color.white.opacity(0.15))

            // FOOTER
            HStack {
                if onDonate != nil {
                    Button(action: { onDonate?() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 8.5))
                            Text("Donate")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(Color(hex: 0xFF8B82))
                    }
                    .buttonStyle(.plain)
                    .help("Support BigUwidget")
                }
                if let fbURL = BigUwidgetConfig.feedbackURL {
                    Button(action: { NSWorkspace.shared.open(fbURL) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                                .font(.system(size: 8.5))
                            Text("Feedback")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Color.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .help("Report a bug or submit feedback on GitHub")
                }
                Spacer()
                Text("v\(BigUwidgetConfig.appVersion)")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.38))
                Spacer()
                Button(action: onClose) {
                    Text("Done")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color(hex: 0x24C1E0))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: 0x18181A).opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.7), radius: 18, y: 6)
    }
}

