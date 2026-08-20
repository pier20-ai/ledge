import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **flow.md's Transitions table, row by row.**
///
/// The table is the contract for this whole phase, and it is small enough to
/// walk exhaustively — so this suite does, once per row, in the table's own
/// order, with the row quoted above each assertion. `walksTheWholeTable` then
/// asserts that *every* row is covered, so a row added to flow.md and not to the
/// machine fails here rather than being noticed on device.
///
/// | from | on | to |
/// |---|---|---|
/// | Resting | wing granted | Ambient |
/// | Resting / Ambient | notification arrives | Interruption |
/// | Resting / Ambient | hover < Th | a small promissory swell, nothing more |
/// | Resting / Ambient | hover ≥ Th | Summary (Visit if the session declares none) |
/// | Resting / Ambient | click | Visit |
/// | Ambient | holder idle > Ta, or released | Resting |
/// | Summary | click anywhere | Visit |
/// | Summary | pointer exit | whence it came |
/// | Interruption | click the action | the action runs |
/// | Interruption | click elsewhere | Visit (owning session) |
/// | Interruption | timeout Ti (alert-class holds until acted) | whence it came |
/// | Visit | `‹\|›` or horizontal swipe | walks the strip |
/// | Visit | drag the panel down off the notch | Parked |
/// | Visit | click outside, or Esc | Resting |
/// | Visit | pointer away > Texit | Resting |
/// | Parked | ⌃, or click the bare notch | Visit (flies home) |
///
/// ⌃⌥Space is prose in flow.md rather than a row, because it cuts across every
/// row above: "opens the visit from anywhere, prefers the recording session,
/// pressed again it closes, and parked it flies home". Its cases are walked
/// under `MARK: - | anywhere | ⌃⌥Space |` below.
@Suite("The interaction machine — flow.md's Transitions table")
struct InteractionMachineTests {
    private typealias Machine = InteractionMachine

    /// A machine already in a given state, reached the way the table says to
    /// reach it. Nothing here pokes `state` directly: a fixture that cheated its
    /// way into a state could pass while the real path was broken.
    private func resting() -> Machine { Machine() }

    private func ambient() -> Machine {
        var machine = Machine()
        machine.apply(.wingGranted)
        return machine
    }

    private func summary(app: String = "chess", from base: Machine? = nil) -> Machine {
        var machine = base ?? Machine()
        machine.apply(.hoverThreshold(app: app, declaresSummary: true))
        return machine
    }

    private func interruption(
        app: String = "alarm",
        priority: NotificationClass = .ambient,
        from base: Machine? = nil
    ) -> Machine {
        var machine = base ?? Machine()
        machine.apply(.notificationArrived(app: app, priority: priority))
        return machine
    }

    private func visit() -> Machine {
        var machine = Machine()
        machine.apply(.click(.pill))
        return machine
    }

    // MARK: - | Resting | wing granted | Ambient |

    @Test("Resting + wing granted → Ambient")
    func wingGranted() {
        var machine = resting()
        #expect(machine.state == .resting)
        #expect(machine.apply(.wingGranted).isEmpty)
        #expect(machine.state == .ambient)
    }

    // MARK: - | Ambient | holder idle > Ta, or released | Resting |

    @Test("Ambient + released (or idle past Ta) → Resting")
    func wingReleased() {
        var machine = ambient()
        #expect(machine.apply(.wingReleased).isEmpty)
        #expect(machine.state == .resting)
    }

    /// Wing arbitration is orthogonal to the rest of the table: an app may take
    /// or release the collapsed wing while the visit is open, and the only
    /// consequence is which state closing the panel falls back to.
    @Test("A wing granted during a visit changes only where the visit falls back to")
    func wingIsOrthogonalToTheVisit() {
        var machine = visit()
        machine.apply(.wingGranted)
        #expect(machine.state == .visit, "a wing must not close the panel")
        machine.apply(.escape)
        #expect(machine.state == .ambient, "…but the notch it goes back to is wearing one")
    }

