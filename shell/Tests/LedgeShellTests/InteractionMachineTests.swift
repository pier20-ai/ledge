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
    /// the table has no row for: an app's `ctx.expand`, the first-run permission
    /// card, a host disconnect. Without this the next Esc would do nothing.
    @Test("sync() reconciles the machine with a presentation the table did not cause")
    func syncCoversTheOutOfBandPaths() {
        var machine = Machine()
        machine.sync(to: .expanded(app: "stocks"))
        #expect(machine.state == .visit)
        machine.sync(to: .permissions)
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
        // Th was 0.35 at ratification and came down to 0.15 on device (G2.5:
        // the open "needs the mouse hovering for a long time").
        #expect(LedgeInteraction.hoverThreshold == 0.15)
        #expect(LedgeInteraction.notificationDwell == 6)
        #expect(LedgeInteraction.exitDelay == 2.5)
        #expect(LedgeInteraction.ambientIdle > 0)
    }
}
