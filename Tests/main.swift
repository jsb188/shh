// Regression check for mic release and exclusion edits while a player command is blocked.
// Build with Sources/*.swift except the app entry point, as described in test.sh.
import Foundation

checkChromeRestoration()
let worker = PlaybackWorker(name: "fixture") { request in
    if requests.isEmpty {
        guard releaseFirst.wait(timeout: .now() + 3) == .success else { fatalError("fixture timed out") }
    }
    requests.append(request)
}
let releaseFirst = DispatchSemaphore(value: 0)
var requests: [PlaybackRequest] = []
let initial = PlaybackRequest(active: true, exclusions: [])
let released = PlaybackRequest(active: false, exclusions: ["test.player"])
worker.onIdle = {
    precondition(requests == [initial, released], "obsolete playback commands must be discarded")
    print("Playback worker restored the latest state.")
    exit(EXIT_SUCCESS)
}
worker.submit(initial)
worker.submit(PlaybackRequest(active: true, exclusions: ["test.player"]))
worker.submit(released)
releaseFirst.signal()
DispatchQueue.main.asyncAfter(deadline: .now() + 5) { fatalError("worker did not drain") }
dispatchMain()