    // MARK: - | Resting / Ambient | notification arrives | Interruption |

    @Test("Resting or Ambient + notification → Interruption, with Ti for ambient class")
    func notificationArrives() {
        for var machine in [resting(), ambient()] {
            let effects = machine.apply(.notificationArrived(app: "alarm", priority: .ambient))
            #expect(machine.state == .interruption)
            #expect(effects == [
                .showNotification(app: "alarm", dwell: LedgeInteraction.notificationDwell),
            ])
        }
    }

    /// "alert-class holds until acted". A nil dwell is the implementation of
    /// that sentence: the controller has no timer to arm.
    @Test("An alert-class notification is raised with no dwell at all")
    func alertHasNoDwell() {
        var machine = resting()
        let effects = machine.apply(.notificationArrived(app: "alarm", priority: .alert))
        #expect(effects == [.showNotification(app: "alarm", dwell: nil)])
    }

    // MARK: - | Resting / Ambient | hover < Th | a small promissory swell |

    @Test("Hover below Th promises and does nothing else")
    func hoverBelowThreshold() {
        for var machine in [resting(), ambient()] {
            let before = machine.state
            #expect(machine.apply(.hoverBegan) == [.promise])
            #expect(machine.state == before, "a promise is not a state change")
            #expect(machine.apply(.pointerExit) == [.unpromise])
            #expect(machine.state == before)
        }
    }

    // MARK: - | Resting / Ambient | hover ≥ Th | Summary (Visit if none) |

    @Test("Hover past Th shows the summary of a heavy session")
    func hoverReachesThresholdWithSummary() {
        for var machine in [resting(), ambient()] {
            let effects = machine.apply(.hoverThreshold(app: "chess", declaresSummary: true))
            #expect(machine.state == .summary)
            #expect(effects == [.showSummary(app: "chess")])
        }
    }

    /// Principle 8: "a heavy visit owes a hover summary; a light one is its own
    /// summary". A session that declares none opens straight into the visit —
    /// and takes the promise back on the way, because the swell it promised is
    /// not the surface that arrived.
    @Test("Hover past Th on a light session opens the visit instead")
    func hoverReachesThresholdWithoutSummary() {
        var machine = resting()
        let effects = machine.apply(.hoverThreshold(app: "focus", declaresSummary: false))
        #expect(machine.state == .visit)
        #expect(effects == [.unpromise, .openVisit(app: "focus")])
    }

    @Test("Hover past Th with no session at all still opens the visit")
    func hoverWithNoSession() {
        var machine = resting()
        let effects = machine.apply(.hoverThreshold(app: nil, declaresSummary: true))
        #expect(machine.state == .visit)
        #expect(effects == [.unpromise, .openVisit(app: nil)])
    }

    // MARK: - | Resting / Ambient | click | Visit |

    @Test("A click on the pill or on a wing opens the visit")
    func clickOpensTheVisit() {
        for target in [Machine.Click.pill, .wing] {
            for var machine in [resting(), ambient()] {
                let effects = machine.apply(.click(target))
                #expect(machine.state == .visit)
                #expect(effects == [.unpromise, .openVisit(app: nil)])
            }
        }
    }

    // MARK: - | Summary | click anywhere | Visit |

    @Test("A click anywhere on the summary opens the visit of that session")
    func summaryClickOpensTheVisit() {
        // "anywhere" includes the chevron the shell drew to promise exactly
        // this, so every click target has to land in the same place.
        for target in [Machine.Click.summary, .pill, .wing, .notificationElsewhere] {
            var machine = summary(app: "chess")
            let effects = machine.apply(.click(target))
            #expect(machine.state == .visit)
            #expect(effects == [.openVisit(app: "chess")])
        }
    }

    // MARK: - | Summary | pointer exit | whence it came |

    @Test("The summary retracts to whence it came on pointer exit")
    func summaryRetractsToWhenceItCame() {
        var fromResting = summary()
        #expect(fromResting.apply(.pointerExit) == [.retractSwell])
        #expect(fromResting.state == .resting)

        var fromAmbient = summary(from: ambient())
        #expect(fromAmbient.apply(.pointerExit) == [.retractSwell])
        #expect(fromAmbient.state == .ambient, "a wing was up before the hover, and still is")
    }

    // MARK: - | Interruption | click the action | the action runs |

    @Test("Clicking the notification's action runs it and retracts the swell")
    func notificationActionRuns() {
        var machine = interruption()
        let effects = machine.apply(.click(.notificationAction))
        #expect(effects == [.runNotificationAction, .retractSwell])
        // It does NOT open the visit: the user asked for the action, not for
        // the app. That distinction is the only reason the table has two rows.
        #expect(machine.state == .resting)
    }

    // MARK: - | Interruption | click elsewhere | Visit (owning session) |

    @Test("Clicking a notification anywhere else visits the owning session")
    func notificationElsewhereOpensTheOwner() {
        var machine = interruption(app: "alarm")
        let effects = machine.apply(.click(.notificationElsewhere))
        #expect(machine.state == .visit)
        #expect(effects == [.openVisit(app: "alarm")], "the owner, not whatever you were last in")
    }

    // MARK: - | Interruption | timeout Ti (alert-class holds) | whence it came |

    @Test("An ambient notification times out to whence it came")
    func ambientTimesOut() {
        var fromAmbient = interruption(from: ambient())
        #expect(fromAmbient.apply(.notificationTimeout) == [.retractSwell])
        #expect(fromAmbient.state == .ambient)
    }

    /// The second lock. The controller never arms a timer for an alert, and a
    /// stray one — armed before the class was known, or left over from the
    /// notification this one replaced — still cannot fire on it.
    @Test("An alert-class notification ignores Ti entirely")
    func alertHoldsUntilActed() {
        var machine = interruption(priority: .alert)
        #expect(machine.apply(.notificationTimeout).isEmpty)
        #expect(machine.state == .interruption, "an alert holds until it is acted on")

        // …and acting on it is what puts it away.
        #expect(machine.apply(.click(.notificationAction)) == [.runNotificationAction, .retractSwell])
        #expect(machine.state == .resting)
    }

    /// "Alerts queue; never two notifications." One swell, latest content.
    @Test("A second notification replaces the first rather than stacking")
    func notificationsNeverStack() {
        var machine = interruption(app: "alarm")
        let effects = machine.apply(.notificationArrived(app: "music", priority: .alert))
        #expect(machine.state == .interruption)
        #expect(effects == [.showNotification(app: "music", dwell: nil)])
        // And now it is the *new* owner a click elsewhere visits.
        #expect(machine.apply(.click(.notificationElsewhere)) == [.openVisit(app: "music")])
    }

    /// A notification is not a hover surface. It arrived on its own schedule and
    /// leaves on its own schedule; the pointer wandering off is not an opinion.
    @Test("Leaving a notification does nothing at all")
    func notificationIgnoresPointerExit() {
        var machine = interruption()
        #expect(machine.apply(.pointerExit).isEmpty)
        #expect(machine.state == .interruption)
    }

    // MARK: - | Visit | ‹|› or horizontal swipe | walks the strip |

    @Test("The visit walks the strip, in either direction, without leaving the visit")
    func visitWalksTheStrip() {
        var machine = visit()
        #expect(machine.apply(.walkStrip(steps: 1)) == [.walkStrip(steps: 1)])
        #expect(machine.state == .visit)
        #expect(machine.apply(.walkStrip(steps: -1)) == [.walkStrip(steps: -1)])
        #expect(machine.state == .visit)
    }

    // MARK: - | Visit | click outside, or Esc | Resting |

    @Test("Click-outside and Esc both close the visit")
    func clickOutsideAndEscapeClose() {
        for event in [Machine.Event.clickOutside, .escape] {
            var machine = visit()
            #expect(machine.apply(event) == [.closeVisit])
            #expect(machine.state == .resting)
        }
    }

    // MARK: - | Visit | pointer away > Texit | Resting |

    @Test("The walk-away timeout closes the visit")
    func exitTimeoutCloses() {
        var machine = visit()
        #expect(machine.apply(.exitTimeout) == [.closeVisit])
        #expect(machine.state == .resting)
    }

    @Test("A visit over a live wing closes back to Ambient, not to Resting")
    func visitFallsBackToAmbient() {
        var machine = ambient()
        machine.apply(.click(.pill))
        #expect(machine.state == .visit)
        machine.apply(.clickOutside)
        #expect(machine.state == .ambient)
    }

    // MARK: - | Visit | drag the panel down off the notch | Parked |

    /// The row is live: the drag tears the whole surface off, and the machine
    /// says so before anything on screen moves. Where the window goes is the
    /// controller's (it is the only thing that knows where the pointer is);
    /// *that* it goes is here.
    @Test("Dragging the panel off the notch parks it")
    func draggingOffTheNotchParks() {
        var machine = visit()
        machine.sync(to: .expanded(app: "focus"))
        #expect(machine.apply(.dragOffNotch) == [.park])
        #expect(machine.state == .parked)
        #expect(machine.parkedApp == "focus", "the window carries the session that left")
    }

    /// **Texit does not run while parked** — nor does anything else passive. A
    /// window is deliberate: the user pulled it off and put it somewhere.
    @Test("Nothing passive takes the parked window away")
    func parkedIgnoresEverythingPassive() {
        var machine = visit()
        machine.apply(.dragOffNotch)
        for event in [Machine.Event.exitTimeout, .clickOutside, .escape, .pointerExit] {
            #expect(machine.apply(event).isEmpty, "\(event) must not disturb a parked window")
            #expect(machine.state == .parked)
        }
    }

    // MARK: - | Parked | ⌃, or click the bare notch | Visit (flies home) |

    @Test("The ⌃ and the bare notch both fly the surface home, to the session that left")
    func parkedFliesHome() {
        for event in [Machine.Event.flyHome, .click(.pill)] {
            var machine = visit()
            machine.sync(to: .chat(app: "chess"))
            machine.apply(.dragOffNotch)
            #expect(machine.state == .parked)
            #expect(machine.apply(event) == [.flyHome(app: "chess")])
            #expect(machine.state == .visit)
            // …and the visit it landed in closes the ordinary way.
            #expect(machine.apply(.escape) == [.closeVisit])
        }
    }

    /// A parked window still walks the strip, opens the ledge and switches
    /// modes: the *whole* surface tore off, so the session in it can change
    /// without the window flying home. The machine learns the new one through
    /// `sync`, which is how it knows which visit to land.
    @Test("Walking the strip inside the parked window changes which session flies home")
    func parkedWindowWalksTheStrip() {
        var machine = visit()
        machine.sync(to: .expanded(app: "chess"))
        machine.apply(.dragOffNotch)
        #expect(machine.apply(.walkStrip(steps: 1)) == [.walkStrip(steps: 1)])
        #expect(machine.state == .parked, "walking is not flying home")
        machine.sync(to: .expanded(app: "focus"))
        #expect(machine.state == .parked, "presenting inside the window does not unpark it")
        #expect(machine.apply(.flyHome) == [.flyHome(app: "focus")])
    }

    // MARK: - | anywhere | ⌃⌥Space | Visit (the recorder, if one is rolling) |

    /// **The keyboard's pill click** (G3, `HotkeyCenter`). The key exists for the
    /// hands-on-keyboard case — a recording running behind a full-screen app,
    /// with the pointer nowhere near the notch — so its rows are the click rows
    /// plus two facts a click cannot express: it carries a *preferred* session
    /// (the one holding the live recording), and pressing it twice puts the
    /// surface away again.
    ///
    /// `app` is a preference, not an order: nil means "whatever you were last
    /// in", exactly as a click on the pill does.
    @Test("⌃⌥Space from the bare notch opens the visit on the preferred session")
    func hotkeyFromResting() {
        var machine = resting()
        #expect(machine.apply(.hotkey(app: "scribe")) == [.unpromise, .openVisit(app: "scribe")])
        #expect(machine.state == .visit)

        // No preference is the pill click's own answer: the last session.
        var plain = resting()
        #expect(plain.apply(.hotkey(app: nil)) == [.unpromise, .openVisit(app: nil)])
        #expect(plain.state == .visit)
    }

    /// Ambient is the state the key is *for*: Scribe holds a wing while it
    /// records, so the notch is wearing one when the user reaches for the key.
    @Test("⌃⌥Space over a live wing opens the visit and remembers the wing")
    func hotkeyFromAmbient() {
        var machine = ambient()
        #expect(machine.apply(.hotkey(app: "scribe")) == [.unpromise, .openVisit(app: "scribe")])
        #expect(machine.state == .visit)
        #expect(machine.ground == .ambient, "the wing is still held; the visit rose from it")
    }

    /// A swell is up and the key goes through it, the way a click on it would —
    /// except that the key's preference outranks the swell's owner. A user
    /// reaching for the recorder mid-ring meant the recorder.
    @Test("⌃⌥Space through a summary or a notification lands on the key's session")
    func hotkeyThroughASwell() {
        var fromSummary = summary(app: "chess")
        #expect(fromSummary.apply(.hotkey(app: "scribe")) == [.openVisit(app: "scribe")])
        #expect(fromSummary.state == .visit)

        var fromNotification = interruption(app: "alarm")
        #expect(fromNotification.apply(.hotkey(app: "scribe")) == [.openVisit(app: "scribe")])
        #expect(fromNotification.state == .visit)

        // With no preference the swell's own session is what opens — the swell
        // is the only thing on screen, so it is "whatever you were last in".
        var noPreference = interruption(app: "alarm")
        #expect(noPreference.apply(.hotkey(app: nil)) == [.openVisit(app: "alarm")])
    }

    /// **The second press closes.** A key that only opens strands exactly the
    /// user it exists for: hands on the keyboard, no pointer to flick away with.
    @Test("A second ⌃⌥Space closes the visit it opened")
    func hotkeyTogglesClosed() {
        var machine = resting()
        machine.apply(.hotkey(app: "scribe"))
        machine.sync(to: .expanded(app: "scribe"))
        #expect(machine.apply(.hotkey(app: "scribe")) == [.closeVisit])
        #expect(machine.state == .resting)

        // …and with no preference at all, which is the ordinary case once the
        // recording has stopped.
        var plain = visit()
        #expect(plain.apply(.hotkey(app: nil)) == [.closeVisit])
        #expect(plain.state == .resting)
    }

    /// The one row that is not a toggle: a preference for a session the visit is
    /// **not** showing is a jump. ⌃⌥Space during a recording lands on the
    /// recorder from anywhere, including from a visit of something else.
    @Test("⌃⌥Space in a visit of another session re-opens on the recorder instead of closing")
    func hotkeyJumpsRatherThanClosing() {
        var machine = visit()
        machine.sync(to: .expanded(app: "chess"))
        #expect(machine.apply(.hotkey(app: "scribe")) == [.openVisit(app: "scribe")])
        #expect(machine.state == .visit, "a jump is not a close")

        // Landing there, the next press is a toggle again — the visit is now
        // showing the session the key prefers.
        machine.sync(to: .expanded(app: "scribe"))
        #expect(machine.apply(.hotkey(app: "scribe")) == [.closeVisit])
        #expect(machine.state == .resting)
    }

    /// Closing by key falls back exactly where closing by Esc does. The wing is
    /// the case that matters: Scribe holds one for the whole recording, so the
    /// notch the key puts away is still wearing it.
    @Test("Closing with the key goes back to Ambient over a held wing, not to Resting")
    func hotkeyClosePreservesTheWing() {
        var machine = visit()
        machine.apply(.wingGranted)
        machine.sync(to: .expanded(app: "scribe"))
        #expect(machine.apply(.hotkey(app: "scribe")) == [.closeVisit])
        #expect(machine.state == .ambient)
        #expect(machine.ground == .ambient)
        // The overview goes with it, like any other close.
        #expect(!machine.showingOverview)
    }

    /// Parked, the strongest reading of the key is "put Ledge in front of me" —
    /// and the window may be on another desktop entirely, where opening a second
    /// surface in the notch would be two Ledges at once.
    @Test("⌃⌥Space with the surface parked flies it home rather than opening a second one")
    func hotkeyFromParked() {
        var machine = visit()
        machine.sync(to: .expanded(app: "scribe"))
        machine.apply(.dragOffNotch)
        #expect(machine.state == .parked)
        #expect(machine.apply(.hotkey(app: "scribe")) == [.flyHome(app: "scribe")])
        #expect(machine.state == .visit)
        #expect(machine.parkedApp == nil, "the window is gone, not merely behind")

        // A preference for something else does not make it a jump: what is
        // parked is the surface, and it comes home whole.
        var other = visit()
        other.sync(to: .expanded(app: "chess"))
        other.apply(.dragOffNotch)
        #expect(other.apply(.hotkey(app: "scribe")) == [.flyHome(app: "chess")])
    }

    // MARK: - The ledge (a mode of the visit, not a seventh state)

    /// flow.md has six states and the overview is not one of them: it is the
    /// visit, zoomed out. The one row that turns on it is Esc.
    @Test("Esc in the overview is Back; Esc again closes the visit")
    func escapeInTheOverviewIsBack() {
        var machine = visit()
        machine.sync(to: .overview)
        #expect(machine.state == .visit, "the ledge is a mode of the visit")
        #expect(machine.showingOverview)
        #expect(machine.apply(.escape) == [.leaveOverview])
        #expect(machine.state == .visit, "Back leaves the mode, not the surface")
        #expect(!machine.showingOverview)
        #expect(machine.apply(.escape) == [.closeVisit])
        #expect(machine.state == .resting)
    }

    /// Everything else about the overview is an ordinary visit: a click outside
    /// closes it like any other surface, and walking the strip leaves the mode.
    @Test("The overview closes and walks like the visit it is")
    func overviewIsOtherwiseAVisit() {
        var machine = visit()
        machine.sync(to: .overview)
        #expect(machine.apply(.clickOutside) == [.closeVisit])
        #expect(machine.state == .resting)

        machine = visit()
        machine.sync(to: .overview)
        #expect(machine.apply(.walkStrip(steps: 1)) == [.walkStrip(steps: 1)])
        #expect(!machine.showingOverview, "walking is leaving the shelf")
    }

    // MARK: - Coverage

    /// Every row of the table has a test above. This asserts the *other*
    /// direction: that the machine has no state the table does not name, and
    /// that all six are reachable by the events the table gives — one walk,
    /// through every state, ending where it started.
    @Test("The machine's states are exactly flow.md's six, and the walk reaches all of them")
    func walksTheWholeTable() {
        #expect(
            Set(Machine.State.allCases.map(\.rawValue))
                == ["resting", "ambient", "summary", "interruption", "visit", "parked"]
        )

        var reached: Set<Machine.State> = [.resting]
        var machine = Machine()
        machine.apply(.wingGranted);                                   reached.insert(machine.state)
        machine.apply(.hoverThreshold(app: "chess", declaresSummary: true))
        reached.insert(machine.state)
        machine.apply(.notificationArrived(app: "alarm", priority: .ambient))
        reached.insert(machine.state)
        machine.apply(.click(.notificationElsewhere));                 reached.insert(machine.state)
        // The last two rows of the table, which used to be the seam.
        machine.apply(.dragOffNotch);                                  reached.insert(machine.state)
        machine.apply(.flyHome);                                       reached.insert(machine.state)
        machine.apply(.escape);                                        reached.insert(machine.state)

        #expect(reached == Set(Machine.State.allCases))
    }

    /// The machine must agree with a presentation the shell changed for a reason
    /// the table has no row for: an app's `ctx.expand`, a host disconnect, the
    /// blank slot. Without this the next Esc would do nothing.
    ///
    /// (The first-run permission card used to be the headline example. It is a
    /// Settings *page* now (G4) — a window the machine never hears about — so
    /// the placeholder stands in for the same shape: expanded chrome with no
    /// app behind it, arrived at without a transition row.)
    @Test("sync() reconciles the machine with a presentation the table did not cause")
    func syncCoversTheOutOfBandPaths() {
        var machine = Machine()
        machine.sync(to: .expanded(app: "stocks"))
        #expect(machine.state == .visit)
        machine.sync(to: .expanded(app: nil))
        #expect(machine.state == .visit)
        machine.sync(to: .summary(app: "chess"))
        #expect(machine.state == .summary)
        machine.sync(to: .notification(app: "alarm"))
        #expect(machine.state == .interruption)
        machine.sync(to: .collapsed)
        #expect(machine.state == .resting)

        // …and a synced state still remembers the wing underneath it.
        machine.apply(.wingGranted)
        machine.sync(to: .expanded(app: "stocks"))
        machine.apply(.escape)
        #expect(machine.state == .ambient)
    }
}

