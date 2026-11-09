import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = DragWatcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Icons.menuBar()
        statusItem.button?.toolTip = "Мандарин"
        rebuildMenu()
        watcher.start()

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            HUD.shared.info("Мандарин запущен", detail: "Тащите файл и зажмите ⇧ Shift — появится колесо конвертации.")
        }
    }

    private func rebuildMenu() {
        let m = NSMenu()
        let hint = NSMenuItem(title: "Тащите файл и зажмите ⇧ Shift", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        m.addItem(hint)
        m.addItem(.separator())

        let open = NSMenuItem(title: "Выбрать файлы…", action: #selector(openFiles), keyEquivalent: "o")
        open.target = self
        m.addItem(open)

        let login = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)

        m.addItem(.separator())
        m.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    @objc private func openFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let frame = NSScreen.main?.visibleFrame ?? .zero
        WheelController.shared.show(urls: panel.urls, at: NSPoint(x: frame.midX, y: frame.midY), mode: .click)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            HUD.shared.error("Не получилось: \(error.localizedDescription)")
        }
        rebuildMenu()
    }
}

/// Polls global mouse/modifier state: a file drag is detected when the system drag pasteboard
/// changes while the button is held; Shift during that drag summons the wheel under the cursor.
@MainActor
final class DragWatcher {
    private var timer: Timer?
    private var wasDown = false
    private var downChangeCount = 0
    private var dragging = false
    private var triggered = false

    func start() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let pb = NSPasteboard(name: .drag)
        let wheel = WheelController.shared

        if down && !wasDown {
            downChangeCount = pb.changeCount
            dragging = false
            triggered = false
        }
        if down {
            if !dragging && pb.changeCount != downChangeCount { dragging = true }
            if dragging && !triggered && NSEvent.modifierFlags.contains(.shift) && !wheel.isVisible {
                triggered = true
                let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
                if !urls.isEmpty {
                    wheel.show(urls: urls, at: NSEvent.mouseLocation, mode: .drag)
                }
            }
        }
        if !down && wasDown {
            if wheel.isVisible && wheel.mode == .drag { wheel.scheduleHide(after: 0.5) }
            dragging = false
        }
        wasDown = down
    }
}
