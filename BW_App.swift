import Cocoa
import SwiftUI
import WebKit

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

    override func mouseDown(with event: NSEvent) {
        // If clicking on an area that is not an active control, allow dragging the window
        super.mouseDown(with: event)
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        performDrag(with: event)
    }
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
        PrefsMigrate.fromLegacyBundleIfNeeded()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        _ = Unmanaged.passRetained(delegate)
        app.run()
    }
}

enum PrefsMigrate {
    static func fromLegacyBundleIfNeeded() {
        let flag = "bigu.migratedPrefsFromLegacyBundle"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        if let old = UserDefaults(suiteName: "com.jakubsokolowski.BigUwidget") {
            for (key, value) in old.dictionaryRepresentation() {
                if UserDefaults.standard.object(forKey: key) == nil {
                    UserDefaults.standard.set(value, forKey: key)
                }
            }
        }
        UserDefaults.standard.set(true, forKey: flag)
    }
}

enum SingleInstance {
    static func claim() -> Bool {
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != mine &&
            ($0.bundleIdentifier == "com.londonvista.biguwidget"
             || $0.bundleIdentifier == "com.jakubsokolowski.BigUwidget"
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