/// **Texit never runs while something is in flight** (flow.md: "the timer never
/// runs while the pill or the app holds the keyboard, during a drag, or while a
/// tool is running").
///
/// A separate suite because it is a separate law, and the worst bug this phase
/// could ship: a panel that evaporates mid-sentence.
@Suite("The walk-away timer's inhibitors (flow.md, Texit)")
struct ExitInhibitorTests {
    @Test("It runs only when the pointer is away and nothing else is happening")
    func theOneCase() {
        #expect(ExitInhibitor(pointerAway: true).mayRunExitTimer)
    }

    @Test("A pointer still on the surface is not a walk-away at all")
    func pointerPresent() {
        #expect(!ExitInhibitor(pointerAway: false).mayRunExitTimer)
    }

    @Test("Each inhibitor alone is enough to stop it")
    func eachInhibitorAlone() {
        // The keyboard: the editor's composer, an `input` node, a focusable
        // canvas. All three are "the user is mid-sentence".
        #expect(!ExitInhibitor(pointerAway: true, keyboardHeld: true).mayRunExitTimer)
        // A drag: a file over the shelf, a canvas being scrubbed.
        #expect(!ExitInhibitor(pointerAway: true, dragging: true).mayRunExitTimer)
        // A tool running — approximated this phase by "the editor is showing",
        // because a turn is the only tool the shell can currently see.
        #expect(!ExitInhibitor(pointerAway: true, editorShowing: true).mayRunExitTimer)
    }

