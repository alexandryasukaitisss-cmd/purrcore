import AppKit
import DiskArbitration
import Foundation
import OSLog
import PurrCoreCore
import SwiftUI

enum AppDefaults {
    static let animationEnabled = "animationEnabled"
    static let historyEnabled = "historyEnabled"
    static let statusMetric = "statusMetric"
    static let detailedProcessInterval = "detailedProcessInterval"
    static let batteryRetentionDays = "batteryRetentionDays"

    static func register() {
        UserDefaults.standard.register(defaults: [
            animationEnabled: true,
            historyEnabled: true,
            statusMetric: StatusMetric.cpu.rawValue,
            detailedProcessInterval: 5,
            batteryRetentionDays: 0
        ])
    }
}

enum ActiveSurface: Hashable {
    case popover
    case dashboard
    case settings
    case ssdHealth
}

private enum DiskChangeKind {
    case appeared
    case disappeared
    case descriptionChanged
}

// Disk Arbitration also reports physical disks with no mounted volumes.
private final class SSDDiskObserver {
    let onChange: @MainActor (DiskChangeKind) -> Void
    private let session: DASession?

    init(onChange: @escaping @MainActor (DiskChangeKind) -> Void) {
        self.onChange = onChange
        session = DASessionCreate(kCFAllocatorDefault)
        guard let session else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, ssdDiskAppeared, context)
        DARegisterDiskDisappearedCallback(session, nil, ssdDiskDisappeared, context)
        let keys = [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeNameKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(session, nil, keys, ssdDiskDescriptionChanged, context)
        DASessionSetDispatchQueue(session, .main)
    }

    deinit {
        guard let session else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        DAUnregisterCallback(session, unsafeBitCast(ssdDiskAppeared as DADiskAppearedCallback, to: UnsafeMutableRawPointer.self), context)
        DAUnregisterCallback(session, unsafeBitCast(ssdDiskDisappeared as DADiskDisappearedCallback, to: UnsafeMutableRawPointer.self), context)
        DAUnregisterCallback(session, unsafeBitCast(ssdDiskDescriptionChanged as DADiskDescriptionChangedCallback, to: UnsafeMutableRawPointer.self), context)
        DASessionSetDispatchQueue(session, nil)
    }
}

private func notifyDiskObserver(_ disk: DADisk, kind: DiskChangeKind, context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let description = DADiskCopyDescription(disk) as? [String: Any]
    guard description?[kDADiskDescriptionDeviceInternalKey as String] as? Bool != true else { return }
    MainActor.assumeIsolated {
        Unmanaged<SSDDiskObserver>.fromOpaque(context).takeUnretainedValue().onChange(kind)
    }
}

private func ssdDiskAppeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    notifyDiskObserver(disk, kind: .appeared, context: context)
}

private func ssdDiskDisappeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    notifyDiskObserver(disk, kind: .disappeared, context: context)
}

private func ssdDiskDescriptionChanged(_ disk: DADisk, _ keys: CFArray, _ context: UnsafeMutableRawPointer?) {
    notifyDiskObserver(disk, kind: .descriptionChanged, context: context)
}

enum CatAnimationConfig {
    static let frameCount = 8
    static let baseFrameInterval: TimeInterval = 0.14
}

enum StatusMetric: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case network
    case disk
    case thermal
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: tr("Память")
        case .network: tr("Сеть")
        case .disk: tr("Диск")
        case .thermal: tr("Нагрев")
        case .none: tr("Без подписи")
        }
    }

    func menuBarValue(for snapshot: SystemSnapshot) -> String {
        switch self {
        case .cpu:
            MetricFormat.percent(snapshot.cpuPercent)
        case .memory:
            "RAM \(MetricFormat.percent(snapshot.memory.usedFraction * 100))"
        case .network:
            "↕ \(MetricFormat.compactRate(snapshot.network.downloadBytesPerSecond + snapshot.network.uploadBytesPerSecond))"
        case .disk:
            "SSD \(MetricFormat.compactRate(snapshot.disk.downloadBytesPerSecond + snapshot.disk.uploadBytesPerSecond))"
        case .thermal:
            MetricFormat.thermal(snapshot.thermalState)
        case .none:
            ""
        }
    }
}

