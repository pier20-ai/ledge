import Foundation

/// Latest-frame-wins coalescing for canvas draws (spec §3.4): if frames arrive
/// faster than the display refreshes, only the most recent op list per canvas is
/// kept. The AppKit canvas drains this on the next display-link tick.
///
/// Frames are keyed by `(app, canvas)`, not by canvas id alone: node ids are
/// allocated per app and restart at 1 in every worker (spec §3.1), so two apps
/// running at once routinely both own a node 12. Keying on the id alone lets one
/// app's frames land on another app's canvas.
public struct DrawCoalescer {
    public struct Key: Hashable, Sendable {
        public let app: String
        public let canvas: Int

        public init(app: String, canvas: Int) {
            self.app = app
            self.canvas = canvas
        }
    }

    private var latest: [Key: [JSONValue]] = [:]

    public init() {}

    public var isEmpty: Bool { latest.isEmpty }

    /// Replace any pending ops for `app`'s `canvas` with `ops`.
    public mutating func submit(app: String, canvas: Int, ops: [JSONValue]) {
        latest[Key(app: app, canvas: canvas)] = ops
    }

    /// Take and clear all pending frames, one entry per canvas.
    public mutating func drain() -> [(app: String, canvas: Int, ops: [JSONValue])] {
        let drained = latest.map { (app: $0.key.app, canvas: $0.key.canvas, ops: $0.value) }
        latest.removeAll(keepingCapacity: true)
        return drained
    }

    /// Drop any pending ops for a canvas that no longer exists.
    public mutating func discard(app: String, canvas: Int) {
        latest[Key(app: app, canvas: canvas)] = nil
    }

    /// Drop every pending frame for one app (its tree was discarded).
    public mutating func discard(app: String) {
        latest = latest.filter { $0.key.app != app }
    }

    public mutating func discardAll() {
        latest.removeAll(keepingCapacity: true)
    }
}
