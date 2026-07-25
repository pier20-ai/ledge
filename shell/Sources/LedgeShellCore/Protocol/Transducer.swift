import Foundation

/// A Swift-generated, local input to a native transducer (spec §3.5). Randomness
/// and time arrive as inputs so the transducer stays pure.
public enum TransducerInput: Sendable, Equatable {
    case tick(dt: Double, t: Double)
    case key(key: String, down: Bool)
    case seed(value: Int)

    /// Wire shape forwarded into the executor.
    public var json: JSONValue {
        switch self {
        case let .tick(dt, t):
            return .object(["type": .string("tick"), "dt": .double(dt), "t": .double(t)])
        case let .key(key, down):
            return .object(["type": .string("key"), "key": .string(key), "down": .bool(down)])
        case let .seed(value):
            return .object(["type": .string("seed"), "value": .int(value)])
        }
    }
}

/// One transducer output (spec §3.5): draw ops go straight to the canvas, events
/// are forwarded to the app's worker as ordinary messages.
public struct TransducerOutput: Sendable, Equatable {
    public struct Event: Sendable, Equatable {
        public var name: String
        public var data: JSONValue
        public init(name: String, data: JSONValue) {
            self.name = name
            self.data = data
        }
    }

    public var state: JSONValue
    public var draw: [JSONValue]
    public var events: [Event]

    public init(state: JSONValue, draw: [JSONValue] = [], events: [Event] = []) {
        self.state = state
        self.draw = draw
        self.events = events
    }
}

/// A pure transducer `(state, input) → (state', output)`. QuickJS slots in
/// behind this later; `ScriptedTransducer` is the stub used until then.
public protocol TransducerExecutor: AnyObject {
    /// Prepare the executor for a canvas. `code`/`hash`/`initial` mirror the
    /// `native` install message.
    func install(canvas: Int, hash: String, code: String, initial: JSONValue)

    /// Run one step. Implementations must be pure with respect to `state` and
    /// `input`; the executor holds no ambient time/RNG.
    func step(canvas: Int, state: JSONValue, input: TransducerInput) throws -> TransducerOutput

    /// Forget any per-canvas resources.
    func remove(canvas: Int)
}

/// A deterministic stand-in for the eventual QuickJS executor. Tests program its
/// behavior with a closure; without one it echoes state and emits no draw/events.
public final class ScriptedTransducer: TransducerExecutor {
    public typealias StepFn = (_ canvas: Int, _ state: JSONValue, _ input: TransducerInput) throws -> TransducerOutput

    private var installed: [Int: (hash: String, code: String)] = [:]
    private let stepFn: StepFn

    public init(step: @escaping StepFn = { _, state, _ in TransducerOutput(state: state) }) {
        self.stepFn = step
    }

    public func install(canvas: Int, hash: String, code: String, initial: JSONValue) {
        installed[canvas] = (hash, code)
    }

    public func step(canvas: Int, state: JSONValue, input: TransducerInput) throws -> TransducerOutput {
        try stepFn(canvas, state, input)
    }

    public func remove(canvas: Int) {
        installed[canvas] = nil
    }
}

/// Manages the shell-side half of native transducers: current state per canvas,
/// input routing, output fan-out, and the over-budget watchdog. It is agnostic
/// to the executor implementation and to AppKit; the engine wires draws/events
/// to the delegate and outbound socket.
public final class NativeHost {
    /// A tick exceeding this wall-clock budget is over budget (§3.5, ~5 ms).
    public static let tickBudget: TimeInterval = 0.005
    /// Consecutive over-budget ticks that suspend a transducer.
    public static let overBudgetLimit = 3

    public struct StepResult: Sendable, Equatable {
        public var draw: [JSONValue]
        public var events: [TransducerOutput.Event]
        /// True once the watchdog has suspended this canvas' transducer.
        public var suspended: Bool
    }

    private let executor: TransducerExecutor
    private var state: [Int: JSONValue] = [:]
    private var overBudget: [Int: Int] = [:]
    private var suspended: Set<Int> = []
    /// A monotonic clock, injectable so the watchdog is testable without sleeping.
    private let now: () -> TimeInterval

    public init(
        executor: TransducerExecutor,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.executor = executor
        self.now = now
    }

    public func install(canvas: Int, hash: String, code: String, initial: JSONValue) {
        // Hot reload passes the old checkpointed state as `initial`.
        executor.install(canvas: canvas, hash: hash, code: code, initial: initial)
        state[canvas] = initial
        overBudget[canvas] = 0
        suspended.remove(canvas)
    }

    public func remove(canvas: Int) {
        executor.remove(canvas: canvas)
        state[canvas] = nil
        overBudget[canvas] = nil
        suspended.remove(canvas)
    }

    public func removeAll() {
        for canvas in state.keys { executor.remove(canvas: canvas) }
        state.removeAll()
        overBudget.removeAll()
        suspended.removeAll()
    }

    public func isInstalled(canvas: Int) -> Bool { state[canvas] != nil }
    public func isSuspended(canvas: Int) -> Bool { suspended.contains(canvas) }

    /// Current checkpointable state for a canvas (§3.5 checkpoint).
    public func checkpointState(canvas: Int) -> JSONValue? { state[canvas] }

    /// Route one input. Returns the draw ops and events to fan out, or nil if the
    /// canvas isn't installed or is already suspended.
    public func input(canvas: Int, _ input: TransducerInput) -> StepResult? {
        guard let current = state[canvas], !suspended.contains(canvas) else { return nil }
        let start = now()
        let output: TransducerOutput
        do {
            output = try executor.step(canvas: canvas, state: current, input: input)
        } catch {
            // A throwing transducer is an app crash; suspend it.
            suspended.insert(canvas)
            return StepResult(draw: [], events: [], suspended: true)
        }
        let elapsed = now() - start
        state[canvas] = output.state

        if elapsed > Self.tickBudget {
            let count = (overBudget[canvas] ?? 0) + 1
            overBudget[canvas] = count
            if count >= Self.overBudgetLimit {
                suspended.insert(canvas)
                return StepResult(draw: output.draw, events: output.events, suspended: true)
            }
        } else {
            overBudget[canvas] = 0
        }
        return StepResult(draw: output.draw, events: output.events, suspended: false)
    }
}