enum HistoryRange: Int, CaseIterable, Identifiable {
    case hour = 3_600
    case day = 86_400
    case week = 604_800

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .hour: tr("1 ч")
        case .day: tr("24 ч")
        case .week: tr("7 д")
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot.empty
    @Published private(set) var historyPoints: [HistoryPoint] = []
    @Published private(set) var taskMarkers: [TaskMarker] = []
    @Published private(set) var historicalCPUProcessGroups: [ProcessGroupSample] = []
    @Published private(set) var historicalMemoryProcessGroups: [ProcessGroupSample] = []
    @Published private(set) var databaseSizeBytes: UInt64 = 0
    @Published private(set) var ssd: SSDSnapshot?
    @Published private(set) var ssdHealth: SSDHealthSnapshot?
    @Published private(set) var ssdHealthLoading = false
    @Published private(set) var ssdHealthError: String?
    @Published private(set) var externalSSDHealth: [ExternalSSDHealthReport] = []
    @Published private(set) var externalSSDHealthError: String?
    @Published private(set) var battery: BatterySnapshot?
    @Published private(set) var usageReport = UsageReport.empty
    @Published private(set) var petPhoto: NSImage?
    @Published private(set) var petAnimation: [CGImage]?
    @Published private(set) var importingPetAsset = false
    @Published private(set) var petPhotoError: String?
    @Published private(set) var historyError: String?
    @Published var selectedRange: HistoryRange = .day {
        didSet {
            if activeSurfaces.contains(.dashboard) {
                refreshDisplayedHistory()
                Task { await reloadHistory(includeChartHistory: true) }
            }
        }
    }

    private let sampler = SystemSampler()
    private let ssdHealthReader = SSDHealthReader()
    private let usageLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PurrCore", category: "Usage")
    private let store: HistoryStore?
    private let petPhotoStore: PetPhotoStore?
    private let petAnimationStore: PetAnimationStore?
    private var usageTracker = UsageTracker()
    private var livePoints: [HistoryPoint] = []
    private var cachedDisplayedHistory: [HistoryPoint] = []
    private var historyReloadRevision = 0
    private var monitorTask: Task<Void, Never>?
    private var lastSSDHealthRefresh = Date.distantPast
    private var ssdHealthRevision = 0
    private var ssdRefreshPending = false
    private var ssdHealthNeedsRefresh = false
    private var ssdDebounceTask: Task<Void, Never>?
    private var diskObserver: SSDDiskObserver?
    private var isPreparingForTermination = false
    private var activeSurfaces: Set<ActiveSurface> = []
    private var forceProcessSampleNextTick = false

    private var isProcessSurfaceActive: Bool {
        activeSurfaces.contains(.popover) || activeSurfaces.contains(.dashboard)
    }

    private var isSSDSurfaceActive: Bool {
        activeSurfaces.contains(.ssdHealth) || activeSurfaces.contains(.settings)
    }

    private var hasVisibleHistorySurface: Bool {
        activeSurfaces.contains(.dashboard) || activeSurfaces.contains(.popover) || activeSurfaces.contains(.settings)
    }

    init() {
        AppDefaults.register()
        petPhotoStore = (try? RuntimePaths.applicationSupportDirectory()).map(PetPhotoStore.init)
        petAnimationStore = (try? RuntimePaths.applicationSupportDirectory()).map(PetAnimationStore.init)
        if let petPhotoStore {
            do {
                if let image = try petPhotoStore.load() {
                    petPhoto = NSImage(cgImage: image, size: .zero)
                }
            } catch {
                petPhotoError = tr(error.localizedDescription)
            }
        }
        if let petAnimationStore {
            do {
                petAnimation = try petAnimationStore.load()
            } catch {
                petPhotoError = tr(error.localizedDescription)
            }
        }
        do {
            store = try HistoryStore(url: RuntimePaths.historyDatabaseURL())
        } catch {
            store = nil
            historyError = tr(error.localizedDescription)
        }
        battery = StorageAndPowerSampler.sampleBattery()
        diskObserver = SSDDiskObserver { [weak self] kind in
            self?.handleExternalDiskChange(kind)
        }
        refreshSSDHealth()
        start()
    }

