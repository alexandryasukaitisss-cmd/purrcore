import AppKit
import Darwin
import Foundation
import PurrCoreCore
import UserNotifications

@MainActor
enum SmartAlertNotifier {
    private static var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static func requestAuthorizationIfNeeded() {
        guard canUseUserNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ event: SmartAlertEvent) {
        guard canUseUserNotifications else { return }
        let content = UNMutableNotificationContent()
        content.sound = .default

        switch event.kind {
        case .criticalMemory:
            content.title = tr("Критическое давление памяти")
            if let name = event.topProcessName, let bytes = event.topProcessMemoryBytes {
                content.body = tr("Больше всего памяти занимает %@ (%@).", tr(name), MetricFormat.bytes(bytes))
            } else {
                content.body = tr("macOS активно сжимает память и использует Swap.")
            }
        case .highThermal:
            content.title = tr("Сильный нагрев Mac")
            if let name = event.topProcessName, let cpu = event.topProcessCPUPercent {
                content.body = tr("Система ограничивает частоты. Основная нагрузка: %@ (%@).", tr(name), MetricFormat.percent(cpu))
            } else {
                content.body = tr("macOS перешла в режим теплового ограничения производительности.")
            }
        case .sustainedHighCPU:
            content.title = tr("Высокая загрузка CPU больше 3 минут")
            if let name = event.topProcessName, let cpu = event.topProcessCPUPercent {
                content.body = tr("Основной потребитель: %@ (%@).", tr(name), MetricFormat.percent(cpu))
            } else {
                content.body = tr("Процессор загружен выше 85% уже несколько минут подряд.")
            }
        case .lowDiskSpace:
            content.title = tr("Мало свободного места на SSD")
            if let free = event.freeDiskBytes {
                content.body = tr("На системном диске осталось всего %@.", MetricFormat.bytes(free))
            } else {
                content.body = tr("На системном диске осталось меньше 15 ГБ.")
            }
        }

        let request = UNNotificationRequest(
            identifier: "purrcore.\(event.kind.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

@MainActor
enum ProcessActions {
    static func revealInFinder(_ sample: ProcessGroupSample) {
        guard let bundlePath = sample.bundlePath else { return }
        let url = URL(fileURLWithPath: bundlePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func quit(_ sample: ProcessGroupSample) {
        guard sample.canTerminate, let pid = sample.representativePID, pid > 1 else { return }
        if let running = NSRunningApplication(processIdentifier: pid) {
            if !running.terminate() {
                _ = Darwin.kill(pid, SIGTERM)
            }
        } else {
            _ = Darwin.kill(pid, SIGTERM)
        }
    }

    static func confirmAndForceQuit(_ sample: ProcessGroupSample) {
        guard sample.canTerminate, let pid = sample.representativePID, pid > 1 else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("Принудительно завершить «%@»?", tr(sample.displayName))
        alert.informativeText = tr("Несохранённые изменения в этом приложении могут быть потеряны.")
        alert.addButton(withTitle: tr("Принудительно завершить"))
        alert.addButton(withTitle: tr("Отмена"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let running = NSRunningApplication(processIdentifier: pid) {
            if !running.forceTerminate() {
                _ = Darwin.kill(pid, SIGKILL)
            }
        } else {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }
}