    @Test("Any combination of inhibitors still stops it")
    func combinations() {
        for keyboard in [false, true] {
            for dragging in [false, true] {
                for editor in [false, true] {
                    let inhibitor = ExitInhibitor(
                        pointerAway: true,
                        keyboardHeld: keyboard,
                        dragging: dragging,
                        editorShowing: editor
                    )
                    #expect(
                        inhibitor.mayRunExitTimer == (!keyboard && !dragging && !editor),
                        "keyboard \(keyboard) drag \(dragging) editor \(editor)"
                    )
                }
            }
        }
    }

    /// The knobs themselves, at flow.md's starting values. Pinned so a feel test
    /// that changes one has to change it here too — which is the point of naming
    /// them rather than scattering literals.
    @Test("The four knobs carry flow.md's starting values")
    func knobs() {
        // Th was 0.35 at ratification and came down on device (G2.5/G2.6: the
        // open "needs the mouse hovering for a long time"); Texit came down
        // with it — Manu is feel-tuning both live.
        #expect(LedgeInteraction.hoverThreshold == 0.1)
        #expect(LedgeInteraction.notificationDwell == 6)
        #expect(LedgeInteraction.exitDelay == 0.3)
        #expect(LedgeInteraction.ambientIdle > 0)
    }
}

/// **A visit opened by key has the pointer nowhere near it** (G4).
///
/// The first build of ⌃⌥Space read "pointer fully away" on the very next
/// refresh, so Texit closed the panel 0.3 s after the key opened it — on device
/// that reads as the notch opening and collapsing right back, which is worse
/// than the key not working. A keyboard-opened visit therefore waits for the
/// pointer to arrive *once* before its absence is allowed to mean anything;
/// until then Esc, a click outside, and the key again are its ways out, and all
/// three are deliberate.
///
/// A controller-level suite rather than a machine one, because the hold is not
/// a state — it is one more inhibitor on the walk-away timer, and the machine
/// never hears about it.
@MainActor
@Suite("The hotkey's hold on a visit nobody has reached yet (G4)")
struct HotkeyHoldTests {
    private func openedByKey() throws -> (NotchPanelController, HostSession) {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        controller.present(.collapsed, animated: false)

        controller.hotkeyPressed()
        #expect(controller.presentation.isExpanded, "the key did not open anything")
        return (controller, session)
    }

