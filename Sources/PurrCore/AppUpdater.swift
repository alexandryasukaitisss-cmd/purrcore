import AppKit
import Foundation
import PurrCoreCore

@MainActor
final class AppUpdater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(shortSHA: String)
        case buildPending(shortSHA: String)
        case available(CommitUpdateCandidate)
        case installing(progressText: String)
        case failed(String)
    }

    static let repository = "alexandryasukaitisss-cmd/purrcore"
    private static let checkIntervalSeconds: TimeInterval = 6 * 3_600
    private static let lastCheckDefaultsKey = "lastCommitUpdateCheckTimestamp"

    @Published private(set) var state: State = .idle

    let localCommitSHA: String?
    let localShortSHA: String
    let localVersion: String

    private var periodicTask: Task<Void, Never>?

    init() {
        let info = Bundle.main.infoDictionary
        let rawSHA = info?["GitCommitSHA"] as? String
        self.localCommitSHA = CommitUpdateEvaluator.normalizeSHA(rawSHA)
        self.localShortSHA = localCommitSHA.map(CommitUpdateEvaluator.shortSHA) ?? "dev"
        self.localVersion = (info?["CFBundleShortVersionString"] as? String) ?? "0.6.2"

        startPeriodicChecks()
    }

    deinit {
        periodicTask?.cancel()
    }

    var availableCandidate: CommitUpdateCandidate? {
        if case .available(let candidate) = state {
            return candidate
        }
        return nil
    }

    var isBusy: Bool {
        switch state {
        case .checking, .installing:
            return true
        default:
            return false
        }
    }

    func checkIfStale() {
        guard UserDefaults.standard.bool(forKey: AppDefaults.autoCheckUpdates) else { return }
        guard !isBusy, availableCandidate == nil else { return }
        let lastCheck = UserDefaults.standard.double(forKey: Self.lastCheckDefaultsKey)
        let elapsed = Date().timeIntervalSince1970 - lastCheck
        if elapsed >= 900 {
            checkForUpdates(manual: false)
        }
    }

    func checkForUpdates(manual: Bool) {
        guard !isBusy else { return }
        state = .checking
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCheck(manual: manual)
        }
    }

    func installAvailableUpdate() {
        guard case .available(let candidate) = state else { return }
        state = .installing(progressText: tr("Скачиваю сборку %@…", candidate.shortSHA))
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performInstall(candidate: candidate)
        }
    }

    private func startPeriodicChecks() {
        periodicTask?.cancel()
        periodicTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                if UserDefaults.standard.bool(forKey: AppDefaults.autoCheckUpdates) {
                    await self.performCheck(manual: false)
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.checkIntervalSeconds * 1_000_000_000))
            }
        }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }

    private func performCheck(manual: Bool) async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckDefaultsKey)

        let headCommit = await fetchHeadCommit(session: session)
        let manifest = await fetchLatestManifest(session: session)

        if headCommit == nil && manifest == nil {
            if manual {
                state = .failed(tr("Не удалось связаться с GitHub для проверки обновлений."))
            } else {
                state = .idle
            }
            return
        }

        let resolution = CommitUpdateEvaluator.resolve(
            localSHA: localCommitSHA,
            headCommit: headCommit,
            manifest: manifest,
            repository: Self.repository
        )

        switch resolution {
        case .upToDate(let sha):
            state = .upToDate(shortSHA: CommitUpdateEvaluator.shortSHA(sha))
        case .buildInProgress(let headSHA):
            state = .buildPending(shortSHA: CommitUpdateEvaluator.shortSHA(headSHA))
        case .updateAvailable(let candidate):
            state = .available(candidate)
        }
    }

    private func fetchHeadCommit(session: URLSession) async -> GitHubCommitHeadPayload? {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/commits/main") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PurrCore/\(localVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            return nil
        }
        return try? JSONDecoder().decode(GitHubCommitHeadPayload.self, from: data)
    }

    private func fetchLatestManifest(session: URLSession) async -> CommitBuildManifest? {
        let cacheBuster = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "https://github.com/\(Self.repository)/releases/download/latest-main/latest-main.json?t=\(cacheBuster)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("PurrCore/\(localVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let finalURL = http.url,
              CommitUpdateEvaluator.isTrustedGitHubURL(finalURL)
        else {
            return nil
        }
        return try? JSONDecoder().decode(CommitBuildManifest.self, from: data)
    }

    private func performInstall(candidate: CommitUpdateCandidate) async {
        let targetAppURL = Bundle.main.bundleURL.standardizedFileURL
        guard targetAppURL.pathExtension == "app" else {
            state = .failed(tr("Автообновление доступно только при запуске из PurrCore.app."))
            return
        }
        let parentDir = targetAppURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDir.path) else {
            NSWorkspace.shared.open(candidate.commitURL)
            state = .failed(tr("Нет прав на запись в %@. Перенеси PurrCore.app в /Applications.", parentDir.path))
            return
        }
        guard CommitUpdateEvaluator.isTrustedGitHubURL(candidate.downloadURL) else {
            state = .failed(tr("Недопустимый адрес загрузки обновления."))
            return
        }

        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("purrcore-update-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

            var request = URLRequest(url: candidate.downloadURL)
            request.setValue("PurrCore/\(localVersion)", forHTTPHeaderField: "User-Agent")
            let (zipData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let finalURL = http.url,
                  CommitUpdateEvaluator.isTrustedGitHubURL(finalURL)
            else {
                try? FileManager.default.removeItem(at: stagingDir)
                state = .failed(tr("Не удалось скачать архив обновления с GitHub."))
                return
            }

            if let expectedSHA256 = candidate.expectedSHA256 {
                let actualSHA256 = CommitUpdateEvaluator.sha256Hex(of: zipData)
                guard actualSHA256 == expectedSHA256 else {
                    try? FileManager.default.removeItem(at: stagingDir)
                    state = .failed(tr("Контрольная сумма SHA-256 архива не совпала."))
                    return
                }
            }

            state = .installing(progressText: tr("Проверяю подпись и распаковываю…"))

            let zipURL = stagingDir.appendingPathComponent("update.zip")
            try zipData.write(to: zipURL, options: .atomic)

            let unpackDir = stagingDir.appendingPathComponent("unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: unpackDir, withIntermediateDirectories: true)

            try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", zipURL.path, unpackDir.path])

            let extractedApp = unpackDir.appendingPathComponent("PurrCore.app", isDirectory: true)
            let executableURL = extractedApp.appendingPathComponent("Contents/MacOS/PurrCore")
            let extractedPlistURL = extractedApp.appendingPathComponent("Contents/Info.plist")

            guard FileManager.default.fileExists(atPath: executableURL.path),
                  let plistData = try? Data(contentsOf: extractedPlistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
            else {
                try? FileManager.default.removeItem(at: stagingDir)
                state = .failed(tr("В архиве не найден корректный PurrCore.app."))
                return
            }

            if let embeddedSHA = CommitUpdateEvaluator.normalizeSHA(plist["GitCommitSHA"] as? String),
               !CommitUpdateEvaluator.isSameCommit(embeddedSHA, candidate.targetSHA)
            {
                try? FileManager.default.removeItem(at: stagingDir)
                state = .failed(tr("Хеш коммита внутри сборки не совпадает с ожидаемым."))
                return
            }

            _ = try? runProcess("/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", extractedApp.path])
            try runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", extractedApp.path])

            state = .installing(progressText: tr("Перезапускаю обновлённый PurrCore…"))
            try launchDetachedSwapAndRelaunch(
                stagingDir: stagingDir,
                extractedApp: extractedApp,
                targetApp: targetAppURL
            )
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            state = .failed(tr("Ошибка обновления: %@", error.localizedDescription))
        }
    }

    @discardableResult
    private func runProcess(_ launchPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "PurrCoreUpdater",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
        return output
    }

    private func launchDetachedSwapAndRelaunch(
        stagingDir: URL,
        extractedApp: URL,
        targetApp: URL
    ) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = stagingDir.appendingPathComponent("apply_update.sh")
        let backupPath = targetApp.path + ".previous-\(pid)"

        let script = """
        #!/bin/sh
        OLD_PID="\(pid)"
        NEW_APP=\(shellQuote(extractedApp.path))
        TARGET_APP=\(shellQuote(targetApp.path))
        BACKUP_APP=\(shellQuote(backupPath))
        STAGING_DIR=\(shellQuote(stagingDir.path))

        i=0
        while kill -0 "$OLD_PID" 2>/dev/null && [ "$i" -lt 150 ]; do
          sleep 0.1
          i=$((i + 1))
        done

        rm -rf "$BACKUP_APP"
        if [ -d "$TARGET_APP" ]; then
          mv "$TARGET_APP" "$BACKUP_APP" || exit 1
        fi

        if /usr/bin/ditto "$NEW_APP" "$TARGET_APP"; then
          /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1 || true
          rm -rf "$BACKUP_APP"
          /usr/bin/open -n "$TARGET_APP"
          rm -rf "$STAGING_DIR"
        else
          if [ -d "$BACKUP_APP" ]; then
            mv "$BACKUP_APP" "$TARGET_APP"
          fi
          exit 1
        fi
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = [scriptURL.path]
        launcher.standardInput = FileHandle.nullDevice
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try launcher.run()
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
