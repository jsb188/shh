import AppKit
import IOKit.hidsystem

/// Sample only modifier state. This observes the hold across apps without
/// registering a conflicting hotkey or receiving the user's keystrokes.
@MainActor
final class DictationHoldMonitor {
    private var timer: Timer?
    private let onChange: (Bool) -> Void
    private var held = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        setHeld(false)
    }

    private func refresh() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        setHeld(flags.rawValue & UInt64(NX_DEVICERALTKEYMASK) != 0)
    }

    private func setHeld(_ value: Bool) {
        guard value != held else { return }
        held = value
        onChange(value)
    }
}
