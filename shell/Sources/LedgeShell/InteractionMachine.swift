import Foundation
import LedgeShellCore

/// **The six-state interaction machine** — flow.md's Transitions table, as code.
///
/// Deliberately a value type with no AppKit, no timers and no presentation in
/// it: every row of that table is a pure `(state, event) → (state, effects)`
/// fact, and the things that are *not* pure — when Th has elapsed, whether a
/// session declares a summary, which app owns the wing — arrive as fields on the
/// event. That is what lets one test walk the entire table (see
/// `InteractionMachineTests`) rather than driving a live panel and hoping.
///
/// The controller owns the timers and turns effects into presentations. It is
/// the only thing that knows a `NotchPanel` exists.
struct InteractionMachine: Equatable {
    /// flow.md, "States": six states, five surfaces.
    enum State: String, Equatable, CaseIterable {
        /// The bare notch.
        case resting
        /// An app holds a wing.
        case ambient
        /// The hover's swell.
        case summary
        /// The notification's swell.
        case interruption
        /// The expanded surface.
        case visit
        /// The whole surface torn off as a floating window (flow.md, Parked).
        /// The notch sits bare behind it, wings paused; the window is deliberate,
        /// so nothing passive — no walk-away timeout, no click-outside — takes it
        /// away. Only the ⌃, or a click on the bare notch, flies it home.
        case parked
    }

    /// Which surface the transient states rose from, so "whence it came" is an
    /// answer and not a guess. Only Resting and Ambient can be underneath.
    enum Ground: String, Equatable {
        case resting
        case ambient

        var state: State { self == .ambient ? .ambient : .resting }
    }

    /// What the user or the system did. Anything the machine would otherwise
    /// have to *ask* about is carried here — see the type doc.
    enum Event: Equatable {
        /// An app took the collapsed wing (spec §3.3 arbitration).
        case wingGranted
        /// The wing's holder went idle past Ta, or released it.
        case wingReleased
        /// A notification arrived for `app`, in its class.
        case notificationArrived(app: String, priority: NotificationClass)
        /// The pointer entered the notch. Below Th, so: a promise and no more.
        case hoverBegan
        /// Th elapsed with the pointer still on the notch. `declaresSummary` is
        /// the focused session's answer — a `<summary>` node in its tree.
        case hoverThreshold(app: String?, declaresSummary: Bool)
        /// The pointer left the swell (or the notch, below Th).
        case pointerExit
        /// A click landed somewhere the shell owns.
        case click(Click)
        /// Ti elapsed on an ambient notification.
        case notificationTimeout
        /// Esc, with the visit up.
        case escape
        /// A click landed outside the shell entirely.
        case clickOutside
        /// Texit elapsed with the pointer fully away and nothing in flight.
        case exitTimeout
        /// `‹` / `›`, or a horizontal swipe across the visit.
        case walkStrip(steps: Int)
        /// The panel was dragged down off the notch, far enough to tear.
        case dragOffNotch
        /// The parked window's ⌃, or a click on the bare notch behind it.
        case flyHome
    }

    /// Where a click landed. The table distinguishes exactly these, because
    /// exactly these mean different things.
    enum Click: Equatable {
        /// The collapsed pill.
        case pill
        /// A wing on the collapsed pill.
        case wing
        /// Anywhere on the summary swell.
        case summary
        /// A notification's one action.
        case notificationAction
        /// A notification, anywhere but its action.
        case notificationElsewhere
    }

    /// What the controller must do about it. Effects are *orders*, not
    /// suggestions: the machine has already decided.
    enum Effect: Equatable {
        /// Swell the notch a breath (hover < Th).
        case promise
        /// Take the promise back.
        case unpromise
        /// Raise the summary for `app`, and arm nothing — a summary lives and
        /// dies by the pointer.
        case showSummary(app: String)
        /// Raise the notification for `app`. `dwell` is nil for alert-class:
        /// it holds until acted on (flow.md).
        case showNotification(app: String, dwell: TimeInterval?)
        /// Retract whichever swell is up.
        case retractSwell
        /// Open the visit. `app` nil means "whatever you were last in".
        case openVisit(app: String?)
        /// Run the notification's one action, then put the swell away.
        case runNotificationAction
        /// Close the visit back to the bare notch.
        case closeVisit
        /// Walk the session strip.
        case walkStrip(steps: Int)
        /// **Tear the whole surface off the notch** (flow.md: "Visit | drag the
        /// panel down off the notch | Parked"). The controller builds the window
        /// under the pointer; nothing about *where* is the machine's business.
        case park
        /// **Fly it home** — the parked window travelling back into the notch and
        /// becoming the visit again. `app` is the session that was in the window,
        /// so the visit that lands is the one that left.
        case flyHome(app: String?)
        /// Leave the ledge overview for the session it was zoomed out of. Esc in
        /// the overview is **Back**, not close-visit: the overview is a mode of
        /// the visit, and Esc leaves the mode before it leaves the visit.
        case leaveOverview
    }

