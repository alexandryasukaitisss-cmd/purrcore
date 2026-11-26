import Foundation
import XCTest
@testable import PurrCoreCore

final class V060FeaturesTests: XCTestCase {
    func testCatRestStateHysteresisAndDelay() {
        let start = Date(timeIntervalSince1970: 1_000)

        let step1 = CatSpeedPolicy.evaluateRestState(
            cpuPercent: 1.8,
            idleSince: nil,
            now: start,
            currentlyResting: false,
            restWhenIdleEnabled: true
        )
        XCTAssertFalse(step1.resting)
        XCTAssertEqual(step1.updatedIdleSince, start)

        let step2 = CatSpeedPolicy.evaluateRestState(
            cpuPercent: 2.4,
            idleSince: step1.updatedIdleSince,
            now: start.addingTimeInterval(29),
            currentlyResting: false,
            restWhenIdleEnabled: true
        )
        XCTAssertFalse(step2.resting)

        let step3 = CatSpeedPolicy.evaluateRestState(
            cpuPercent: 2.2,
            idleSince: step2.updatedIdleSince,
            now: start.addingTimeInterval(30),
            currentlyResting: false,
            restWhenIdleEnabled: true
        )
        XCTAssertTrue(step3.resting)

        // Hysteresis keeps resting at 3.2% (< 3.5% wake threshold)
        let step4 = CatSpeedPolicy.evaluateRestState(
            cpuPercent: 3.2,
            idleSince: step3.updatedIdleSince,
            now: start.addingTimeInterval(40),
            currentlyResting: true,
            restWhenIdleEnabled: true
        )
        XCTAssertTrue(step4.resting)

        // Wakes immediately at >= 3.5%
        let step5 = CatSpeedPolicy.evaluateRestState(
            cpuPercent: 4.0,
            idleSince: step4.updatedIdleSince,
            now: start.addingTimeInterval(41),
            currentlyResting: true,
            restWhenIdleEnabled: true
        )
        XCTAssertFalse(step5.resting)
        XCTAssertNil(step5.updatedIdleSince)
    }

    func testGPUUtilizationExtractionAndProcessSafetyGuards() {
        XCTAssertEqual(
            SystemSampler.gpuUtilizationPercent(from: ["Device Utilization %": 74]),
            74
        )
        XCTAssertEqual(
            SystemSampler.gpuUtilizationPercent(from: ["Renderer Utilization %": 32, "Tiler Utilization %": 61]),
            61
        )
        XCTAssertNil(SystemSampler.gpuUtilizationPercent(from: [:]))

        let nestedHelper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        let mainApp = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let bundle = SystemSampler.outermostAppBundlePath(from: nestedHelper)
        XCTAssertEqual(bundle, "/Applications/Google Chrome.app")
        XCTAssertFalse(SystemSampler.isPrimaryAppExecutable(path: nestedHelper, bundlePath: bundle))
        XCTAssertTrue(SystemSampler.isPrimaryAppExecutable(path: mainApp, bundlePath: bundle))

        // System processes and self PID are strictly non-terminable
        XCTAssertFalse(
            SystemSampler.isTerminableUserProcess(
                pid: 400,
                uid: 501,
                currentUID: 501,
                selfPID: 999,
                category: .system,
                executablePath: "/System/Library/CoreServices/WindowServer"
            )
        )
        XCTAssertFalse(
            SystemSampler.isTerminableUserProcess(
                pid: 999,
                uid: 501,
                currentUID: 501,
                selfPID: 999,
                category: .other,
                executablePath: "/Applications/PurrCore.app/Contents/MacOS/PurrCore"
            )
        )
        XCTAssertTrue(
            SystemSampler.isTerminableUserProcess(
                pid: 1500,
                uid: 501,
                currentUID: 501,
                selfPID: 999,
                category: .browser,
                executablePath: mainApp
            )
        )
    }

