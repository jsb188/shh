import AppKit
import Carbon

/// Uses Chrome's scripting dictionary directly, so requests target an existing PID and
/// never open a browser window. Call from the playback worker's serial queue.
final class ChromePlayback {
    static let bundleID = "com.google.Chrome"

    private typealias Descriptor = NSAppleEventDescriptor
    private var session: UUID?
    private var affectedTabs = Set<String>()
    private var nextTabIndex = 0

    func pause() throws {
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            return
        }
        let token = session ?? UUID()
        session = token
        try update(chrome, token: token, pausing: true)
    }

    func resume() throws {
        guard let token = session else { return }
        if !affectedTabs.isEmpty, let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first {
            try update(chrome, token: token, pausing: false)
        }
        session = nil
        affectedTabs.removeAll()
        nextTabIndex = 0
    }

    private func update(_ chrome: NSRunningApplication, token: UUID, pausing: Bool) throws {
        let target = Descriptor(processIdentifier: chrome.processIdentifier)
        let tabs = try Self.tabs(in: target)
        let ids = tabs.map(Self.tabID)
        affectedTabs.formIntersection(ids)
        let javascript = Descriptor(string: Self.mediaScript(token: token, pausing: pausing))
        var firstError: Error?
        let start = nextTabIndex
        let budget = ProcessInfo.processInfo.systemUptime + 1.25
        for offset in tabs.indices {
            let index = (start + offset) % tabs.count
            let id = ids[index]
            if pausing {
                // Yield to a pending microphone-off request. Start the next sweep at
                // the following tab, including when a sleeping renderer times out.
                if offset > 0 && ProcessInfo.processInfo.systemUptime >= budget { break }
                nextTabIndex = (index + 1) % tabs.count
            } else if !affectedTabs.contains(id) {
                continue
            }
            let tab = tabs[index]
            let execute = Descriptor(eventClass: Self.code("CrSu"), eventID: Self.code("ExJa"),
                                     targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                     transactionID: AETransactionID(kAnyTransactionID))
            execute.setParam(tab, forKeyword: AEKeyword(keyDirectObject))
            execute.setParam(javascript, forKeyword: Self.code("JvSc"))
            do {
                let ownsMedia = try Self.send(execute, timeout: 0.6)?.booleanValue ?? false
                if pausing && ownsMedia { affectedTabs.insert(id) } else { affectedTabs.remove(id) }
            } catch let error as NSError {
                // Delivery can succeed even when the reply times out.
                if pausing && error.code == Int(errAETimeout) { affectedTabs.insert(id) }
                // A tab/window can disappear between enumeration and the command.
                if [Int(errAENoSuchObject), Int(procNotFound), 9, 11].contains(error.code) { continue }
                if error.code == Int(errAEEventNotPermitted) { throw error }
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private static func tabs(in target: Descriptor) throws -> [Descriptor] {
        // 'CrTb', 'CrSu', 'ExJa', and 'JvSc' are the codes in Chrome's scripting.sdef.
        let allWindows = try Self.every(FourCharCode(cWindow), in: Descriptor.null())
        let allTabs = try Self.every(Self.code("CrTb"), in: allWindows)
        let getTabs = Descriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
                                 targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                 transactionID: AETransactionID(kAnyTransactionID))
        getTabs.setParam(allTabs, forKeyword: AEKeyword(keyDirectObject))
        guard let reply = try send(getTabs) else { return [] }
        return objectSpecifiers(in: reply)
    }

    private static func tabID(_ tab: Descriptor) -> String {
        // Chrome's unique tab ID survives a move between windows.
        if tab.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formUniqueID),
           let id = tab.forKeyword(AEKeyword(keyAEKeyData))?.stringValue { return id }
        return tab.data.base64EncodedString()
    }

    private static func code(_ text: StaticString) -> FourCharCode {
        text.withUTF8Buffer { bytes in bytes.reduce(0) { ($0 << 8) | UInt32($1) } }
    }

    private static func every(_ type: FourCharCode, in container: Descriptor) throws -> Descriptor {
        var all = OSType(kAEAll)
        let ordinal = Descriptor(descriptorType: DescType(typeAbsoluteOrdinal), bytes: &all, length: 4)
        let spec = Descriptor.record()
        spec.setDescriptor(Descriptor(typeCode: type), forKeyword: AEKeyword(keyAEDesiredClass))
        spec.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        spec.setDescriptor(Descriptor(enumCode: OSType(formAbsolutePosition)), forKeyword: AEKeyword(keyAEKeyForm))
        guard let ordinal else { throw CocoaError(.coderInvalidValue) }
        spec.setDescriptor(ordinal, forKeyword: AEKeyword(keyAEKeyData))
        guard let result = spec.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else {
            throw CocoaError(.coderInvalidValue)
        }
        return result
    }

    // "Every tab of every window" returns a list of lists of tab references.
    private static func objectSpecifiers(in item: Descriptor) -> [Descriptor] {
        if item.descriptorType == DescType(typeObjectSpecifier) { return [item] }
        guard item.descriptorType == DescType(typeAEList), item.numberOfItems > 0 else { return [] }
        return (1...item.numberOfItems).compactMap { item.atIndex($0) }.flatMap(objectSpecifiers)
    }

    private static func send(_ event: Descriptor, timeout: TimeInterval = 2) throws -> Descriptor? {
        let reply: Descriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: timeout)
        } catch {
            throw chromeError((error as NSError).code, message: error.localizedDescription)
        }
        if let number = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), number.int32Value != 0 {
            let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
            throw chromeError(Int(number.int32Value), message: message)
        }
        return reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
    }

    private static func chromeError(_ number: Int, message: String?) -> NSError {
        let reason: String
        switch number {
        case Int(errAEEventNotPermitted):
            reason = "Allow Shh to control Google Chrome in System Settings → Privacy & Security → Automation."
        case 12: // Chrome's kJavaScriptUnsupported
            reason = "In Chrome, enable View → Developer → Allow JavaScript from Apple Events."
        default:
            reason = message ?? "Chrome playback control failed (\(number))."
        }
        return NSError(domain: "Shh.Chrome", code: number, userInfo: [NSLocalizedDescriptionKey: reason])
    }

    static func mediaScript(token: UUID, pausing: Bool) -> String {
        // State lives on individual elements in Chrome's isolated scripting world.
        // A fresh document or replacement player cannot inherit a previous pause.
        """
        (() => {
          const key = Symbol.for('shh.savedMedia');
          const token = '\(token.uuidString)';
          let ownsMedia = false;
          function visit(doc) {
            for (const media of doc.querySelectorAll('audio, video')) {
              if (\(pausing)) {
                if (!media.paused && !media.ended && !media.srcObject) {
                  media[key]?.clear();
                  const record = { token, source: media.currentSrc, url: doc.URL };
                  record.clear = () => {
                    media.removeEventListener('emptied', record.clear);
                    media.removeEventListener('playing', onPlaying);
                    if (media[key] === record) delete media[key];
                  };
                  const onPlaying = () => { if (!media.paused) record.clear(); };
                  media.pause();
                  media[key] = record;
                  media.addEventListener('emptied', record.clear);
                  media.addEventListener('playing', onPlaying);
                }
                if (media[key]?.token === token) ownsMedia = true;
              } else if (media[key]?.token === token) {
                const record = media[key];
                record.clear();
                if (media.paused && !media.ended && !media.srcObject &&
                    media.currentSrc === record.source && doc.URL === record.url) {
                  media.play().catch(() => {});
                }
              }
            }
            for (const frame of doc.querySelectorAll('iframe, frame')) {
              // Chrome exposes only same-origin frame documents to the calling tab.
              if (frame.contentDocument) visit(frame.contentDocument);
            }
          }
          visit(document);
          return ownsMedia;
        })()
        """
    }
}
