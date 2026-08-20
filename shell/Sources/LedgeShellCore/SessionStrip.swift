import Foundation

/// **The strip** (flow.md, "The strip"): the visit surface is a row of sessions
/// that `‹|›` — and a horizontal swipe — walks.
///
/// Session ≡ app for now: a session is what an app puts on stage, and until the
/// conversation lands (Phase C) there is exactly one session per installed app.
/// The key type is deliberately a plain `String` app id so that refactor is a
/// change of what `Slot.app` carries, not of every caller.
///
/// Two laws and nothing else:
///
/// - **Installed apps in registry order.** The catalog is the only source (spec
///   §3.6, full snapshots), so the strip cannot drift from the app list.
/// - **Exactly one blank slot, reachable past either end — and the blank IS
///   the end.** flow.md: "Walking past either end lands on the blank slot — at
///   most one blank exists." Stepping right off the last app and stepping left
///   off the first app both land on the same blank; stepping *outward from the
///   blank* goes nowhere (G2.7: the strip used to be a ring, and swiping past
///   the blank silently wrapped to the far end — "Don't do this! Show some
///   indication that this is the end").
public struct SessionStrip: Equatable, Sendable {
    /// One stop on the strip. The blank slot has no stage — it is a pure
    /// conversation, and the shell presents it as the `.newApp` surface until
    /// the conversation is real (flow.md: "A blank slot has no stage: chat
    /// only, no glass toggle. First launch opens here.").
    public enum Slot: Equatable, Sendable {
        case app(String)
        case blank
    }

    /// Enabled apps in catalog order. Held rather than recomputed so a walk
    /// taken between two catalog snapshots is answered against one of them.
    public private(set) var apps: [String]

    public init(apps: [String] = []) {
        self.apps = apps
    }

    /// Rebuild from a catalog snapshot (spec §3.6). Disabled apps are not on the
    /// strip: a disabled app is one the user turned off, and walking onto it
    /// would be walking onto nothing.
    public init(catalog: [CatalogApp]) {
        self.apps = catalog
            .filter(\.enabled)
            .sorted { $0.order < $1.order }
            .map(\.id)
    }

    /// The strip, in order: every app, then the one blank.
    public var slots: [Slot] { apps.map(Slot.app) + [.blank] }

    /// Which end of the strip the blank slot is currently standing in for. The
    /// blank is one slot reachable past *either* end, so "which way is back to
    /// the apps" depends on the direction it was entered from — remembered by
    /// the caller (the walk's own state) and passed back in.
    public enum BlankEnd: Equatable, Sendable {
        case leading
        case trailing
    }

    /// Where a presentation sits on the strip, or nil when it is not a strip
    /// surface at all (the permission card, the placeholder with no app).
    public func slot(for presentation: ShellPresentation) -> Slot? {
        if case .newApp = presentation { return .blank }
        guard let app = presentation.app else { return nil }
        return apps.contains(app) ? .app(app) : nil
    }

    /// Walk `steps` stops from `slot` along the LINE. `steps` is signed: `-1`
    /// is `‹`, `+1` is `›`.
    ///
    /// Returns `nil` when the walk runs off the strip's end — outward from the
    /// blank — which is the caller's cue to *say so* (the end bounce) rather
    /// than move. `blankEnd` is which end the blank is currently standing in
    /// for; the caller remembers it because only the walk that landed there
    /// knows.
    public func step(from slot: Slot?, by steps: Int, blankEnd: BlankEnd) -> Slot? {
        guard steps != 0 else { return slot }
        switch slot {
        case .blank:
            // Inward is the neighbouring session; outward is the end. A strip
            // with no apps has no inward — every direction is the end.
            switch blankEnd {
            case .trailing:
                return steps < 0 ? apps.last.map(Slot.app) : nil
            case .leading:
                return steps > 0 ? apps.first.map(Slot.app) : nil
            }
        case .app(let app):
            guard let index = apps.firstIndex(of: app) else { return .blank }
            let target = index + steps
            // Past either end of the apps: the blank. Never *past* the blank in
            // one gesture — one step is one stop.
            guard target >= 0, target < apps.count else { return .blank }
            return .app(apps[target])
        case nil:
            // An unknown starting point — a surface that is not on the strip at
            // all, like the placeholder card — is treated as standing in the
            // *seam* past the strip's ends: `›` walks onto the first session,
            // `‹` onto the blank.
            return steps > 0 ? apps.first.map(Slot.app) ?? .blank : .blank
        }
    }
}
