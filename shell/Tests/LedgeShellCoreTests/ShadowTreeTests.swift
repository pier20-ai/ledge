import Foundation
import Testing
@testable import LedgeShellCore

@Suite("Shadow tree & commit validation (spec §3.1)")
struct ShadowTreeTests {
    private func mutations(_ name: String) throws -> [Mutation] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: Fixtures.data(name))
        return try envelope.decodePayload(CommitPayload.self).mutations
    }

    @Test("commit-mount then commit-update produce the expected tree")
    func mountThenUpdate() throws {
        let tree = ShadowTree()
        #expect(tree.isEmpty)

        try #require(tree.apply(mutations("commit-mount.json")).isSuccess)
        #expect(tree.root == 1)
        // Root stack has four children (ids 2..5) in insertion order.
        #expect(tree.node(1)?.children == [2, 3, 4, 5])
        #expect(tree.node(3)?.kind == .text)
        #expect(tree.node(5)?.kind == .button)

        try #require(tree.apply(mutations("commit-update.json")).isSuccess)
        // The update didn't change structure except removing the button (id 5).
        #expect(tree.node(5) == nil)
        #expect(tree.node(1)?.children == [2, 3, 4])
        #expect(tree.node(3)?.kind == .text)      // still present, props updated
    }

    @Test("Unknown-parent insert is rejected and leaves the tree untouched")
    func unknownParent() throws {
        let tree = try mountedTree()
        let before = snapshot(tree)
        let result = tree.apply(try mutations("invalid-commit-unknown-parent.json"))
        #expect(result.isFailure)
        if case .failure(let failure) = result {
            #expect(failure == .unknownParent(id: 999))
        }
        #expect(snapshot(tree) == before)          // unchanged
    }

    @Test("Duplicate create is rejected and leaves the tree untouched")
    func duplicateCreate() throws {
        let tree = try mountedTree()
        let before = snapshot(tree)
        let result = tree.apply(try mutations("invalid-commit-duplicate-create.json"))
        #expect(result.isFailure)
        if case .failure(let failure) = result {
            #expect(failure == .duplicateCreate(id: 3))
        }
        #expect(snapshot(tree) == before)
    }

    @Test("Bad props (text content not a string) is rejected, tree untouched")
    func badProps() throws {
        let tree = try mountedTree()
        let before = snapshot(tree)
        let result = tree.apply(try mutations("invalid-commit-bad-props.json"))
        #expect(result.isFailure)
        if case .failure(let failure) = result {
            #expect(failure == .badProps(id: 10, key: "content"))
        }
        #expect(snapshot(tree) == before)
    }

    @Test("Unknown kind fails validation")
    func unknownKind() {
        let tree = ShadowTree()
        let result = tree.apply([Mutation(op: .create, id: 1, kind: "widget", props: [:])])
        #expect(result.isFailure)
    }

    @Test("Insert under a non-attachable parent fails")
    func notAttachable() {
        let tree = ShadowTree()
        _ = tree.apply([
            Mutation(op: .create, id: 1, kind: "text", props: ["content": .string("a")]),
            Mutation(op: .create, id: 2, kind: "text", props: ["content": .string("b")]),
        ])
        let result = tree.apply([Mutation(op: .insert, id: 2, parent: 1)])
        #expect(result.isFailure)
        if case .failure(let failure) = result {
            #expect(failure == .notAttachable(id: 1))
        }
    }

    @Test("Partial failure late in the list rolls back the whole commit")
    func allOrNothing() throws {
        let tree = try mountedTree()
        let before = snapshot(tree)
        // First op is valid; second references a missing id — the whole list is
        // discarded.
        let result = tree.apply([
            Mutation(op: .create, id: 100, kind: "text", props: ["content": .string("ok")]),
            Mutation(op: .insert, id: 100, parent: 999),
        ])
        #expect(result.isFailure)
        #expect(tree.node(100) == nil)             // the valid create was rolled back
        #expect(snapshot(tree) == before)
    }

    // MARK: - divider (spec §5)

    @Test("divider is a known kind, takes no props, and accepts none it is given")
    func divider() {
        let tree = ShadowTree()
        let result = tree.apply([
            Mutation(op: .create, id: 1, kind: "stack", props: ["axis": .string("v")]),
            // A prop the kind has never heard of is forward-compatible, not an
            // error (§3.1) — the same contract every other kind has.
            Mutation(op: .create, id: 2, kind: "divider", props: ["inset": .double(12)]),
            Mutation(op: .insert, id: 2, parent: 1),
            Mutation(op: .setRoot, id: 1),
        ])
        #expect(result.isSuccess)
        #expect(tree.node(2)?.kind == .divider)
    }

    @Test("Nothing attaches under a divider — it is a rule, not a container")
    func dividerIsNotAttachable() {
        let tree = ShadowTree()
        _ = tree.apply([
            Mutation(op: .create, id: 1, kind: "divider", props: [:]),
            Mutation(op: .create, id: 2, kind: "text", props: ["content": .string("a")]),
        ])
        let result = tree.apply([Mutation(op: .insert, id: 2, parent: 1)])
        #expect(result.isFailure)
        if case .failure(let failure) = result {
            #expect(failure == .notAttachable(id: 1))
        }
    }

    @Test("A button takes a child — §5's `label` or child, validated as such")
    func buttonAcceptsAChild() {
        let tree = ShadowTree()
        let result = tree.apply([
            Mutation(op: .create, id: 1, kind: "button", props: ["onClick": .bool(true)]),
            Mutation(op: .create, id: 2, kind: "stack", props: ["axis": .string("h")]),
            Mutation(op: .insert, id: 2, parent: 1),
            Mutation(op: .setRoot, id: 1),
        ])
        #expect(result.isSuccess)
        #expect(tree.node(1)?.children == [2])
    }

    // MARK: - Helpers

    private func mountedTree() throws -> ShadowTree {
        let tree = ShadowTree()
        _ = tree.apply(try mutations("commit-mount.json"))
        return tree
    }

    private func snapshot(_ tree: ShadowTree) -> [Int: ShadowTree.Node] {
        var map: [Int: ShadowTree.Node] = [:]
        for id in [1, 2, 3, 4, 5] {
            if let node = tree.node(id) { map[id] = node }
        }
        return map
    }
}

// Shared with EnvelopeFixtureTests, which replays the same corpus.
extension Result {
    var isSuccess: Bool { if case .success = self { return true }; return false }
    var isFailure: Bool { !isSuccess }
}