    deinit {
        monitorTask?.cancel()
        ssdDebounceTask?.cancel()
    }

    func setSurface(_ surface: ActiveSurface, active: Bool) {
        if active {
            let inserted = activeSurfaces.insert(surface).inserted
            switch surface {
            case .dashboard:
                forceProcessSampleNextTick = true
                refreshDisplayedHistory()
                Task { await reloadHistory(includeChartHistory: true) }
            case .popover:
                forceProcessSampleNextTick = true
                ssd = StorageAndPowerSampler.sampleSSD()
                Task { await reloadHistory(includeChartHistory: false) }
            case .settings:
                Task { await reloadHistory(includeChartHistory: false) }
                refreshSSDHealthIfStale(threshold: 15)
            case .ssdHealth:
                refreshSSDHealthIfStale(threshold: 15)
            }
            if inserted, surface == .popover || surface == .dashboard {
                battery = StorageAndPowerSampler.sampleBattery()
            }
        } else {
            activeSurfaces.remove(surface)
        }
    }

    func importPetPhoto(from url: URL) {
        guard !importingPetAsset else { return }
        guard let petPhotoStore else {
            petPhotoError = tr("Не удалось открыть локальное хранилище фото.")
            return
        }
        importingPetAsset = true
        petPhotoError = nil
        Task { @MainActor in
            let scopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if scopedAccess { url.stopAccessingSecurityScopedResource() }
                importingPetAsset = false
            }
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try petPhotoStore.importPhoto(from: url)
                }.value
                petPhoto = NSImage(cgImage: image, size: .zero)
            } catch {
                petPhotoError = tr(error.localizedDescription)
            }
        }
    }

    func importPetAnimation(from url: URL) {
        guard !importingPetAsset, let petAnimationStore else { return }
        importingPetAsset = true
        petPhotoError = nil
        Task { @MainActor in
            let scopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if scopedAccess { url.stopAccessingSecurityScopedResource() }
                importingPetAsset = false
            }
            do {
                petAnimation = try await Task.detached(priority: .userInitiated) {
                    try petAnimationStore.importAnimation(from: url)
                }.value
            } catch {
                petPhotoError = tr(error.localizedDescription)
            }
        }
    }

    func resetPetAnimation() {
        guard !importingPetAsset, let petAnimationStore else { return }
        do {
            try petAnimationStore.reset()
            petAnimation = nil
            petPhotoError = nil
        } catch {
            petPhotoError = tr(error.localizedDescription)
        }
    }

    func resetPetPhoto() {
        guard !importingPetAsset, let petPhotoStore else { return }
        do {
            try petPhotoStore.reset()
            petPhoto = nil
            petPhotoError = nil
        } catch {
            petPhotoError = tr(error.localizedDescription)
        }
    }

    var petGenerationPrompt: String? {
        guard petPhoto != nil, let petPhotoStore else { return nil }
        return tr("Создай бегущего питомца для PurrCore. Фото-референс на этом Mac:\n%@\n\nИспользуй фото как референс внешности, сохрани окрас, пропорции и особенности питомца.\nСоздай PNG с прозрачным фоном: ровно 8 кадров в одном горизонтальном ряду.\nРекомендуемый размер 3072×384: 8 одинаковых ячеек 384×384.\nВ каждом кадре питомец целиком, бежит вправо. Одинаковый масштаб, линия лап и камера.\nПолный плавный цикл бега, без растягивания тела. Оставь прозрачные поля внутри каждой ячейки.\nБез текста, сетки, рамок, теней, земли и других животных.\nСохрани готовую ленту PNG в отдельный файл и укажи путь для импорта в PurrCore.\nПроверь, что кадры стоят в равных ячейках и не пересекают их границы.\nЕсли генератор не поддерживает прозрачный фон, объясни ограничение до генерации.", String(describing: petPhotoStore.referencePhotoURL.path))
    }

    func showPetReferenceInFinder() {
        guard petPhoto != nil, let petPhotoStore else { return }
        NSWorkspace.shared.activateFileViewerSelecting([petPhotoStore.referencePhotoURL])
    }

    var displayedHistory: [HistoryPoint] {
        cachedDisplayedHistory
    }

    private func refreshDisplayedHistory() {
        let until = Date()
        cachedDisplayedHistory = HistoryPoint.mergedAndDownsampled(
            stored: historyPoints,
            live: livePoints,
            since: until.addingTimeInterval(-Double(selectedRange.rawValue)),
            until: until,
            maximumCount: 720
        )
    }

    func reloadHistory(includeChartHistory: Bool = true) async {
        guard let store else { return }
        historyReloadRevision += 1
        let revision = historyReloadRevision
        let range = selectedRange
        let now = Date()
        let since = now.addingTimeInterval(-Double(range.rawValue))
        let calendar = Calendar.autoupdatingCurrent
        let usageSince = calendar.date(
            byAdding: .day,
            value: -6,
            to: calendar.startOfDay(for: now)
        ) ?? now.addingTimeInterval(-6 * 86_400)

        do {
            async let size = store.databaseSizeBytes()
            async let usage = store.loadUsageReport(
                since: usageSince,
                until: now,
                calendar: calendar
            )

            if includeChartHistory {
                let systemUntil = livePoints.first.map {
                    Date(timeIntervalSince1970: $0.timestamp.timeIntervalSince1970.nextDown)
                } ?? now
                async let points: [HistoryPoint] = systemUntil >= since
                    ? store.loadSystemHistory(since: since, until: systemUntil, maxPoints: 720)
                    : []
                async let markers = store.loadTaskMarkers(since: since, until: now)
                async let cpuProcesses = store.loadTopProcessGroups(since: since, until: now, sortBy: .cpu, limit: 16)
                async let memProcesses = store.loadTopProcessGroups(since: since, until: now, sortBy: .memory, limit: 16)

                let loadedPoints = try await points
                let loadedMarkers = try await markers
                let loadedCPUProcesses = try await cpuProcesses
                let loadedMemProcesses = try await memProcesses
                let loadedSize = await size
                let loadedUsage = try await usage
                guard revision == historyReloadRevision, selectedRange == range else { return }
                historyPoints = loadedPoints
                taskMarkers = loadedMarkers
                historicalCPUProcessGroups = loadedCPUProcesses
                historicalMemoryProcessGroups = loadedMemProcesses
                databaseSizeBytes = loadedSize
                usageReport = loadedUsage
                historyError = nil
                refreshDisplayedHistory()
            } else {
                let loadedSize = await size
                let loadedUsage = try await usage
                guard revision == historyReloadRevision else { return }
                databaseSizeBytes = loadedSize
                usageReport = loadedUsage
                historyError = nil
            }
        } catch {
            guard revision == historyReloadRevision else { return }
            historyError = tr(error.localizedDescription)
        }
    }

    func handleSystemWillSleep() {
        let currentBattery = StorageAndPowerSampler.sampleBattery()
        battery = currentBattery
        usageTracker.suspend(at: .now, battery: currentBattery)
        usageLogger.info("System sleep: closed awake segment")
        Task { [weak self] in
            guard let self else { return }
            await self.persistUsage(reload: self.hasVisibleHistorySurface)
        }
    }

    func handleSystemDidWake() {
        let currentBattery = StorageAndPowerSampler.sampleBattery()
        battery = currentBattery
        usageTracker.resume(at: .now, battery: currentBattery)
        usageLogger.info("System wake: started awake segment")
        Task { [weak self] in
            guard let self else { return }
            await self.persistUsage(reload: self.hasVisibleHistorySurface)
        }
    }

    func prepareForTermination() async {
        guard !isPreparingForTermination else { return }
        isPreparingForTermination = true
        monitorTask?.cancel()
        ssdDebounceTask?.cancel()
        let currentBattery = StorageAndPowerSampler.sampleBattery()
        battery = currentBattery
        usageTracker.suspend(at: .now, battery: currentBattery)
        await persistUsage(reload: false)
        try? await store?.checkpointAndTruncate()
        usageLogger.info("Termination: usage state flushed and WAL truncated")
    }

    func refreshSSDHealthIfStale(threshold: TimeInterval) {
        if ssdHealth == nil || ssdHealthNeedsRefresh || Date().timeIntervalSince(lastSSDHealthRefresh) >= threshold {
            refreshSSDHealth()
        }
    }

    func refreshSSDHealth() {
        guard !ssdHealthLoading else {
            ssdRefreshPending = true
            return
        }
        ssdHealthLoading = true
        ssdHealthNeedsRefresh = false
        ssdHealthError = nil
        externalSSDHealthError = nil
        lastSSDHealthRefresh = .now
        let reader = ssdHealthReader
        let revision = ssdHealthRevision

        Task { [weak self] in
            let results = await Task.detached(priority: .utility) {
                (Result { try reader.read() }, Result { try reader.readExternalDisks() })
            }.value
            guard let self else { return }
            if revision == ssdHealthRevision {
                switch results.0 {
                case .success(let health): ssdHealth = health
                case .failure(let error):
                    ssdHealth = nil
                    ssdHealthError = tr(error.localizedDescription)
                }
                switch results.1 {
                case .success(let disks): externalSSDHealth = disks
                case .failure(let error):
                    externalSSDHealth = []
                    externalSSDHealthError = tr(error.localizedDescription)
                }
            }
            ssdHealthLoading = false
            if ssdRefreshPending {
                ssdRefreshPending = false
                if isSSDSurfaceActive {
                    refreshSSDHealth()
                } else {
                    ssdHealthNeedsRefresh = true
                }
            }
        }
    }

    private func handleExternalDiskChange(_ kind: DiskChangeKind) {
        if kind == .disappeared {
            ssdHealthRevision += 1
            externalSSDHealth = []
        }
        guard isSSDSurfaceActive else {
            ssdHealthNeedsRefresh = true
            return
        }
        ssdDebounceTask?.cancel()
        ssdDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.ssdHealthLoading {
                self.ssdRefreshPending = true
            } else {
                self.refreshSSDHealth()
            }
        }
    }

    private func start() {
        monitorTask = Task { [weak self] in
            await self?.monitorLoop()
        }
    }

    private func monitorLoop() async {
        var tick = 0
        await initializeUsageTracking()
        await maintainHistory()

        while !Task.isCancelled {
            let historyEnabled = UserDefaults.standard.bool(forKey: AppDefaults.historyEnabled)
            let processInterval = max(UserDefaults.standard.integer(forKey: AppDefaults.detailedProcessInterval), 5)
            let shouldPersistProcesses = historyEnabled && tick > 0 && tick.isMultiple(of: 60)
            let includeProcesses: Bool
            if tick == 0 || tick == 1 || forceProcessSampleNextTick || shouldPersistProcesses {
                includeProcesses = true
                forceProcessSampleNextTick = false
            } else if isProcessSurfaceActive {
                includeProcesses = tick.isMultiple(of: processInterval)
            } else {
                includeProcesses = false
            }

            let sampled = await sampler.sample(includeProcesses: includeProcesses)
            snapshot = sampled

            if isSSDSurfaceActive && Date().timeIntervalSince(lastSSDHealthRefresh) >= 60 {
                refreshSSDHealth()
            }
            if tick == 0 || (includeProcesses && activeSurfaces.contains(.popover)) {
                ssd = StorageAndPowerSampler.sampleSSD()
            }
            if tick == 0 || (battery != nil && tick.isMultiple(of: 5)) || (battery == nil && tick.isMultiple(of: 60)) {
                battery = StorageAndPowerSampler.sampleBattery()
            }
            usageTracker.observe(at: sampled.timestamp, battery: battery)

            livePoints.append(HistoryPoint(snapshot: sampled))
            if livePoints.count > 3_600 {
                livePoints.removeFirst(livePoints.count - 3_600)
            }
            if activeSurfaces.contains(.dashboard) {
                refreshDisplayedHistory()
            }

            if historyEnabled, let store {
                do {
                    if tick.isMultiple(of: 15) {
                        try await store.addSystemSample(sampled)
                    }
                    if shouldPersistProcesses {
                        let toPersist = Self.processesToPersist(from: sampled.processes)
                        try await store.addProcessSamples(toPersist, at: sampled.timestamp)
                    }
                } catch {
                    historyError = tr(error.localizedDescription)
                }
            }

            if tick > 0, tick.isMultiple(of: 3_600) {
                await maintainHistory()
            }
            if tick.isMultiple(of: 15) {
                await persistUsage(reload: hasVisibleHistorySurface)
            }

            tick += 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private static func processesToPersist(from processes: [ProcessGroupSample]) -> [ProcessGroupSample] {
        var selected: [String: ProcessGroupSample] = [:]
        selected.reserveCapacity(20)
        for sample in processes.sorted(by: { $0.cpuPercent > $1.cpuPercent }).prefix(10) {
            selected[sample.groupKey] = sample
        }
        for sample in processes.sorted(by: { $0.residentBytes > $1.residentBytes }).prefix(10) {
            selected[sample.groupKey] = sample
        }
        return Array(selected.values)
    }

    func setBatteryRetention(days: Int) {
        guard [0, 30, 90, 365].contains(days) else { return }
        UserDefaults.standard.set(days, forKey: AppDefaults.batteryRetentionDays)
        Task { await maintainHistory() }
    }

    private func maintainHistory() async {
        guard let store else { return }
        do {
            try await store.purge(olderThan: Date().addingTimeInterval(-604_800))
            let days = UserDefaults.standard.integer(forKey: AppDefaults.batteryRetentionDays)
            if [30, 90, 365].contains(days) {
                try await store.purgeBatterySessions(endedBefore: Date().addingTimeInterval(-Double(days) * 86_400))
            }
            if hasVisibleHistorySurface {
                await reloadHistory(includeChartHistory: activeSurfaces.contains(.dashboard))
            }
        } catch {
            historyError = tr(error.localizedDescription)
        }
    }

    private func initializeUsageTracking() async {
        let currentBattery = battery ?? StorageAndPowerSampler.sampleBattery()
        battery = currentBattery
        if let store {
            do {
                let active = try await store.loadActiveBatterySession()
                usageTracker = UsageTracker(activeBatterySession: active)
                usageTracker.resume(at: .now, battery: currentBattery)
                usageLogger.info("Usage tracking initialized; restored battery session: \(active != nil)")
                return
            } catch {
                historyError = tr(error.localizedDescription)
                usageLogger.error("Usage restore failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        usageTracker = UsageTracker()
        usageTracker.resume(at: .now, battery: currentBattery)
    }

    private func persistUsage(reload: Bool) async {
        guard let store else { return }
        let batch = usageTracker.persistenceBatch()
        do {
            try await store.saveUsageBatch(batch)
            usageTracker.acknowledgePersistence(of: batch)
            if reload {
                await reloadHistory(includeChartHistory: activeSurfaces.contains(.dashboard))
            }
        } catch {
            historyError = tr(error.localizedDescription)
            usageLogger.error("Usage persistence failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
