import AppKit
import SwiftUI

@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?
    private weak var activeModel: AppModel?

    func show(model: AppModel) {
        activeModel = model
        model.setSurface(.dashboard, active: true)
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
        activeModel?.setSurface(.dashboard, active: false)
        activeModel = nil
        windowController?.window?.contentViewController = nil
        windowController = nil
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?
    private weak var activeModel: AppModel?

    func show(model: AppModel) {
        activeModel = model
        model.setSurface(.settings, active: true)
        if let window = windowController?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = tr("Настройки PurrCore")
        window.minSize = NSSize(width: 560, height: 520)
        window.setFrameAutosaveName("PurrCoreSettings")
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        activeModel?.setSurface(.settings, active: false)
        activeModel = nil
        windowController?.window?.contentViewController = nil
        windowController = nil
    }
}

@MainActor
final class SSDHealthWindowController: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?
    private weak var activeModel: AppModel?

    func show(model: AppModel) {
        activeModel = model
        model.setSurface(.ssdHealth, active: true)
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
        activeModel?.setSurface(.ssdHealth, active: false)
        activeModel = nil
        windowController?.window?.contentViewController = nil
        windowController = nil
    }
}
