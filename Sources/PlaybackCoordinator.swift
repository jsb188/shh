import Foundation

struct PlaybackRequest: Equatable {
    var active: Bool
    var exclusions: Set<String>
}

/// Each integration gets a serial worker. A slow player or permission prompt
/// cannot delay the other players, and timer ticks cannot build up a backlog.
final class PlaybackWorker {
    let name: String
    private let queue: DispatchQueue
    private let apply: (PlaybackRequest) throws -> Void
    private var pending: PlaybackRequest?
    private var busy = false
    private var retryAfter = Date.distantPast
    private var failed: PlaybackRequest?
    private var releaseRetry: DispatchWorkItem?
    var onResult: ((String?) -> Void)?
    var onIdle: (() -> Void)?

    init(name: String, apply: @escaping (PlaybackRequest) throws -> Void) {
        self.name = name
        self.apply = apply
        queue = DispatchQueue(label: "shh.playback." + name)
    }

    // Called on the main queue, including completion callbacks.
    func submit(_ request: PlaybackRequest) {
        releaseRetry?.cancel()
        pending = request
        drain()
    }

    private func drain() {
        guard !busy else { return }
        guard let request = pending else { onIdle?(); return }
        pending = nil
        if onIdle == nil, failed == request, Date() < retryAfter { onIdle?(); return }
        busy = true
        queue.async {
            let result = Result { try self.apply(request) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.failed = nil
                    self.onResult?(nil)
                case .failure(let error):
                    let firstFailure = self.failed != request
                    self.failed = request
                    self.retryAfter = Date().addingTimeInterval(10)
                    let nsError = error as NSError
                    self.onResult?(nsError.code == -1743
                        ? "Allow Shh to control " + self.name + " in System Settings → Privacy & Security → Automation."
                        : error.localizedDescription)
                    // Idle monitoring has no periodic playback sweep. Retry a
                    // transient release failure once unless a newer request arrives.
                    if !request.active && firstFailure && self.pending == nil && self.onIdle == nil {
                        let retry = DispatchWorkItem { [weak self] in self?.submit(request) }
                        self.releaseRetry = retry
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10.1, execute: retry)
                    }
                }
                self.busy = false
                self.drain()
            }
        }
    }
}

final class PlaybackCoordinator {
    private let workers: [PlaybackWorker]
    var onIssue: ((String, String?) -> Void)?

    init() {
        let chrome = ChromePlayback()
        let silencer = AudioSilencer()
        var workers = NativePlayer.allCases.map { player in
            let playback = NativePlayback(player)
            return PlaybackWorker(name: player.name) { request in
                try playback.update(suppress: request.active && !request.exclusions.contains(player.rawValue))
            }
        }
        workers.append(PlaybackWorker(name: "Google Chrome") { request in
            if request.active && !request.exclusions.contains(ChromePlayback.bundleID) {
                try chrome.pause()
            } else {
                try chrome.resume()
            }
        })
        workers.append(PlaybackWorker(name: "System audio") { request in
            if request.active {
                try silencer.update(excluding: request.exclusions)
            } else {
                silencer.stop()
            }
        })
        self.workers = workers
        for worker in workers {
            let name = worker.name
            worker.onResult = { [weak self] message in self?.onIssue?(name, message) }
        }
    }

    func update(active: Bool, exclusions: Set<String>) {
        let request = PlaybackRequest(active: active, exclusions: exclusions)
        workers.forEach { $0.submit(request) }
    }

    func shutDown(completion: @escaping () -> Void) {
        var remaining = workers.count
        for worker in workers {
            worker.onIdle = { [weak worker] in
                worker?.onIdle = nil
                remaining -= 1
                if remaining == 0 { completion() }
            }
            worker.submit(PlaybackRequest(active: false, exclusions: []))
        }
    }
}
