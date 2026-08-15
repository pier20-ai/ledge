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
/// - **Exactly one blank slot, reachable past either end.** flow.md: "Walking
///   past either end lands on the blank slot — at most one blank exists." The
///   slots therefore form a *ring* with the blank as its last member: stepping
///   right off the last app and stepping left off the first app both land on the
///   same blank, which is what "at most one" means when you can walk in circles.
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

    /// The ring, in order: every app, then the one blank.
    public var slots: [Slot] { apps.map(Slot.app) + [.blank] }

    /// Where a presentation sits on the strip, or nil when it is not a strip
    /// surface at all (the permission card, the placeholder with no app).
    public func slot(for presentation: ShellPresentation) -> Slot? {
        if case .newApp = presentation { return .blank }
        guard let app = presentation.app else { return nil }
        return apps.contains(app) ? .app(app) : nil
    }

    /// Walk `steps` stops from `slot`, wrapping through the blank.
    ///
    /// `steps` is signed: `-1` is `‹`, `+1` is `›`. A strip with no apps at all
    /// is one blank slot, and walking it stays where it is — there is nowhere
    /// else to be, and refusing is more honest than pretending to move.
    public func step(from slot: Slot?, by steps: Int) -> Slot {
        let ring = slots
        guard !ring.isEmpty else { return .blank }
        let count = ring.count
        // An unknown starting point — a surface that is not on the strip at all,
        // like the placeholder card — is treated as standing in the *seam*
        // between the last slot and the first. `›` walks onto the first session,
        // `‹` onto the blank, and neither answer needs a special case anywhere
        // else. Which side of the seam you are on depends on the direction you
        // are about to walk, which is the only thing that makes a seam a place.
        let start = slot.flatMap { ring.firstIndex(of: $0) } ?? (steps > 0 ? -1 : count)
        let index = ((start + steps) % count + count) % count
        return ring[index]
    }
}
