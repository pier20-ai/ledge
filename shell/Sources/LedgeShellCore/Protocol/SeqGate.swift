import Foundation

/// Per-`(gen, app, sender)` sequence gating (spec §2). All counters are scoped
/// to a connection generation and reset by construction on reconnect, so this
/// gate only needs per-app state; the whole gate is discarded when a new
/// generation begins. A frame whose `seq <= last` for its app is stale and
/// dropped.
public struct SeqGate {
    private var last: [String: Int] = [:]

    public init() {}

    /// Record `seq` for `app` and report whether it is fresh (strictly greater
    /// than the last accepted value). Stale frames leave the recorded high-water
    /// mark unchanged.
    public mutating func accept(app: String, seq: Int) -> Bool {
        if let previous = last[app], seq <= previous {
            return false
        }
        last[app] = seq
        return true
    }
}
