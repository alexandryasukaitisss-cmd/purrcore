import AppKit
import Combine
import PurrCoreCore
import QuartzCore
import ServiceManagement
import SwiftUI

@MainActor
enum CatAsset {
    static let menuBarSize = NSSize(width: 48, height: 24)
    static let statusSlotSize = NSSize(width: 48, height: 24)

    static let frames: [NSImage] = (0..<CatAnimationConfig.frameCount).map { frame in
        let image: NSImage
        if
            let url = PurrCoreResources.bundle.url(forResource: "cat_\(frame)", withExtension: "png"),
            let loaded = NSImage(contentsOf: url)
        {
            image = loaded
        } else {
            image = NSImage(systemSymbolName: "hare.fill", accessibilityDescription: "PurrCore") ?? NSImage()
        }
        image.size = menuBarSize
        image.isTemplate = false
        return image
    }

    static let cgFrames: [CGImage] = frames.compactMap { image in
        var proposedRect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    static let placeholder = NSImage(size: statusSlotSize)

    static func image(frame: Int) -> NSImage {
        frames[min(max(frame, 0), frames.count - 1)]
    }
}

struct PetFrameImage: View {
    let frame: Int
    let animation: [CGImage]?

    private var image: NSImage {
        guard let animation, !animation.isEmpty else { return CatAsset.image(frame: frame) }
        return NSImage(cgImage: animation[min(max(frame, 0), animation.count - 1)], size: .zero)
    }

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}

/// GPU-composited CoreAnimation sprite view so animated pets in MenuPanel and
/// Settings preview never trigger SwiftUI layout passes or display-link CPU spikes.
struct AnimatedPetView: NSViewRepresentable {
    let cpuPercent: Double
    let animationEnabled: Bool
    let isResting: Bool
    let reduceMotion: Bool
    let customFrames: [CGImage]?

    init(
        cpuPercent: Double,
        animationEnabled: Bool,
        isResting: Bool = false,
        reduceMotion: Bool,
        customFrames: [CGImage]?
    ) {
        self.cpuPercent = cpuPercent
        self.animationEnabled = animationEnabled
        self.isResting = isResting
        self.reduceMotion = reduceMotion
        self.customFrames = customFrames
    }

    func makeNSView(context: Context) -> AnimatedPetNSView {
        AnimatedPetNSView()
    }

    func updateNSView(_ view: AnimatedPetNSView, context: Context) {
        let frames = (customFrames?.isEmpty == false ? customFrames : nil) ?? CatAsset.cgFrames
        view.update(
            frames: frames,
            cpuPercent: cpuPercent,
            shouldAnimate: animationEnabled && !reduceMotion && !isResting,
            isResting: isResting
        )
    }
}

@MainActor
final class AnimatedPetNSView: NSView {
    private let petLayer = CALayer()
    private var currentFrameCount = 0
    private var currentFirstFrame: CGImage?
    private var currentSpeed: Float?
    private var currentResting: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        petLayer.contentsGravity = .resizeAspect
        petLayer.minificationFilter = .trilinear
        petLayer.magnificationFilter = .linear
        layer?.addSublayer(petLayer)
        updateAppearanceOutline()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceOutline()
    }