    func testCommitUpdateEvaluatorResolvesUpToDatePendingAndAvailable() throws {
        let shaOld = "1111111111111111111111111111111111111111"
        let shaNew = "2222222222222222222222222222222222222222"
        let headData = """
        {
          "sha": "\(shaNew)",
          "html_url": "https://github.com/alexandryasukaitisss-cmd/purrcore/commit/\(shaNew)",
          "commit": { "message": "Feat: add GPU monitoring\\n\\nDetails" }
        }
        """.data(using: .utf8)!
        let head = try JSONDecoder().decode(GitHubCommitHeadPayload.self, from: headData)
        XCTAssertEqual(head.firstLineMessage, "Feat: add GPU monitoring")

        let manifestOld = CommitBuildManifest(
            repo: "alexandryasukaitisss-cmd/purrcore",
            branch: "main",
            sha: shaOld,
            shortSHA: "1111111",
            version: "0.6.0",
            commitTitle: "Old commit",
            publishedAt: "2026-11-26T12:00:00Z",
            assetName: "PurrCore-macos-arm64.zip",
            assetURL: "https://github.com/alexandryasukaitisss-cmd/purrcore/releases/download/latest-main/PurrCore-macos-arm64.zip",
            sha256: String(repeating: "a", count: 64)
        )

        // Local == manifest, but HEAD moved ahead -> buildInProgress
        let pending = CommitUpdateEvaluator.resolve(
            localSHA: shaOld,
            headCommit: head,
            manifest: manifestOld,
            repository: "alexandryasukaitisss-cmd/purrcore"
        )
        XCTAssertEqual(pending, .buildInProgress(headSHA: shaNew))

        // Manifest caught up to shaNew -> updateAvailable for local shaOld
        let manifestNew = CommitBuildManifest(
            repo: "alexandryasukaitisss-cmd/purrcore",
            branch: "main",
            sha: shaNew,
            shortSHA: "2222222",
            version: "0.6.0",
            commitTitle: "Feat: add GPU monitoring",
            publishedAt: "2026-11-26T12:05:00Z",
            assetName: "PurrCore-macos-arm64.zip",
            assetURL: "https://github.com/alexandryasukaitisss-cmd/purrcore/releases/download/latest-main/PurrCore-macos-arm64.zip",
            sha256: String(repeating: "b", count: 64)
        )
        let available = CommitUpdateEvaluator.resolve(
            localSHA: shaOld,
            headCommit: head,
            manifest: manifestNew,
            repository: "alexandryasukaitisss-cmd/purrcore"
        )
        if case .updateAvailable(let candidate) = available {
            XCTAssertEqual(candidate.shortSHA, "2222222")
            XCTAssertEqual(candidate.commitTitle, "Feat: add GPU monitoring")
        } else {
            XCTFail("Expected updateAvailable, got \(available)")
        }

        // Local == shaNew -> upToDate
        let current = CommitUpdateEvaluator.resolve(
            localSHA: shaNew,
            headCommit: head,
            manifest: manifestNew,
            repository: "alexandryasukaitisss-cmd/purrcore"
        )
        XCTAssertEqual(current, .upToDate(sha: shaNew))
    }

    func testSmartAlertTrackerRespectsSustainedDurationAndCooldown() {
        var tracker = SmartAlertTracker(cooldownSeconds: 1_800)
        let t0 = Date(timeIntervalSince1970: 10_000)

        func makeSnap(at date: Date, cpu: Double, pressure: MemoryPressureLevel = .normal) -> SystemSnapshot {
            SystemSnapshot(
                timestamp: date,
                cpuPercent: cpu,
                memory: MemorySnapshot(
                    totalBytes: 16_000_000_000,
                    usedBytes: 14_000_000_000,
                    appBytes: 10_000_000_000,
                    wiredBytes: 2_000_000_000,
                    compressedBytes: 2_000_000_000,
                    cachedBytes: 1_000_000_000,
                    swapUsedBytes: 0,
                    pressure: pressure
                ),
                network: .zero,
                disk: .zero,
                thermalState: .nominal,
                processes: [
                    ProcessGroupSample(
                        groupKey: "app:chrome",
                        displayName: "Google Chrome",
                        explanation: "browser",
                        category: .browser,
                        cpuPercent: cpu,
                        residentBytes: 6_000_000_000,
                        processCount: 5
                    )
                ]
            )
        }

        XCTAssertTrue(tracker.evaluate(snapshot: makeSnap(at: t0, cpu: 92), ssd: nil, now: t0).isEmpty)
        XCTAssertTrue(tracker.evaluate(snapshot: makeSnap(at: t0.addingTimeInterval(120), cpu: 90), ssd: nil, now: t0.addingTimeInterval(120)).isEmpty)

        let fired = tracker.evaluate(snapshot: makeSnap(at: t0.addingTimeInterval(181), cpu: 91), ssd: nil, now: t0.addingTimeInterval(181))
        XCTAssertEqual(fired.map(\.kind), [.sustainedHighCPU])
        XCTAssertEqual(fired.first?.topProcessName, "Google Chrome")

        // Cooldown blocks immediate repeat
        XCTAssertTrue(tracker.evaluate(snapshot: makeSnap(at: t0.addingTimeInterval(200), cpu: 95), ssd: nil, now: t0.addingTimeInterval(200)).isEmpty)
    }

    func testHistoryStorePersistsAndAveragesGPUPercent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PurrCoreGPU-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try HistoryStore(url: dir.appendingPathComponent("history.sqlite3"))
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snap = SystemSnapshot(
            timestamp: now,
            cpuPercent: 25,
            gpuPercent: 82.5,
            memory: MemorySnapshot(totalBytes: 16_000, usedBytes: 8_000, appBytes: 4_000, wiredBytes: 2_000, compressedBytes: 2_000, cachedBytes: 1_000, swapUsedBytes: 0, pressure: .normal),
            network: .zero,
            disk: .zero,
            thermalState: .nominal,
            processes: []
        )
        try await store.addSystemSample(snap)
        let loaded = try await store.loadSystemHistory(since: now.addingTimeInterval(-10), until: now.addingTimeInterval(10), maxPoints: 10)
        XCTAssertEqual(loaded.count, 1)
        let gpu = try XCTUnwrap(loaded.first?.gpuPercent)
        XCTAssertEqual(gpu, 82.5, accuracy: 0.01)
    }
}
