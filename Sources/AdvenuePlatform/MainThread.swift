import Foundation

/// Runs `work` on the main thread and returns its result, hopping to the main
/// queue when the caller is elsewhere.
///
/// UIKit's singletons (`UIScreen.main`, `UIDevice.current`) and
/// `UIApplication`'s `applicationState` are main-actor isolated under Swift 6,
/// but the collectors stay synchronous: they run on background tasks and
/// their public signatures predate the isolation. Marking them `@MainActor`
/// would push `await` onto every caller for a handful of property reads; a
/// bounded synchronous hop keeps the API and the data.
///
/// The hop is safe because no caller blocks the main thread waiting for it:
/// production calls from fire-and-forget tasks, and tests either run on the
/// main thread (no hop) or suspend at `await` (the queue drains).
public func onMainSync<T: Sendable>(_ work: @MainActor () -> T) -> T {
  if Thread.isMainThread {
    return MainActor.assumeIsolated(work)
  }
  // On the main queue the thread is right; assumeIsolated states that fact
  // for the compiler. The closure never escapes: `sync` runs it before it
  // returns.
  return DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
}