    private func updateAppearanceOutline() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isDark {
            petLayer.shadowColor = NSColor.white.cgColor
            petLayer.shadowOpacity = 0.55
            petLayer.shadowRadius = 1.1
            petLayer.shadowOffset = .zero
        } else {
            petLayer.shadowColor = NSColor.black.cgColor
            petLayer.shadowOpacity = 0.16
            petLayer.shadowRadius = 0.75
            petLayer.shadowOffset = CGSize(width: 0, height: -0.3)
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if petLayer.contentsScale != scale {
            petLayer.contentsScale = scale
        }
        if petLayer.frame != bounds {
            petLayer.frame = bounds
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        petLayer.contentsScale = scale
        CATransaction.commit()
    }

    func update(frames: [CGImage], cpuPercent: Double, shouldAnimate: Bool, isResting: Bool) {
        let framesChanged = frames.count != currentFrameCount || frames.first !== currentFirstFrame
        if framesChanged {
            currentFrameCount = frames.count
            currentFirstFrame = frames.first
            petLayer.removeAnimation(forKey: "petRun")
            currentSpeed = nil
            currentResting = nil
        }

        guard shouldAnimate, !frames.isEmpty else {
            petLayer.removeAnimation(forKey: "petRun")
            if !frames.isEmpty {
                let idx = isResting ? min(CatSpeedPolicy.restingFrameIndex, frames.count - 1) : 0
                petLayer.contents = frames[idx]
            } else {
                petLayer.contents = nil
            }
            petLayer.speed = 1
            petLayer.timeOffset = 0
            petLayer.beginTime = 0
            currentSpeed = nil
            currentResting = isResting
            return
        }

        let interval = CatSpeedPolicy.frameInterval(cpuPercent: cpuPercent)
        let rawSpeed = Float(CatAnimationConfig.baseFrameInterval / interval)
        let speed = (rawSpeed * 20).rounded() / 20

        if petLayer.animation(forKey: "petRun") == nil {
            petLayer.speed = 1
            petLayer.timeOffset = 0
            petLayer.beginTime = 0
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = frames
            animation.calculationMode = .discrete
            animation.duration = CatAnimationConfig.baseFrameInterval * Double(frames.count)
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            petLayer.add(animation, forKey: "petRun")
        }

        guard currentSpeed != speed else { return }
        let now = CACurrentMediaTime()
        petLayer.timeOffset = petLayer.convertTime(now, from: nil)
        petLayer.beginTime = now
        petLayer.speed = speed
        currentSpeed = speed
    }
}

@MainActor
final class AppServices {
    static let shared = AppServices()

    let model = AppModel()
    let updater = AppUpdater()
    let dashboardController = DashboardWindowController()
    let ssdHealthController = SSDHealthWindowController()
    let settingsController = SettingsWindowController()