    private(set) var state: State = .resting
    /// The state a transient surface rose from. flow.md's "whence it came".
    private(set) var ground: Ground = .resting
    /// The app whose swell is currently up, so a late timer can name it.
    private(set) var swellApp: String?
    /// The class of the notification currently up. Alert-class ignores Ti.
    private(set) var swellClass: NotificationClass = .ambient
    /// Whether an app holds a wing right now. Ambient is exactly this fact, and
    /// it has to survive a visit — closing the panel over a live wing goes back
    /// to Ambient, not to Resting.
    private(set) var wingHeld = false
    /// Whether the visit is zoomed out to **the ledge** (flow.md, "The strip":
    /// "Zoom out to the overview — the ledge").
    ///
    /// A *mode of the visit*, not a seventh state: flow.md's table has six
    /// states and the overview is not one of them — it walks the same strip, in
    /// the same panel, with the same wings, exactly as chat does. It is here
    /// rather than in the controller only because one row turns on it: Esc in
    /// the overview is Back, and that is a fact about the table.
    private(set) var showingOverview = false
    /// The session the parked window carries, so flying home lands on the visit
    /// that left rather than on "whatever you were last in".
    private(set) var parkedApp: String?
    /// The session the visit is showing, learned through `sync`. Only read when
    /// the surface tears off; it is what `parkedApp` becomes.
    private(set) var visitApp: String?

    init() {}

    /// Apply one event. Returns the effects in the order they must happen.
    @discardableResult
    mutating func apply(_ event: Event) -> [Effect] {
        // Wing arbitration is orthogonal to everything else: an app may take or
        // release the collapsed wing while the visit is open, and the only
        // consequence is which state the surface falls back to. Handled first so
        // the table below never has to repeat it.
        switch event {
        case .wingGranted:
            wingHeld = true
            ground = .ambient
            if state == .resting { state = .ambient }
            return []
        case .wingReleased:
            wingHeld = false
            ground = .resting
            if state == .ambient { state = .resting }
            return []
        default:
            break
        }

        switch (state, event) {

        // MARK: Resting / Ambient

        case (.resting, .notificationArrived(let app, let priority)),
             (.ambient, .notificationArrived(let app, let priority)):
            ground = wingHeld ? .ambient : .resting
            state = .interruption
            swellApp = app
            swellClass = priority
            return [
                .showNotification(
                    app: app,
                    dwell: priority == .alert ? nil : LedgeInteraction.notificationDwell
                ),
            ]

        case (.resting, .hoverBegan), (.ambient, .hoverBegan):
            return [.promise]

        case (.resting, .pointerExit), (.ambient, .pointerExit):
            return [.unpromise]

        case (.resting, .hoverThreshold(let app, let declaresSummary)),
             (.ambient, .hoverThreshold(let app, let declaresSummary)):
            ground = wingHeld ? .ambient : .resting
            // "hover ≥ Th → Summary (Visit if the session declares none)".
            // Principle 8: a heavy visit owes a hover summary; a light one is
            // its own summary — so the light one just opens.
            guard declaresSummary, let app else {
                state = .visit
                showingOverview = false
                return [.unpromise, .openVisit(app: app)]
            }
            state = .summary
            swellApp = app
            return [.showSummary(app: app)]

        case (.resting, .click(.pill)), (.ambient, .click(.pill)),
             (.resting, .click(.wing)), (.ambient, .click(.wing)):
            ground = wingHeld ? .ambient : .resting
            state = .visit
            showingOverview = false
            return [.unpromise, .openVisit(app: nil)]

        // MARK: Summary

        case (.summary, .click):
            // "Summary | click anywhere | Visit" — anywhere means anywhere,
            // including the chevron the shell drew to promise exactly this.
            let app = swellApp
            swellApp = nil
            state = .visit
            return [.openVisit(app: app)]

        case (.summary, .pointerExit):
            // "Summary | pointer exit | whence it came".
            let app = swellApp
            swellApp = nil
            state = ground.state
            _ = app
            return [.retractSwell]

        case (.summary, .notificationArrived(let app, let priority)):
            // An interruption outranks a glance: the swell is already up, so
            // this is a swap of content rather than a new surface.
            state = .interruption
            swellApp = app
            swellClass = priority
            return [
                .showNotification(
                    app: app,
                    dwell: priority == .alert ? nil : LedgeInteraction.notificationDwell
                ),
            ]

        // MARK: Interruption

        case (.interruption, .click(.notificationAction)):
            swellApp = nil
            state = ground.state
            return [.runNotificationAction, .retractSwell]

        case (.interruption, .click):
            // "Interruption | click elsewhere | Visit (owning session)".
            let app = swellApp
            swellApp = nil
            state = .visit
            return [.openVisit(app: app)]

        case (.interruption, .notificationTimeout):
            // "timeout Ti (alert-class holds until acted)". The controller does
            // not arm a timer for an alert, and this second guard means a timer
            // armed before the class was known still cannot fire on one.
            guard swellClass != .alert else { return [] }
            swellApp = nil
            state = ground.state
            return [.retractSwell]

        case (.interruption, .notificationArrived(let app, let priority)):
            // "Alerts queue; never two notifications" — latest wins the surface.
            swellApp = app
            swellClass = priority
            return [
                .showNotification(
                    app: app,
                    dwell: priority == .alert ? nil : LedgeInteraction.notificationDwell
                ),
            ]

        case (.interruption, .pointerExit):
            // A notification is not a hover surface: leaving it changes nothing.
            // It arrived on its own schedule and leaves on its own schedule.
            return []

        // MARK: Visit

        case (.visit, .walkStrip(let steps)):
            showingOverview = false
            return [.walkStrip(steps: steps)]

        case (.visit, .escape) where showingOverview:
            // **Esc in the overview is Back.** The overview is a mode of the
            // visit (see `showingOverview`), and Esc leaves the mode it is in
            // before it leaves the surface — the same reading that makes Esc in
            // a sheet close the sheet rather than the document. One more Esc,
            // from the session it lands on, closes the visit.
            showingOverview = false
            return [.leaveOverview]

        case (.visit, .clickOutside), (.visit, .escape), (.visit, .exitTimeout):
            state = wingHeld ? .ambient : .resting
            ground = wingHeld ? .ambient : .resting
            showingOverview = false
            return [.closeVisit]

        case (.visit, .dragOffNotch):
            // "Visit | drag the panel down off the notch | Parked". The whole
            // surface goes — the mode it was in goes with it, overview included,
            // because what tears off is the body and not a page of it.
            state = .parked
            parkedApp = visitApp
            return [.park]

        // MARK: Parked

        case (.parked, .walkStrip(let steps)):
            // The *whole* surface tore off, so the strip still walks inside the
            // window — `‹|›` came with it. It does not fly home to do it: what
            // is parked is the surface, not one session of it.
            showingOverview = false
            return [.walkStrip(steps: steps)]

        case (.parked, .flyHome), (.parked, .click):
            // "Parked | ⌃, or click the bare notch | Visit (flies home)". The
            // window travels back into the notch; `app` is the session that was
            // in it, so the visit that lands is the visit that left.
            let app = parkedApp
            parkedApp = nil
            state = .visit
            return [.flyHome(app: app)]

        // MARK: Everything the table does not have a row for

        default:
            return []
        }
    }

