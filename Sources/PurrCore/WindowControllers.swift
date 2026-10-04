import AppKit
import SwiftUI

@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?

    func show(model: AppModel) {
        if let window = windowController?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PurrCore"
        window.minSize = NSSize(width: 880, height: 600)
        window.setFrameAutosaveName("PurrCoreDashboard")
        window.contentViewController = NSHostingController(rootView: DashboardView(model: model))
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        windowController?.window?.contentViewController = nil
        windowController = nil
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?

    func show(model: AppModel) {
        if let window = windowController?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = tr("Настройки PurrCore")
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        windowController?.window?.contentViewController = nil
        windowController = nil
    }
}

@MainActor
final class SSDHealthWindowController: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?

    func show(model: AppModel) {
        if let window = windowController?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = tr("Здоровье SSD")
        window.minSize = NSSize(width: 500, height: 430)
        window.setFrameAutosaveName("PurrCoreSSDHealth")
        window.contentViewController = NSHostingController(rootView: SSDHealthView(model: model))
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        windowController?.window?.contentViewController = nil
        windowController = nil
    }
}
