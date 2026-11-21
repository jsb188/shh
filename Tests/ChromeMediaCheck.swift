import Foundation
import JavaScriptCore

/// Exercise Chrome's actual injected script without controlling a user's browser.
func checkChromeRestoration() {
    let context = JSContext()!
    context.exceptionHandler = { _, value in fatalError("JavaScript fixture failed: " + (value?.toString() ?? "")) }
    context.evaluateScript("""
        function element(paused) {
          return {paused, currentSrc: 'first', ended: false,
                  pause() { this.paused = true }, play() { this.paused = false; return Promise.resolve() },
                  addEventListener() {}, removeEventListener() {}};
        }
        const playing = element(false), paused = element(true), replaced = element(false);
        const call = element(false); call.srcObject = {};
        const frameMedia = element(false);
        const frameDoc = {URL: 'frame', querySelectorAll(q) { return q.startsWith('audio') ? [frameMedia] : [] }};
        const document = {URL: 'tab', querySelectorAll(q) {
          return q.startsWith('audio') ? [playing, paused, replaced, call] : [{contentDocument: frameDoc}];
        }};
        """)
    let session = UUID()
    let pause = ChromePlayback.mediaScript(token: session, pausing: true)
    let resume = ChromePlayback.mediaScript(token: session, pausing: false)
    precondition(context.evaluateScript(pause).toBool())
    precondition(context.evaluateScript("playing.paused && paused.paused && replaced.paused && frameMedia.paused && !call.paused").toBool())
    context.evaluateScript("replaced.currentSrc = 'second'")
    precondition(context.evaluateScript(pause).toBool())
    context.evaluateScript(resume)
    precondition(context.evaluateScript("!playing.paused && paused.paused && replaced.paused && !frameMedia.paused && !call.paused").toBool())
    print("Chrome media ownership and restoration checks passed.")
}