    /// Force the machine's idea of the world to match a presentation the shell
    /// changed for a reason outside the table — an app's `ctx.expand`, the
    /// first-run permission card, a host disconnect. Without this the machine
    /// would believe the notch was resting while a panel was on screen, and the
    /// next Esc would do nothing.
    mutating func sync(to presentation: ShellPresentation) {
        // **Parked outranks the presentation.** While the surface is a window,
        // what it shows inside is still a visit — every commit, every walk and
        // every mode change re-presents one — and a machine that took those at
        // face value would believe the panel had flown home on the first tick
        // an app committed.
        guard state != .parked else {
            visitApp = presentation.app
            parkedApp = presentation.app
            showingOverview = presentation == .overview
            return
        }
        switch presentation {
        case .collapsed:
            state = wingHeld ? .ambient : .resting
            swellApp = nil
            showingOverview = false
        case .mini(let app):
            state = .interruption
            swellApp = app
            showingOverview = false
        case .summary(let app):
            state = .summary
            swellApp = app
            showingOverview = false
        case .expanded, .chat, .newApp, .permissions, .overview:
            state = .visit
            visitApp = presentation.app
            // The one mode the table cares about (see `showingOverview`).
            showingOverview = presentation == .overview
        }
    }
}

/// Why the walk-away timeout is not running.
///
/// flow.md: "Texit ≈ 2.5 s of pointer fully away, and the timer never runs while
/// the pill or the app holds the keyboard, during a drag, or while a tool is
/// running." Each of those is a moment where the user is demonstrably still in
/// the middle of something the pointer's position says nothing about — and a
/// panel that vanished mid-sentence would be the single worst bug this surface
/// could have.
///
/// A value type so the law can be asserted directly rather than inferred from a
/// panel that did or did not close.
struct ExitInhibitor: Equatable {
    /// The pointer is fully outside the shape (not merely off the content).
    var pointerAway = false
    /// A text input somewhere in the shell holds keyboard focus — the editor's
    /// composer, an `input` node in an app's tree, a focusable canvas.
    var keyboardHeld = false
    /// A drag is in flight (a file over the shelf, a `canvas` scrub).
    var dragging = false
    /// The editor surface is showing. This phase's approximation of "a tool is
    /// running": the transcript is where a turn happens, and a turn is the only
    /// tool the shell can currently see. Marked as an approximation because it
    /// is one — a real "tool running" signal arrives with the agent adapter.
    var editorShowing = false

    /// The only question anyone asks.
    var mayRunExitTimer: Bool {
        pointerAway && !keyboardHeld && !dragging && !editorShowing
    }
}
