import AppKit
import UniformTypeIdentifiers

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private var exclusions: [String: String] = [:]
    private var enabled = true
    private var microphoneActive = false
    private var shortcutHeld = false
    private var watchShortcut = true
    private var active: Bool { enabled && (microphoneActive || shortcutHeld) }
    private var shuttingDown = false
    private var timer: Timer?
    private let playback = PlaybackCoordinator()
    private var issues: [String: String] = [:]
    private lazy var microphone = MicrophoneMonitor { [weak self] active in
        guard let self else { return }
        let wasActive = self.active
        self.microphoneActive = active
        self.activityChanged(from: wasActive)
    }
    private lazy var dictationHold = DictationHoldMonitor { [weak self] held in
        guard let self else { return }
        let wasActive = self.active
        self.shortcutHeld = held
        self.activityChanged(from: wasActive)
    }

    private func activityChanged(from wasActive: Bool) {
        guard !shuttingDown else { return }
        if wasActive != active {
            updateTimer()
            sync()
        }
        updateIcon()
    }

    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        exclusions = defaults.dictionary(forKey: "excludedApps") as? [String: String] ?? [:]
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        playback.onIssue = { [weak self] name, message in
            self?.issues[name] = message
            self?.updateIcon()
        }
        menu.delegate = self
        status.menu = menu
        updateIcon()
        watchShortcut = defaults.object(forKey: "watchRightOption") as? Bool ?? true
        if enabled {
            if watchShortcut { dictationHold.start() }
            microphone.start()
        }
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard active && enabled else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sync() {
        guard !shuttingDown else { return }
        playback.update(active: enabled && active, exclusions: Set(exclusions.keys))
    }

    private var statusText: String {
        if !enabled { return "Monitoring is off" }
        if shortcutHeld { return "Dictation shortcut held" }
        return active ? "Microphone in use" : "Waiting for microphone"
    }

    private func updateIcon() {
        let symbol = !enabled ? "mic.slash" : (active ? "mic.fill" : "mic")
        status.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Shh — " + statusText)
        status.button?.toolTip = "Shh — " + statusText + (issues.isEmpty ? "" : " • Check playback issues")
    }

    private func item(_ title: String, _ action: Selector? = nil, in menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        _ = item(statusText, in: menu)
        menu.addItem(.separator())
        let toggle = item("Monitor Microphone", #selector(toggleMonitoring), in: menu)
        toggle.state = enabled ? .on : .off

        let shortcut = item("Pause While Holding Right Option", #selector(toggleShortcut), in: menu)
        shortcut.state = watchShortcut ? .on : .off

        let excluded = NSMenu()
        let submenu = item("Excluded Apps", in: menu)
        submenu.submenu = excluded
        for (id, name) in exclusions.sorted(by: { $0.value.localizedStandardCompare($1.value) == .orderedAscending }) {
            let entry = item(name, #selector(removeExclusion(_:)), in: excluded)
            entry.representedObject = id
            entry.toolTip = "Click to remove from exclusions"
            entry.state = .on
        }
        if !exclusions.isEmpty { excluded.addItem(.separator()) }
        _ = item("Exclude an App…", #selector(addExclusion), in: excluded)

        if !issues.isEmpty {
            let details = NSMenu()
            for (name, message) in issues.sorted(by: { $0.key < $1.key }) {
                item(name + "…", #selector(showIssue(_:)), in: details).representedObject = message
            }
            item("Playback Issues", in: menu).submenu = details
        }
        _ = item("Playback Setup…", #selector(showSetup), in: menu)
        menu.addItem(.separator())
        item("Quit Shh", #selector(quit), in: menu).keyEquivalent = "q"
    }

    @objc private func toggleMonitoring() {
        enabled.toggle()
        defaults.set(enabled, forKey: "enabled")
        if enabled {
            if watchShortcut { dictationHold.start() }
            microphone.start()
        } else {
            dictationHold.stop()
            microphone.stop()
            microphoneActive = false
            updateTimer()
        }
        sync()
        updateIcon()
    }

    @objc private func toggleShortcut() {
        watchShortcut.toggle()
        defaults.set(watchShortcut, forKey: "watchRightOption")
        if enabled && watchShortcut { dictationHold.start() } else { dictationHold.stop() }
    }

    @objc private func addExclusion() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Exclude Apps from Playback Control"
        panel.prompt = "Exclude"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier {
                exclusions[id] = url.deletingPathExtension().lastPathComponent
            }
        }
        saveExclusions()
    }

    @objc private func removeExclusion(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        exclusions.removeValue(forKey: id)
        saveExclusions()
    }

    private func saveExclusions() {
        defaults.set(exclusions, forKey: "excludedApps")
        sync()
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    @objc private func showSetup() {
        alert("Playback setup", """
        For Chrome videos and music, turn on View → Developer → Allow JavaScript from Apple Events in Chrome.

        Allow Shh to control your players when macOS asks. System audio recording permission lets Shh silence other app audio while the microphone is in use. Muted streams continue playing. Shh discards the audio.

        Choose Excluded Apps to keep an app audible, including call audio. An excluded app using the microphone still triggers Shh.
        """)
    }

    @objc private func showIssue(_ sender: NSMenuItem) {
        alert(sender.title, sender.representedObject as? String ?? "")
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !shuttingDown {
            shuttingDown = true
            timer?.invalidate()
            microphone.stop()
            dictationHold.stop()
            playback.shutDown { DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) } }
        }
        return .terminateLater
    }
}

guard CGSessionCopyCurrentDictionary() != nil else {
    FileHandle.standardError.write(Data("Open Shh from a logged-in macOS desktop session.\n".utf8))
    exit(EXIT_FAILURE)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
