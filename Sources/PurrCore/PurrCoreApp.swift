import AppKit
import Combine
import PurrCoreCore
import QuartzCore
import ServiceManagement
import SwiftUI

@MainActor
enum CatAsset {
    static let menuBarSize = NSSize(width: 64, height: 24)
    static let statusSlotSize = NSSize(width: 64, height: 24)

    private static let resourceBundle: Bundle? = {
        let bundleName = "PurrCore_PurrCore.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName)
        ].compactMap { $0 }
        return candidates.lazy.compactMap(Bundle.init(url:)).first
    }()

    static let frames: [NSImage] = (0..<CatAnimationConfig.frameCount).map { frame in
        let image: NSImage
        if
            let url = resourceBundle?.url(forResource: "cat_\(frame)", withExtension: "png"),
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

@MainActor
final class AppServices {
    static let shared = AppServices()

    let model = AppModel()
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
        if ProcessInfo.processInfo.arguments.contains("--register-login-item") {
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

        NSApp.setActivationPolicy(.accessory)
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
            openDashboard: { services.dashboardController.show(model: services.model) },
            openSSDHealth: { services.ssdHealthController.show(model: services.model) },
            openSettings: { services.settingsController.show(model: services.model) }
        )

        if ProcessInfo.processInfo.arguments.contains("--show-dashboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                services.dashboardController.show(model: services.model)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                services.settingsController.show(model: services.model)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--show-menu") {
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

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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
    private let openDashboard: () -> Void
    private let openSSDHealth: () -> Void
    private let openSettings: () -> Void
    private let catLayer = CALayer()
    private var animationSpeed: Float?
    private var lastTitleRefresh = Date.distantPast
    private var subscriptions: Set<AnyCancellable> = []

    init(model: AppModel, openDashboard: @escaping () -> Void, openSSDHealth: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.model = model
        self.openDashboard = openDashboard
        self.openSSDHealth = openSSDHealth
        self.openSettings = openSettings
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleNone
            button.image = CatAsset.placeholder
            button.toolTip = "PurrCore"
            button.font = AppFonts.statusItemButton
            button.wantsLayer = true

            catLayer.contents = CatAsset.cgFrames.first
            catLayer.contentsGravity = .resizeAspect
            catLayer.minificationFilter = .linear
            catLayer.magnificationFilter = .linear
            catLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            button.layer?.addSublayer(catLayer)
            layoutCatLayer(in: button)
        }

        model.$snapshot
            .sink { [weak self] snapshot in
                self?.refreshTitleIfDue(snapshot: snapshot)
                self?.refreshAnimation(cpuPercent: snapshot.cpuPercent)
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
                guard let self else { return }
                self.lastTitleRefresh = Date()
                self.refreshTitle(snapshot: self.model.snapshot)
                self.animationSpeed = nil
                self.refreshAnimation(cpuPercent: self.model.snapshot.cpuPercent)
            }
            .store(in: &subscriptions)

        refreshTitle(snapshot: model.snapshot)
        refreshAnimation(cpuPercent: model.snapshot.cpuPercent)
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        popover.contentSize = NSSize(width: 370, height: 600)
        popover.contentViewController = NSHostingController(
            rootView: MenuPanel(
                model: model,
                onOpenDashboard: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openDashboard()
                },
                onOpenSSDHealth: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openSSDHealth()
                },
                onOpenSettings: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openSettings()
                },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    private func refreshTitleIfDue(snapshot: SystemSnapshot) {
        let interval = max(UserDefaults.standard.integer(forKey: AppDefaults.detailedProcessInterval), 5)
        guard Date().timeIntervalSince(lastTitleRefresh) >= Double(interval) else { return }
        lastTitleRefresh = Date()
        refreshTitle(snapshot: snapshot)
    }

    private func refreshTitle(snapshot: SystemSnapshot) {
        guard let button = statusItem.button else { return }
        let rawMetric = UserDefaults.standard.string(forKey: AppDefaults.statusMetric) ?? StatusMetric.cpu.rawValue
        let metric = StatusMetric(rawValue: rawMetric) ?? .cpu
        let value = metric.menuBarValue(for: snapshot)
        let displayTitle = value.isEmpty ? "" : " " + value
        if button.title != displayTitle {
            button.title = displayTitle
        }
        button.setAccessibilityLabel(value.isEmpty ? "PurrCore" : "PurrCore, \(metric.title): \(value)")
        button.layoutSubtreeIfNeeded()
        layoutCatLayer(in: button)
    }

    private func refreshAnimation(cpuPercent: Double, frames: [CGImage]? = nil) {
        let frames = frames ?? model.petAnimation ?? CatAsset.cgFrames
        let shouldAnimate = UserDefaults.standard.bool(forKey: AppDefaults.animationEnabled)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate, !frames.isEmpty else {
            catLayer.removeAnimation(forKey: "catRun")
            catLayer.contents = frames.first
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
        let imageRect = button.cell?.imageRect(forBounds: button.bounds) ?? fallback
        let height = button.bounds.height > 0 ? button.bounds.height : CatAsset.menuBarSize.height
        let frame = NSRect(
            x: imageRect.width > 0 ? imageRect.minX : fallback.minX,
            y: 0,
            width: height * CatAsset.menuBarSize.width / CatAsset.menuBarSize.height,
            height: height
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        catLayer.frame = frame
        CATransaction.commit()
    }
}

@main
struct PurrCoreApp: App {
    @NSApplicationDelegateAdaptor(PurrCoreAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: AppServices.shared.model)
        }
    }
}
