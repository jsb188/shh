import CoreAudio
import Foundation

/// Observes Core Audio client activity without opening the microphone.
@MainActor
final class MicrophoneMonitor {
    private let onChange: (Bool) -> Void
    private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var recoveryTimer: Timer?
    private var lastActive: Bool?
    private let system = AudioObjectID(kAudioObjectSystemObject)

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard recoveryTimer == nil else { return }
        // Notifications drive normal operation. The timer also recovers when the
        // audio service restarts or a client exits while a listener is being added.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.05
        recoveryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func stop() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        for id in Array(listeners.keys) { removeListener(from: id) }
        lastActive = nil
    }

    private func refresh() {
        guard recoveryTimer != nil else { return }
        listen(to: system)
        guard let processes = ids(system, kAudioHardwarePropertyProcessObjectList) else { return }

        let clients = Set(processes)
        for id in listeners.keys.filter({ $0 != system && !clients.contains($0) }) {
            removeListener(from: id)
        }
        for id in clients { listen(to: id) }

        // Ignore our own private output tap, which also presents as an input client.
        let active = clients.contains { id in
            guard scalar(id, kAudioProcessPropertyIsRunningInput) == 1,
                  let pid = scalar(id, kAudioProcessPropertyPID),
                  pid != UInt32(getpid()) else { return false }

            guard let devices = ids(id, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput),
                  !devices.isEmpty else { return true }
            return devices.contains(where: isMicrophoneInput)
        }
        if lastActive != active {
            lastActive = active
            onChange(active)
        }
    }

    private func isMicrophoneInput(_ device: AudioObjectID) -> Bool {
        switch scalar(device, kAudioDevicePropertyTransportType) {
        case kAudioDeviceTransportTypeVirtual:
            // Loopback drivers can carry speaker output without opening a microphone.
            return false
        case kAudioDeviceTransportTypeAggregate:
            guard let members = ids(device, kAudioAggregateDevicePropertyActiveSubDeviceList) else {
                return true
            }
            // A process tap may have a clock/output device and no real input.
            return members.contains { member in
                scalar(member, kAudioDevicePropertyTransportType) != kAudioDeviceTransportTypeVirtual &&
                !(ids(member, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput) ?? []).isEmpty
            }
        default:
            return true
        }
    }

    private func listenerAddress(_ id: AudioObjectID) -> AudioObjectPropertyAddress {
        address(id == system ? kAudioHardwarePropertyProcessObjectList : kAudioProcessPropertyIsRunningInput)
    }

    private func listen(to id: AudioObjectID) {
        guard listeners[id] == nil else { return }
        var property = listenerAddress(id)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if AudioObjectAddPropertyListenerBlock(id, &property, .main, listener) == noErr {
            listeners[id] = listener
        }
    }

    private func removeListener(from id: AudioObjectID) {
        guard let listener = listeners.removeValue(forKey: id) else { return }
        var property = listenerAddress(id)
        AudioObjectRemovePropertyListenerBlock(id, &property, .main, listener)
    }

    private func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func scalar(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var property = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func ids(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID]? {
        var property = address(selector, scope)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &bytes) == noErr else { return nil }
        let stride = MemoryLayout<AudioObjectID>.stride
        guard bytes > 0 else { return [] }
        guard Int(bytes).isMultiple(of: stride) else { return nil }
        var values = [AudioObjectID](repeating: 0, count: Int(bytes) / stride)
        let status = values.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(id, &property, 0, nil, &bytes, buffer.baseAddress!)
        }
        guard status == noErr, Int(bytes).isMultiple(of: stride) else { return nil }
        return Array(values.prefix(Int(bytes) / stride))
    }
}