    private init() {}
}

@MainActor
final class PurrCoreAppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var terminationReplyPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--register-login-item") {
            do {
                try SMAppService.mainApp.register()
                let status = SMAppService.mainApp.status
                print("PurrCore login item status: \(status.rawValue)")
                exit(status == .enabled || status == .requiresApproval ? 0 : 1)
            } catch {
                print("PurrCore login item registration failed: \(error)")
                exit(1)
            }
        }

        if !arguments.contains("--allow-multiple"), let bundleID = Bundle.main.bundleIdentifier {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
            if !duplicates.isEmpty {
                exit(0)
            }
        }

        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        let services = AppServices.shared
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(systemWillPowerOff),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )
        statusController = StatusItemController(
            model: services.model,
            updater: services.updater,
            openDashboard: { services.dashboardController.show(model: services.model) },
            openSSDHealth: { services.ssdHealthController.show(model: services.model) },
            openSettings: { services.settingsController.show(model: services.model, updater: services.updater) }
        )

        if arguments.contains("--show-dashboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                services.dashboardController.show(model: services.model)
            }
        } else if arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                services.settingsController.show(model: services.model, updater: services.updater)
            }
        } else if arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.statusController?.showPopover()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplyPending else { return .terminateLater }
        terminationReplyPending = true
        Task { @MainActor in
            await AppServices.shared.model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            statusController?.showPopover()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "PurrCore")
        let settingsItem = NSMenuItem(
            title: tr("Настройки") + "…",
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: tr("Выйти"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettingsFromMenu() {
        let services = AppServices.shared
        services.settingsController.show(model: services.model, updater: services.updater)
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        AppServices.shared.model.handleSystemWillSleep()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        AppServices.shared.model.handleSystemDidWake()
    }

    @objc private func systemWillPowerOff(_ notification: Notification) {
        AppServices.shared.model.handleSystemWillSleep()
    }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    private let updater: AppUpdater
    private let openDashboard: () -> Void
    private let openSSDHealth: () -> Void
    private let openSettings: () -> Void
    private let catLayer = CALayer()
    private var animationSpeed: Float?
    private var lastTitleRefresh = Date.distantPast
    private var cachedStatusMetric: String
    private var cachedAnimationEnabled: Bool
    private var cachedDetailedInterval: Int
    private var subscriptions: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?
    private var globalMouseMonitor: Any?
    private var localEventMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var workspaceActivateObserver: NSObjectProtocol?

    init(
        model: AppModel,
        updater: AppUpdater,
        openDashboard: @escaping () -> Void,
        openSSDHealth: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.model = model
        self.updater = updater
        self.openDashboard = openDashboard
        self.openSSDHealth = openSSDHealth
        self.openSettings = openSettings
        self.cachedStatusMetric = UserDefaults.standard.string(forKey: AppDefaults.statusMetric) ?? StatusMetric.cpu.rawValue
        self.cachedAnimationEnabled = UserDefaults.standard.bool(forKey: AppDefaults.animationEnabled)
        self.cachedDetailedInterval = UserDefaults.standard.integer(forKey: AppDefaults.detailedProcessInterval)
        super.init()

        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleStatusBarClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleNone
            button.image = CatAsset.placeholder
            button.toolTip = "PurrCore"
            button.font = AppFonts.statusItemButton
            button.wantsLayer = true
            button.postsFrameChangedNotifications = true

            catLayer.contents = CatAsset.cgFrames.first
            catLayer.contentsGravity = .resizeAspect
            catLayer.minificationFilter = .trilinear
            catLayer.magnificationFilter = .linear
            catLayer.contentsScale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            button.layer?.addSublayer(catLayer)
            updateCatAppearanceShadow(for: button)
            layoutCatLayer(in: button)

            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] button, _ in
                Task { @MainActor [weak self, weak button] in
                    guard let self, let button else { return }
                    self.updateCatAppearanceShadow(for: button)
                }
            }

            NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: button)
                .sink { [weak self, weak button] _ in
                    guard let self, let button else { return }
                    self.layoutCatLayer(in: button)
                }
                .store(in: &subscriptions)

            NotificationCenter.default.publisher(for: NSWindow.didChangeBackingPropertiesNotification)
                .sink { [weak self, weak button] notification in
                    guard let self, let button, let window = button.window,
                          notification.object as AnyObject? === window else { return }
                    self.layoutCatLayer(in: button)
                }
                .store(in: &subscriptions)
        }

        model.$snapshot
            .sink { [weak self] snapshot in
                self?.refreshTitleIfDue(snapshot: snapshot)
                self?.refreshAnimation(cpuPercent: snapshot.cpuPercent)
            }
            .store(in: &subscriptions)

        model.$isPetResting
            .sink { [weak self] _ in
                guard let self else { return }
                self.animationSpeed = nil
                self.refreshAnimation(cpuPercent: self.model.snapshot.cpuPercent)
            }
            .store(in: &subscriptions)

        model.$petAnimation
            .sink { [weak self] frames in
                guard let self else { return }
                catLayer.removeAnimation(forKey: "catRun")
                animationSpeed = nil
                refreshAnimation(cpuPercent: model.snapshot.cpuPercent, frames: frames ?? CatAsset.cgFrames)
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleUserDefaultsChanged()
            }
            .store(in: &subscriptions)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.animationSpeed = nil
                self.refreshAnimation(cpuPercent: self.model.snapshot.cpuPercent)
            }
            .store(in: &subscriptions)

        refreshTitle(snapshot: model.snapshot)
        refreshAnimation(cpuPercent: model.snapshot.cpuPercent)
    }

    private func updateCatAppearanceShadow(for button: NSStatusBarButton) {
        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isDark {
            catLayer.shadowColor = NSColor.white.cgColor
            catLayer.shadowOpacity = 0.65
            catLayer.shadowRadius = 1.15
            catLayer.shadowOffset = .zero
        } else {
            catLayer.shadowColor = NSColor.black.cgColor
            catLayer.shadowOpacity = 0.20
            catLayer.shadowRadius = 0.75
            catLayer.shadowOffset = CGSize(width: 0, height: -0.3)
        }
        CATransaction.commit()
    }

    @objc private func handleStatusBarClick() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        {
            closePopover()
            showQuickContextMenu()
            return
        }
        togglePopover()
    }

    private func showQuickContextMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()

        let metricHeader = NSMenuItem(title: tr("Показатель рядом с питомцем"), action: nil, keyEquivalent: "")
        metricHeader.isEnabled = false
        menu.addItem(metricHeader)

        let activeMetric = StatusMetric(rawValue: cachedStatusMetric) ?? .cpu
        for metric in StatusMetric.allCases {
            if metric == .gpu && model.snapshot.gpuPercent == nil {
                continue
            }
            let item = NSMenuItem(
                title: tr(metric.title),
                action: #selector(selectMetricFromContextMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = metric.rawValue
            item.state = (metric == activeMetric) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let historyItem = NSMenuItem(title: tr("История") + "…", action: #selector(openDashboardFromContextMenu), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

        let ssdItem = NSMenuItem(title: tr("Здоровье SSD") + "…", action: #selector(openSSDFromContextMenu), keyEquivalent: "")
        ssdItem.target = self
        menu.addItem(ssdItem)

        if let candidate = updater.availableCandidate {
            let updateItem = NSMenuItem(
                title: tr("Обновить до %@…", candidate.shortSHA),
                action: #selector(installUpdateFromContextMenu),
                keyEquivalent: ""
            )
            updateItem.target = self
            menu.addItem(updateItem)
        } else {
            let checkItem = NSMenuItem(
                title: tr("Проверить обновления"),
                action: #selector(checkUpdatesFromContextMenu),
                keyEquivalent: ""
            )
            checkItem.target = self
            menu.addItem(checkItem)
        }

        let settingsItem = NSMenuItem(title: tr("Настройки") + "…", action: #selector(openSettingsFromContextMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Выйти"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func selectMetricFromContextMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: AppDefaults.statusMetric)
    }

    @objc private func openDashboardFromContextMenu() {
        openDashboard()
    }

    @objc private func openSSDFromContextMenu() {
        openSSDHealth()
    }

    @objc private func openSettingsFromContextMenu() {
        openSettings()
    }

    @objc private func checkUpdatesFromContextMenu() {
        updater.checkForUpdates(manual: true)
        openSettings()
    }

    @objc private func installUpdateFromContextMenu() {
        updater.installAvailableUpdate()
    }

    @objc private func togglePopover() {
        popover.isShown ? closePopover() : showPopover()
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        model.setSurface(.popover, active: true)
        updater.checkIfStale()
        let hostingController = NSHostingController(
            rootView: MenuPanel(
                model: model,
                updater: updater,
                onOpenDashboard: { [weak self] in
                    self?.closePopover()
                    self?.openDashboard()
                },
                onOpenSSDHealth: { [weak self] in
                    self?.closePopover()
                    self?.openSSDHealth()
                },
                onOpenSettings: { [weak self] in
                    self?.closePopover()
                    self?.openSettings()
                },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        let fittingHeight = hostingController.view.fittingSize.height
        popover.contentSize = NSSize(
            width: 376,
            height: fittingHeight > 100 ? fittingHeight : (model.hasInternalBattery ? 616 : 560)
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        installDismissMonitors()
    }

    func closePopover() {
        removeDismissMonitors()
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeDismissMonitors()
        model.setSurface(.popover, active: false)
        popover.contentViewController = nil
    }

    private func installDismissMonitors() {
        removeDismissMonitors()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                if !self.isPointInsidePopoverOrStatusButton(NSEvent.mouseLocation) {
                    self.closePopover()
                }
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            let eventType = event.type
            let keyCode: UInt16? = eventType == .keyDown ? event.keyCode : nil
            let eventWindowNumber = event.windowNumber
            let shouldConsume: Bool = MainActor.assumeIsolated {
                guard self.popover.isShown else { return false }
                if let keyCode {
                    if keyCode == 53 {
                        self.closePopover()
                        return true
                    }
                    return false
                }
                let popoverWindowNumber = self.popover.contentViewController?.view.window?.windowNumber
                let statusWindowNumber = self.statusItem.button?.window?.windowNumber
                if eventWindowNumber != popoverWindowNumber && eventWindowNumber != statusWindowNumber {
                    self.closePopover()
                }
                return false
            }
            return shouldConsume ? nil : event
        }

        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                self.closePopover()
            }
        }

        workspaceActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            let currentPID = ProcessInfo.processInfo.processIdentifier
            guard activatedPID != currentPID else { return }
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                self.closePopover()
            }
        }
    }

    private func removeDismissMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
        if let workspaceActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivateObserver)
            self.workspaceActivateObserver = nil
        }
    }

    private func isPointInsidePopoverOrStatusButton(_ screenPoint: NSPoint) -> Bool {
        if let popoverWindow = popover.contentViewController?.view.window,
           popoverWindow.frame.contains(screenPoint)
        {
            return true
        }
        if let button = statusItem.button, let buttonWindow = button.window {
            let buttonRectInWindow = button.convert(button.bounds, to: nil)
            let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)
            if buttonRectOnScreen.contains(screenPoint) {
                return true
            }
        }
        return false
    }

    private func handleUserDefaultsChanged() {
        let currentMetric = UserDefaults.standard.string(forKey: AppDefaults.statusMetric) ?? StatusMetric.cpu.rawValue
        let currentAnimation = UserDefaults.standard.bool(forKey: AppDefaults.animationEnabled)
        let currentInterval = UserDefaults.standard.integer(forKey: AppDefaults.detailedProcessInterval)

        let metricChanged = currentMetric != cachedStatusMetric
        let animationChanged = currentAnimation != cachedAnimationEnabled
        let intervalChanged = currentInterval != cachedDetailedInterval
        guard metricChanged || animationChanged || intervalChanged else { return }

        cachedStatusMetric = currentMetric
        cachedAnimationEnabled = currentAnimation
        cachedDetailedInterval = currentInterval

        if metricChanged || intervalChanged {
            lastTitleRefresh = Date()
            refreshTitle(snapshot: model.snapshot)
        }
        if animationChanged {
            animationSpeed = nil
            refreshAnimation(cpuPercent: model.snapshot.cpuPercent)
        }
    }

    private func refreshTitleIfDue(snapshot: SystemSnapshot) {
        let interval = max(cachedDetailedInterval, 5)
        guard Date().timeIntervalSince(lastTitleRefresh) >= Double(interval) else { return }
        lastTitleRefresh = Date()
        refreshTitle(snapshot: snapshot)
    }

    private func refreshTitle(snapshot: SystemSnapshot) {
        guard let button = statusItem.button else { return }
        let metric = StatusMetric(rawValue: cachedStatusMetric) ?? .cpu
        let value = metric.menuBarValue(for: snapshot)
        let displayTitle = value.isEmpty ? "" : " " + value
        if button.title != displayTitle {
            button.title = displayTitle
        }
        button.setAccessibilityLabel(value.isEmpty ? "PurrCore" : "PurrCore, \(metric.title): \(value)")
        layoutCatLayer(in: button)
    }

    private func refreshAnimation(cpuPercent: Double, frames: [CGImage]? = nil) {
        let frames = frames ?? model.petAnimation ?? CatAsset.cgFrames
        let resting = model.isPetResting
        let shouldAnimate = cachedAnimationEnabled
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !resting
        guard shouldAnimate, !frames.isEmpty else {
            catLayer.removeAnimation(forKey: "catRun")
            if !frames.isEmpty {
                let idx = resting ? min(CatSpeedPolicy.restingFrameIndex, frames.count - 1) : 0
                catLayer.contents = frames[idx]
            } else {
                catLayer.contents = nil
            }
            resetAnimationTiming()
            animationSpeed = nil
            return
        }

        let interval = CatSpeedPolicy.frameInterval(cpuPercent: cpuPercent)
        let rawSpeed = Float(CatAnimationConfig.baseFrameInterval / interval)
        let speed = (rawSpeed * 20).rounded() / 20

        if catLayer.animation(forKey: "catRun") == nil {
            resetAnimationTiming()
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = frames
            animation.calculationMode = .discrete
            animation.duration = CatAnimationConfig.baseFrameInterval * Double(frames.count)
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            catLayer.add(animation, forKey: "catRun")
        }

        guard animationSpeed != speed else { return }
        let currentTime = CACurrentMediaTime()
        catLayer.timeOffset = catLayer.convertTime(currentTime, from: nil)
        catLayer.beginTime = currentTime
        catLayer.speed = speed
        animationSpeed = speed
    }

    private func resetAnimationTiming() {
        catLayer.speed = 1
        catLayer.timeOffset = 0
        catLayer.beginTime = 0
    }

    private func layoutCatLayer(in button: NSStatusBarButton) {
        let fallback = NSRect(
            x: 4,
            y: 0,
            width: CatAsset.statusSlotSize.width,
            height: CatAsset.statusSlotSize.height
        )
        let imageRect = button.bounds.width > 0
            ? (button.cell?.imageRect(forBounds: button.bounds) ?? fallback)
            : fallback
        let height = button.bounds.height > 0 ? button.bounds.height : CatAsset.menuBarSize.height
        let frame = NSRect(
            x: imageRect.width > 0 ? imageRect.minX : fallback.minX,
            y: 0,
            width: height * CatAsset.menuBarSize.width / CatAsset.menuBarSize.height,
            height: height
        )
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if catLayer.contentsScale != scale {
            catLayer.contentsScale = scale
        }
        if catLayer.frame != frame {
            catLayer.frame = frame
        }
        CATransaction.commit()
    }
}

@main
enum PurrCoreMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = PurrCoreAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
