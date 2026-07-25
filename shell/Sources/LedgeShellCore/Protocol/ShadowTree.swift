import Foundation

/// The component vocabulary (spec §5). An unknown kind fails validation — the
/// renderer has no NSView to map it to and the props can't be type-checked.
public enum ComponentKind: String, Sendable, CaseIterable {
    case stack
    case text
    case button
    case image
    case spacer
    case chart
    case slider
    case input
    case canvas
    // The six controls apps had been faking, ratified as §5 kinds (D8/Q5).
    case toggle
    case segment
    case stepper
    case progress
    case spinner
    case pill
    /// A **panel wing** — one of the two zones flanking the hardware cutout at
    /// the top of the expanded panel. Not the collapsed §3.3 wings (`ctx.wing`):
    /// those are the live-activity areas on the pill, this is chrome the app may
    /// fill while its panel is open. See protocol/README.md.
    case wing

    /// Whether children may be attached under this kind. Containers (`stack`),
    /// `button` (a single child), and `wing` (its zone content) are attachable;
    /// nothing else is.
    var isAttachable: Bool {
        switch self {
        case .stack, .button, .wing: true
        default: false
        }
    }
}

/// Expected type of a known prop, for per-kind type-checking (§3.1).
enum PropType {
    case string
    case number
    case bool
    case numberArray
    case numberOrBool
    /// `segment.options` — a list of `{ id, label }`. Only the *shape* is checked
    /// here; a member missing `id` is the renderer's problem, not the wire's.
    case objectArray
    /// `wing.side` — the ONE enumerated prop the wire checks by value rather than
    /// by type. `"right"` is the shell's own zone (the app name, the Edit
    /// affordance), so an app asking for it is not a preference the shell can
    /// decline quietly: it is a tree that means something the protocol does not
    /// offer, and §3.1 says a commit that means nothing is discarded whole.
    case wingSide

    func accepts(_ value: JSONValue) -> Bool {
        // `null` deletes a key in a partial update — always allowed.
        if case .null = value { return true }
        switch self {
        case .string: return value.asString != nil
        case .number: return value.isNumber
        case .bool: return value.asBool != nil
        case .numberOrBool: return value.isNumber || value.asBool != nil
        case .numberArray:
            guard let array = value.asArray else { return false }
            return array.allSatisfy { $0.isNumber }
        case .objectArray:
            guard let array = value.asArray else { return false }
            return array.allSatisfy { $0.asObject != nil }
        case .wingSide:
            return value.asString == "left"
        }
    }
}

private func expectedType(for kind: ComponentKind, prop: String) -> PropType? {
    switch (kind, prop) {
    case (.stack, "axis"), (.stack, "align"), (.stack, "distribute"): return .string
    case (.stack, "gap"), (.stack, "pad"): return .number
    case (.stack, "flex"): return .numberOrBool
    case (.stack, "scroll"): return .bool
    // Semantic container styling (spec §5 proposal, see protocol/README.md):
    // tokens only — a raw color would put theming in the app instead of the
    // shell, which is exactly what the semantic `text.color` vocabulary avoids.
    case (.stack, "fill"), (.stack, "stroke"): return .string
    case (.stack, "radius"): return .number

    case (.text, "content"), (.text, "size"), (.text, "weight"), (.text, "color"): return .string
    case (.text, "mono"), (.text, "truncate"): return .bool
    // Multi-line is opt-in and counted (L7) — never a silent wrap.
    case (.text, "maxLines"): return .number

    case (.button, "label"), (.button, "variant"), (.button, "icon"): return .string
    // The size ramp (D8/Q4) and the disabled state (D6).
    case (.button, "size"): return .string
    case (.button, "onClick"), (.button, "disabled"): return .bool

    case (.image, "src"): return .string
    case (.image, "w"), (.image, "h"), (.image, "radius"): return .number

    case (.spacer, "min"): return .number

    case (.chart, "points"): return .numberArray
    case (.chart, "color"): return .string
    case (.chart, "fill"): return .bool

    // `min`/`max` were accepted and ignored until D6; `step` joins them, and the
    // value on the wire is now in min…max space rather than always 0…1.
    case (.slider, "value"), (.slider, "min"), (.slider, "max"), (.slider, "step"): return .number
    // `rate` — value units per second of shell-side self-advance. A monitor that
    // polls every three seconds does not have to pretend it polls every frame.
    case (.slider, "rate"): return .number
    case (.slider, "onChange"): return .bool

    case (.input, "value"), (.input, "placeholder"): return .string
    case (.input, "onChange"), (.input, "onSubmit"): return .bool

    case (.canvas, "w"), (.canvas, "h"): return .number
    case (.canvas, "focusable"), (.canvas, "onKey"): return .bool

    // MARK: - New kinds (D6)

    case (.toggle, "on"), (.toggle, "disabled"), (.toggle, "onChange"): return .bool

    case (.segment, "options"): return .objectArray
    case (.segment, "value"): return .string
    case (.segment, "onChange"): return .bool

    case (.stepper, "value"), (.stepper, "min"), (.stepper, "max"), (.stepper, "step"):
        return .number
    // A display string the app computed, not a format specifier — the shell does
    // not know that 450 means 07:30.
    case (.stepper, "format"): return .string
    case (.stepper, "onChange"): return .bool

    case (.progress, "value"), (.progress, "rate"): return .number

    case (.pill, "label"), (.pill, "tone"): return .string

    // Panel wings: `side` is checked by *value*, not merely by type.
    case (.wing, "side"): return .wingSide

    // Unknown prop for this kind: forward-compatible, not an error.
    default: return nil
    }
}

