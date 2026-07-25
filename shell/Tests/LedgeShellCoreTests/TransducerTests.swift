import Foundation
import Testing
@testable import LedgeShellCore

@Suite("Native transducer host (spec §3.5)")
struct TransducerTests {
    @Test("State threads through steps and is checkpointable")
    func stateThreads() {
        let transducer = ScriptedTransducer { _, state, input in
            guard case .tick = input else { return TransducerOutput(state: state) }
            let count = state.asObject?["n"]?.asInt ?? 0
            return TransducerOutput(state: .object(["n": .int(count + 1)]))
        }
        let host = NativeHost(executor: transducer)
        host.install(canvas: 1, hash: "h", code: "c", initial: .object(["n": .int(0)]))
        _ = host.input(canvas: 1, .tick(dt: 16, t: 0))
        _ = host.input(canvas: 1, .tick(dt: 16, t: 16))
        #expect(host.checkpointState(canvas: 1)?.asObject?["n"]?.asInt == 2)
    }

    @Test("Three consecutive over-budget ticks suspend the transducer")
    func watchdogSuspends() {
        var clock: TimeInterval = 0
        // Each step advances the injected clock past the 5 ms budget.
        let transducer = ScriptedTransducer { _, state, _ in
            clock += NativeHost.tickBudget * 2
            return TransducerOutput(state: state)
        }
        let host = NativeHost(executor: transducer, now: { clock })
        host.install(canvas: 1, hash: "h", code: "c", initial: .null)

        for _ in 0..<(NativeHost.overBudgetLimit - 1) {
            let result = host.input(canvas: 1, .tick(dt: 16, t: 0))
            #expect(result?.suspended == false)
        }
        let final = host.input(canvas: 1, .tick(dt: 16, t: 0))
        #expect(final?.suspended == true)
        #expect(host.isSuspended(canvas: 1))
        // Further input is ignored once suspended.
        #expect(host.input(canvas: 1, .tick(dt: 16, t: 0)) == nil)
    }

    @Test("A single over-budget tick amid fast ticks does not suspend")
    func transientOverBudgetForgiven() {
        var elapsed = NativeHost.tickBudget / 2
        let transducer = ScriptedTransducer { _, state, _ in
            defer { elapsed = NativeHost.tickBudget / 2 }
            return TransducerOutput(state: state)
        }
        var clock: TimeInterval = 0
        let host = NativeHost(executor: transducer, now: { defer { clock += elapsed }; return clock })
        host.install(canvas: 1, hash: "h", code: "c", initial: .null)

        _ = host.input(canvas: 1, .tick(dt: 16, t: 0))    // fast
        elapsed = NativeHost.tickBudget * 3               // one slow tick
        _ = host.input(canvas: 1, .tick(dt: 16, t: 0))
        elapsed = NativeHost.tickBudget / 2               // fast again → counter resets
        _ = host.input(canvas: 1, .tick(dt: 16, t: 0))
        #expect(host.isSuspended(canvas: 1) == false)
    }

    @Test("A throwing transducer suspends (app crash)")
    func throwSuspends() {
        struct Boom: Error {}
        let transducer = ScriptedTransducer { _, _, _ in throw Boom() }
        let host = NativeHost(executor: transducer)
        host.install(canvas: 1, hash: "h", code: "c", initial: .null)
        let result = host.input(canvas: 1, .tick(dt: 16, t: 0))
        #expect(result?.suspended == true)
    }
}

@Suite("Draw coalescer & seq gate")
struct SmallUnitTests {
    @Test("Coalescer keeps only the latest ops per canvas")
    func coalescer() {
        var coalescer = DrawCoalescer()
        coalescer.submit(app: "play", canvas: 1, ops: [.string("a")])
        coalescer.submit(app: "play", canvas: 1, ops: [.string("b")])
        coalescer.submit(app: "play", canvas: 2, ops: [.string("c")])
        let drained = coalescer.drain().sorted { $0.canvas < $1.canvas }
        #expect(drained.count == 2)
        #expect(drained[0].ops == [.string("b")])
        #expect(drained[1].ops == [.string("c")])
        #expect(coalescer.isEmpty)
    }

    @Test("Two apps can own the same canvas id without colliding (§3.1 ids restart at 1)")
    func coalescerScopesByApp() {
        var coalescer = DrawCoalescer()
        coalescer.submit(app: "tetris", canvas: 12, ops: [.string("tetris")])
        coalescer.submit(app: "aviary", canvas: 12, ops: [.string("aviary")])
        let drained = coalescer.drain().sorted { $0.app < $1.app }
        #expect(drained.count == 2)
        #expect(drained[0].app == "aviary")
        #expect(drained[1].ops == [.string("tetris")])

        // Discarding one app's tree leaves the other's pending frame alone.
        coalescer.submit(app: "tetris", canvas: 12, ops: [.string("t2")])
        coalescer.submit(app: "aviary", canvas: 12, ops: [.string("a2")])
        coalescer.discard(app: "tetris")
        let rest = coalescer.drain()
        #expect(rest.count == 1)
        #expect(rest[0].app == "aviary")
    }

    @Test("Seq gate accepts strictly increasing seq per app")
    func seqGate() {
        var gate = SeqGate()
        // `accept` is mutating, so evaluate outside the #expect closure.
        let first = gate.accept(app: "a", seq: 1)
        let second = gate.accept(app: "a", seq: 2)
        let equal = gate.accept(app: "a", seq: 2)
        let lower = gate.accept(app: "a", seq: 1)
        let otherApp = gate.accept(app: "b", seq: 1)
        #expect(first)
        #expect(second)
        #expect(equal == false)                           // equal → stale
        #expect(lower == false)                           // lower → stale
        #expect(otherApp)                                 // independent app
    }
}