    /// Up with the visit, and — the part that matters — still up after the
    /// pointer's *absence* has been noticed. That notice is precisely what used
    /// to close the panel.
    @Test("The hold goes up with the visit and outlives the pointer being away")
    func theHoldSurvivesThePointerBeingAway() throws {
        let (controller, _) = try openedByKey()
        #expect(controller.isHoldingForHotkeyOpenForTesting)

        controller.surfaceForTesting.onPointerInside?(false)
        #expect(
            controller.isHoldingForHotkeyOpenForTesting,
            "a pointer that was never there leaving is not a walk-away"
        )
        #expect(controller.presentation.isExpanded)
    }

    /// The graduation: the hand arrives, and from then on this visit is an
    /// ordinary one. The hold is spent on the first crossing — not renewed, not
    /// re-armed by leaving again.
    @Test("The first pointer arrival hands the visit back to the ordinary rules")
    func pointerArrivalClearsTheHold() throws {
        let (controller, _) = try openedByKey()

        controller.surfaceForTesting.onPointerInside?(true)
        #expect(!controller.isHoldingForHotkeyOpenForTesting)

        // And leaving again does not give it back: from here the walk-away
        // timer is the visit's own business.
        controller.surfaceForTesting.onPointerInside?(false)
        #expect(!controller.isHoldingForHotkeyOpenForTesting)
    }

    /// The key's other row: pressed again it closes the visit. Nothing is being
    /// held open any more, and a hold left standing would inhibit the timer for
    /// the *next* visit — one opened by hover, which never asked for keyboard
    /// rules.
    @Test("A second press closes the visit and takes the hold with it")
    func pressingAgainClearsTheHold() throws {
        let (controller, _) = try openedByKey()

        controller.hotkeyPressed()
        #expect(!controller.presentation.isExpanded)
        #expect(!controller.isHoldingForHotkeyOpenForTesting)
    }

    /// A collapse from any other door ends it too — Esc here, but `refresh` is
    /// where the clearing lives, so every route out is covered by the same line.
    @Test("Esc out of a keyboard-opened visit ends the hold")
    func escapeClearsTheHold() throws {
        let (controller, _) = try openedByKey()

        controller.surfaceForTesting.onEscape?()
        #expect(!controller.presentation.isExpanded)
        #expect(!controller.isHoldingForHotkeyOpenForTesting)
    }
}
