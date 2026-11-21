import AppKit

private typealias Descriptor = NSAppleEventDescriptor

private func code(_ text: String) -> UInt32 {
    precondition(text.utf8.count == 4)
    return text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

/// Addresses an already running instance by PID so a playback command cannot launch a player.
private struct PlayerEvents {
    let pid: pid_t

    @discardableResult
    func send(_ suite: String, _ command: String, object: Descriptor? = nil) throws -> Descriptor {
        let event = Descriptor(eventClass: code(suite), eventID: code(command),
                               targetDescriptor: Descriptor(processIdentifier: pid), returnID: -1, transactionID: 0)
        if let object { event.setParam(object, forKeyword: code("----")) }
        let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 2)
        if let error = reply.paramDescriptor(forKeyword: code("errn")), error.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value))
        }
        return reply.paramDescriptor(forKeyword: code("----")) ?? .null()
    }

    func property(_ key: String, of container: Descriptor = .null()) -> Descriptor {
        let record = Descriptor.record()
        record.setDescriptor(Descriptor(typeCode: code("prop")), forKeyword: code("want"))
        record.setDescriptor(Descriptor(enumCode: code("prop")), forKeyword: code("form"))
        record.setDescriptor(Descriptor(typeCode: code(key)), forKeyword: code("seld"))
        record.setDescriptor(container, forKeyword: code("from"))
        return record.coerce(toDescriptorType: code("obj "))!
    }

    func get(_ key: String) throws -> Descriptor {
        try send("core", "getd", object: property(key))
    }
}

enum NativePlayer: String, CaseIterable {
    case music = "com.apple.Music"
    case tv = "com.apple.TV"
    case spotify = "com.spotify.client"
    case vlc = "org.videolan.vlc"

    var name: String {
        switch self {
        case .music: return "Music"
        case .tv: return "TV"
        case .spotify: return "Spotify"
        case .vlc: return "VLC"
        }
    }

    fileprivate var suite: String { self == .spotify ? "spfy" : "hook" }
}

/// Confined to one worker queue. Keep the track and process together to avoid
/// resuming a different item after a track change, app quit or relaunch.
final class NativePlayback {
    let player: NativePlayer
    private var paused: (app: NSRunningApplication, track: String)?

    init(_ player: NativePlayer) { self.player = player }

    func update(suppress: Bool) throws {
        guard suppress || paused != nil else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).first else {
            paused = nil
            return
        }
        if paused?.app != app { paused = nil }
        guard suppress || paused != nil else { return }

        let events = PlayerEvents(pid: app.processIdentifier)
        let state: (playing: Bool, resumable: Bool)
        if player == .vlc {
            let playing = try events.get("AAPL").booleanValue
            state = (playing, !playing)
        } else {
            let value = try events.get("pPlS").enumCodeValue
            state = (value == code("kPSP"), value == code("kPSp"))
        }

        if suppress, !state.playing { return }
        if !suppress, !state.resumable { paused = nil; return }
        let track: String?
        if player == .vlc {
            track = try events.get("AAPA").stringValue
        } else {
            let id = player == .spotify ? "spur" : "pPIS"
            track = try events.send("core", "getd", object: events.property(id, of: events.property("pTrk"))).stringValue
        }
        guard let track, !track.isEmpty else { paused = nil; return }
        if suppress {
            if player == .vlc { try events.send("VLC#", "VLC1") }
            else { try events.send(player.suite, "Paus") }
            paused = (app, track)
        } else {
            if paused?.track == track {
                if player == .vlc { try events.send("VLC#", "VLC1") }
                else { try events.send(player.suite, "Play") }
            }
            paused = nil
        }
    }
}