/// Validate a prop set against a kind. Only *known* props are type-checked;
/// unknown keys pass so the vocabulary can grow without a version bump. Returns
/// the offending key on failure.
func validateProps(kind: ComponentKind, props: [String: JSONValue]?) -> String? {
    guard let props else { return nil }
    for (key, value) in props {
        if let type = expectedType(for: kind, prop: key), !type.accepts(value) {
            return key
        }
    }
    return nil
}

/// A lightweight `id → (kind, parent, children)` map mirroring the real view
/// tree (spec §3.1). The whole mutation list is validated and applied to a
/// working copy first; only if it fully validates does the caller touch NSViews.
/// On any failure the tree is left untouched and the commit is discarded.
public final class ShadowTree {
    public struct Node: Equatable, Sendable {
        public var kind: ComponentKind
        public var parent: Int?
        public var children: [Int]
    }

    public enum Failure: Error, Equatable {
        case unknownKind(id: Int, kind: String)
        case duplicateCreate(id: Int)
        case unknownId(id: Int)
        case unknownParent(id: Int)
        case notAttachable(id: Int)
        case badProps(id: Int, key: String)
        case badBefore(id: Int)
        case missingField(op: String)
        /// A `wing` that is not a direct child of the root. The zone it fills is
        /// panel chrome, not a box inside the app's layout — a wing nested in a
        /// card would render somewhere its parent cannot see, which is a worse
        /// answer than refusing the commit.
        case misplacedWing(id: Int)
    }

    private(set) var nodes: [Int: Node] = [:]
    private(set) var root: Int?

    public init() {}

    public var isEmpty: Bool { nodes.isEmpty && root == nil }

    public func node(_ id: Int) -> Node? { nodes[id] }

    /// Validate `mutations` in array order against a working copy, then commit
    /// the copy on full success. On any failure nothing changes and the failure
    /// is returned so the caller can send `resyncRequest`.
    @discardableResult
    public func apply(_ mutations: [Mutation]) -> Result<Void, Failure> {
        var workNodes = nodes
        var workRoot = root

        for mutation in mutations {
            switch mutation.op {
            case .create:
                guard let id = mutation.id else {
                    return .failure(.missingField(op: "create"))
                }
                guard workNodes[id] == nil else {
                    return .failure(.duplicateCreate(id: id))
                }
                guard let rawKind = mutation.kind, let kind = ComponentKind(rawValue: rawKind) else {
                    return .failure(.unknownKind(id: id, kind: mutation.kind ?? ""))
                }
                if let badKey = validateProps(kind: kind, props: mutation.props) {
                    return .failure(.badProps(id: id, key: badKey))
                }
                workNodes[id] = Node(kind: kind, parent: nil, children: [])

            case .insert:
                guard let parent = mutation.parent, let id = mutation.id else {
                    return .failure(.missingField(op: "insert"))
                }
                guard workNodes[id] != nil else {
                    return .failure(.unknownId(id: id))
                }
                guard let parentNode = workNodes[parent] else {
                    return .failure(.unknownParent(id: parent))
                }
                guard parentNode.kind.isAttachable else {
                    return .failure(.notAttachable(id: parent))
                }
                if let before = mutation.before {
                    guard let beforeNode = workNodes[before], beforeNode.parent == parent else {
                        return .failure(.badBefore(id: before))
                    }
                }
                // Detach from any current parent (a move is legal).
                if let oldParent = workNodes[id]?.parent {
                    workNodes[oldParent]?.children.removeAll { $0 == id }
                }
                workNodes[id]?.parent = parent
                if let before = mutation.before,
                   let index = workNodes[parent]?.children.firstIndex(of: before) {
                    workNodes[parent]?.children.insert(id, at: index)
                } else {
                    workNodes[parent]?.children.append(id)
                }

            case .update:
                guard let id = mutation.id else {
                    return .failure(.missingField(op: "update"))
                }
                guard let existing = workNodes[id] else {
                    return .failure(.unknownId(id: id))
                }
                if let badKey = validateProps(kind: existing.kind, props: mutation.props) {
                    return .failure(.badProps(id: id, key: badKey))
                }

            case .remove:
                guard let id = mutation.id else {
                    return .failure(.missingField(op: "remove"))
                }
                guard workNodes[id] != nil else {
                    return .failure(.unknownId(id: id))
                }
                removeSubtree(id, in: &workNodes, root: &workRoot)

            case .setRoot:
                guard let id = mutation.id else {
                    return .failure(.missingField(op: "setRoot"))
                }
                guard workNodes[id] != nil else {
                    return .failure(.unknownId(id: id))
                }
                workRoot = id
            }
        }

        // Placement is checked once, at the end, rather than per-insert: a batch
        // may legally insert a wing under a node that only *becomes* the root a
        // few mutations later (`setRoot` is conventionally last, see
        // commit-mount.json), so mid-batch the tree is allowed to be wrong.
        for (id, node) in workNodes where node.kind == .wing {
            guard let parent = node.parent, parent == workRoot else {
                return .failure(.misplacedWing(id: id))
            }
        }

        nodes = workNodes
        root = workRoot
        return .success(())
    }

    private func removeSubtree(_ id: Int, in nodes: inout [Int: Node], root: inout Int?) {
        if let parent = nodes[id]?.parent {
            nodes[parent]?.children.removeAll { $0 == id }
        }
        var stack = [id]
        while let current = stack.popLast() {
            if let node = nodes[current] {
                stack.append(contentsOf: node.children)
            }
            nodes[current] = nil
            if root == current { root = nil }
        }
    }
}
