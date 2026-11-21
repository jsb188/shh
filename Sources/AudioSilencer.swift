import AppKit
import CoreAudio

/// Call on one serial queue. The tap covers only the selected Core Audio process objects.
@available(macOS 14.2, *)
final class AudioSilencer {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var tappedProcesses = Set<AudioObjectID>()
    private var tapUUID = UUID()

    /// Reconcile during microphone use to catch new audio clients and changed exclusions.
    func update(excluding excludedBundleIDs: Set<String>) throws {
        let processes: Set<AudioObjectID>
        do {
            processes = try outputProcesses(excluding: excludedBundleIDs)
        } catch {
            // Release any old selection if new exclusions cannot be applied.
            stop()
            throw error
        }
        guard processes != tappedProcesses else { return }
        guard !processes.isEmpty else {
            stop()
            return
        }

        if tap != kAudioObjectUnknown {
            let description = makeDescription(for: processes)
            var reference = Unmanaged.passUnretained(description)
            var address = property(kAudioTapPropertyDescription)
            let status = withExtendedLifetime(description) {
                AudioObjectSetPropertyData(tap, &address, 0, nil,
                                           UInt32(MemoryLayout.size(ofValue: reference)), &reference)
            }
            if status == noErr {
                tappedProcesses = processes
                return
            }
            // A device or client can disappear between enumeration and reconfiguration.
            stop()
        }

        tapUUID = UUID()
        do {
            let description = makeDescription(for: processes)
            try check(AudioHardwareCreateProcessTap(description, &tap), "create an audio tap")
            let configuration: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Shh Audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID.uuidString]],
            ]
            try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregate),
                      "create the tap input device")
            // A tap-only aggregate has no hardware microphone or output. Pull its input
            // to activate .mutedWhenTapped and discard each buffer in the callback.
            try check(AudioDeviceCreateIOProcID(aggregate, { _, _, _, _, _, _, _ in noErr },
                                               nil, &ioProc), "prepare audio silencing")
            try check(AudioDeviceStart(aggregate, ioProc), "start audio silencing")
            tappedProcesses = processes
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
            self.ioProc = nil
        }
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
        tappedProcesses.removeAll()
    }

    deinit { stop() }

    private func makeDescription(for processes: Set<AudioObjectID>) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: Array(processes))
        description.uuid = tapUUID
        description.name = "Shh"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        return description
    }

    private func outputProcesses(excluding exclusions: Set<String>) throws -> Set<AudioObjectID> {
        var address = property(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size), "list audio clients")
        let stride = MemoryLayout<AudioObjectID>.stride
        guard Int(size).isMultiple(of: stride) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioHardwareBadPropertySizeError))
        }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        guard !objects.isEmpty else { return [] }
        try objects.withUnsafeMutableBytes {
            try check(AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!),
                      "read audio clients")
        }
        guard Int(size).isMultiple(of: stride) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioHardwareBadPropertySizeError))
        }
        return Set(objects.prefix(Int(size) / stride).filter { object in
            guard let rawPID = uint32(object, kAudioProcessPropertyPID),
                  rawPID != 0, pid_t(bitPattern: rawPID) != getpid(),
                  tappedProcesses.contains(object) || uint32(object, kAudioProcessPropertyIsRunningOutput) == 1
            else { return false }
            guard !exclusions.isEmpty else { return true }
            return !isExcluded(object, pid: pid_t(bitPattern: rawPID), exclusions: exclusions)
        })
    }

    private func isExcluded(_ object: AudioObjectID, pid: pid_t, exclusions: Set<String>) -> Bool {
        var address = property(kAudioProcessPropertyBundleID)
        var identifier: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: identifier))
        if AudioObjectGetPropertyData(object, &address, 0, nil, &size, &identifier) == noErr,
           let bundleID = identifier?.takeRetainedValue() as String?,
           exclusions.contains(bundleID) {
            return true
        }
        // Browser and Electron audio clients often run in nested helper bundles.
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathSize = UInt32(path.count)
        guard proc_pidpath(pid, &path, pathSize) > 0 else {
            guard let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
            return exclusions.contains(bundleID)
        }
        let executable = URL(fileURLWithFileSystemRepresentation: path, isDirectory: false, relativeTo: nil)
        var url = executable.deletingLastPathComponent()
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app", let id = Bundle(url: url)?.bundleIdentifier, exclusions.contains(id) {
                return true
            }
            url.deleteLastPathComponent()
        }
        return false
    }

    private func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = property(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status != noErr else { return }
        let message = "Couldn’t \(operation) (Core Audio \(status))."
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}
