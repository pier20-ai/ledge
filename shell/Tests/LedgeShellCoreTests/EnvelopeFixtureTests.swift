import Foundation
import Testing
@testable import LedgeShellCore

@Suite("Envelope fixtures (spec §2)")
struct EnvelopeFixtureTests {
    @Test("Every fixture decodes as an envelope")
    func allDecode() throws {
        for name in try Fixtures.jsonNames() {
            let data = try Fixtures.data(name)
            #expect(throws: Never.self, "\(name)") {
                _ = try JSONDecoder().decode(Envelope.self, from: data)
            }
        }
    }

    @Test("Valid fixtures decode to their declared types")
    func validTypes() throws {
        let hello = try decode("hello-host.json")
        #expect(hello.kind == .hello)
        #expect(try hello.decodePayload(HelloHostPayload.self).host == "0.4.0")

        let catalog = try decode("catalog.json")
        #expect(catalog.kind == .catalog)
        let apps = try catalog.decodePayload(CatalogPayload.self).apps
        #expect(apps.count == 4)
        // `panel` is optional per app (spec §5 extension): declared by one,
        // absent for the rest, and absent must stay absent (not a zero).
        #expect(apps.first(where: { $0.id == "chess" })?.panel == PanelSpec(width: 520, maxHeight: 560))
        #expect(apps.first(where: { $0.id == "stocks" })?.panel == nil)

        let mount = try decode("commit-mount.json")
        #expect(mount.kind == .commit)
        let mutations = try mount.decodePayload(CommitPayload.self).mutations
        #expect(mutations.count == 10)
        #expect(mutations.last?.op == .setRoot)

        let click = try decode("event-click.json")
        #expect(click.kind == .event)

        let lifecycle = try decode("lifecycle-expanded.json")
        #expect(lifecycle.kind == .lifecycle)

        let selection = try decode("selection-app.json")
        #expect(try selection.decodePayload([String: JSONValue].self)["app"]?.asString == "music")

        // A worker-driven draw frame (spec §3.4). Ops stay raw JSON, and an op
        // the shell has never heard of must decode fine — it is skipped at draw
        // time, not rejected at parse time.
        let draw = try decode("draw-frame.json")
        #expect(draw.kind == .draw)
        let frame = try draw.decodePayload(DrawPayload.self)
        #expect(frame.id == 12)
        #expect(frame.ops.count == 6)
        #expect(frame.ops.last?.asObject?["op"]?.asString == "orbit")
        // The `image` op (§3.4, added without a version bump): an absolute path
        // plus an optional source rect naming one spritesheet cell in image
        // pixels. Core only has to carry it — cropping and blitting are the
        // renderer's business.
        let image = try #require(frame.ops[4].asObject)
        #expect(image["op"]?.asString == "image")
        #expect(image["src"]?.asString?.hasPrefix("/") == true)
        #expect(image["sw"]?.asDouble == 16)
    }

    @Test("Chrome fixtures: expand, and the three wing shapes (§3.3)")
    func chromeFixtures() throws {
        let expand = try decode("chrome-expand.json")
        #expect(expand.kind == .chrome)
        #expect(try expand.decodePayload(ChromePayload.self) == ChromePayload(request: "expand"))

        let wing = try decode("chrome-wing.json").decodePayload(ChromePayload.self)
        #expect(wing.request == "wing")
        #expect(wing.wing?.text == "AAPL ▲ 1.2%")
        #expect(wing.wing?.canvas == WingCanvasSpec(id: 12, w: 64))
        #expect(wing.wing?.width == nil)

        // A bare width request: shape only, no content (the breathing pacer).
        let width = try decode("chrome-wing-width.json").decodePayload(ChromePayload.self)
        #expect(width.wing?.width == 286)
        #expect(width.wing?.text == nil)
        #expect(width.wing?.canvas == nil)

        // `wing: null` releases the notch.
        let clear = try decode("chrome-wing-clear.json").decodePayload(ChromePayload.self)
        #expect(clear.request == "wing")
        #expect(clear.wing == nil)
    }

    @Test("Capability fixtures: apple, notify and capture, both directions (§6)")
    func capabilityFixtures() throws {
        let script = try decode("apple-script.json")
        #expect(script.kind == .apple)
        let scriptPayload = try script.decodePayload(ApplePayload.self)
        #expect(scriptPayload.invocation == .script("return 1 + 2"))

        let shortcut = try decode("apple-shortcut.json").decodePayload(ApplePayload.self)
        #expect(shortcut.id == 4)
        #expect(shortcut.name == "Log Note")
        #expect(shortcut.input?.asObject?["note"]?.asString == "standup at 10")

        let ok = try decode("apple-result.json")
        #expect(ok.kind == .appleResult)
        let okPayload = try ok.decodePayload(AppleResultPayload.self)
        #expect(okPayload == AppleResultPayload.success(id: 3, value: .int(3)))

        let failed = try decode("apple-result-error.json").decodePayload(AppleResultPayload.self)
        #expect(failed.ok == false)
        #expect(failed.value == nil)
        #expect(failed.error == "shortcut \"Log Note\" not found")

        let notify = try decode("notify.json")
        #expect(notify.kind == .notify)
        let notifyPayload = try notify.decodePayload(NotifyPayload.self)
        #expect(notifyPayload.id == 7)
        #expect(notifyPayload.title == "Deal Watch")
        #expect(notifyPayload.actions == [
            NotifyActionSpec(id: "open", label: "Open listing"),
            NotifyActionSpec(id: "snooze", label: "Snooze a week"),
        ])

        let action = try decode("notify-action.json")
        #expect(action.kind == .notifyAction)
        #expect(try action.decodePayload(NotifyActionPayload.self) == NotifyActionPayload(id: 7, action: "open"))

        let capture = try decode("capture.json")
        #expect(capture.kind == .capture)
        #expect(try capture.decodePayload(CapturePayload.self).isInteractive == true)

        let captured = try decode("capture-result.json").decodePayload(CaptureResultPayload.self)
        #expect(captured.ok)
        #expect(captured.path == "/var/folders/T/ledge-capture-9F3A.png")

        // The drop shelf reuses §4.1's `event` at the app-level id 0 — no new
        // envelope type, because it is genuinely the same kind of message.
        let drop = try decode("event-drop.json")
        #expect(drop.kind == .event)
        let dropPayload = try drop.decodePayload([String: JSONValue].self)
        #expect(dropPayload["id"]?.asInt == 0)
        #expect(dropPayload["name"]?.asString == "drop")
        #expect(dropPayload["data"]?.asObject?["paths"]?.asArray?.first?.asString
            == "/Users/you/Downloads/boarding-pass.pdf")
    }

    @Test("Platform fixtures: observe, unobserve, the ack, and the id-0 event (§6 ext)")
    func platformFixtures() throws {
        let observe = try decode("platform-observe.json")
        #expect(observe.kind == .platform)
        let request = try observe.decodePayload(PlatformPayload.self)
        #expect(request == PlatformPayload(
            id: 5,
            call: "observe",
            kind: "distributedNotification",
            name: "com.apple.Music.playerInfo"
        ))
        #expect(request.isSupported)

        let unobserve = try decode("platform-unobserve.json").decodePayload(PlatformPayload.self)
        #expect(unobserve.call == "unobserve")
        #expect(unobserve.isSupported)

        let ok = try decode("platform-result.json")
        #expect(ok.kind == .platformResult)
        // A success carries no `error` key at all, not a null one — the same
        // rule `appleResult` follows, so fixtures can assert exact objects.
        #expect(try ok.decodePayload(PlatformResultPayload.self) == .success(id: 5))
        let failed = try decode("platform-result-error.json")
            .decodePayload(PlatformResultPayload.self)
        #expect(failed.ok == false)
        #expect(failed.error?.contains("carrierPigeon") == true)

        // The event is an ordinary §4.1 `event` at the app-level id 0 — the same
        // convention `drop` and `notification` use, so push invalidation costs
        // the protocol no new envelope type either.
        let event = try decode("event-platform.json")
        #expect(event.kind == .event)
        let payload = try event.decodePayload([String: JSONValue].self)
        #expect(payload["id"]?.asInt == 0)
        #expect(payload["name"]?.asString == "platform")
        let data = try #require(payload["data"]?.asObject)
        #expect(data["kind"]?.asString == "distributedNotification")
        let info = try #require(data["userInfo"]?.asObject)
        // Scalars only: strings, numbers and bools. Nothing else ever appears
        // here, because the shell drops it at the boundary.
        #expect(info["Player State"]?.asString == "Playing")
        #expect(info["Total Time"]?.asDouble == 140_000)
        #expect(info["Loved"]?.asBool == false)
        #expect(info.values.allSatisfy { value in
            value.asString != nil || value.isNumber || value.asBool != nil
        })
    }

    @Test("Observe fixtures cover every ratified kind, with translated names (§6 ext)")
    func observeKindFixtures() throws {
        let expected: [(file: String, kind: String, name: String)] = [
            ("platform-observe-workspace.json", "workspace", "didActivateApplication"),
            ("platform-observe-pasteboard.json", "pasteboard", "changed"),
            ("platform-observe-power.json", "power", "changed"),
            ("platform-observe-reachability.json", "reachability", "changed"),
            ("platform-observe-audio.json", "audio", "changed"),
        ]
        for entry in expected {
            let payload = try decode(entry.file).decodePayload(PlatformPayload.self)
            #expect(payload.invocation == .observe(kind: entry.kind, name: entry.name), "\(entry.file)")
            #expect(PlatformObserveKind.all.contains(entry.kind))
        }
        // Every kind on the wire is one the shell claims to support, and every
        // kind the shell supports has a fixture — otherwise a kind ships with no
        // golden example of what its envelope looks like.
        let covered = Set(expected.map(\.kind) + [PlatformObserveKind.distributedNotification])
        #expect(covered == PlatformObserveKind.all)
    }

    @Test("Event fixtures: one per observe kind, scalars only (§6 ext)")
    func platformEventFixtures() throws {
        let files = [
            "event-platform-workspace.json", "event-platform-pasteboard.json",
            "event-platform-power.json", "event-platform-reachability.json",
            "event-platform-audio.json",
        ]
        for file in files {
            let payload = try decode(file).decodePayload([String: JSONValue].self)
            #expect(payload["id"]?.asInt == 0, "\(file)")
            #expect(payload["name"]?.asString == "platform", "\(file)")
            let data = try #require(payload["data"]?.asObject, "\(file)")
            #expect(PlatformObserveKind.all.contains(try #require(data["kind"]?.asString)), "\(file)")
            let info = try #require(data["userInfo"]?.asObject, "\(file)")
            // The reduction rule binds every kind, not just distributedNotification:
            // a nested object or an array here would be a payload no app can rely
            // on and a frame nobody bounded.
            #expect(info.values.allSatisfy { value in
                value.asString != nil || value.isNumber || value.asBool != nil
                    || value.asArray?.allSatisfy { $0.asString != nil } == true
            }, "\(file)")
        }

        // The pasteboard event is the privacy line, made concrete: an
        // invalidation signal, never the contents.
        let clipboard = try decode("event-platform-pasteboard.json")
            .decodePayload([String: JSONValue].self)
        let info = try #require(clipboard["data"]?.asObject?["userInfo"]?.asObject)
        #expect(info["changeCount"]?.asInt == 4821)
        #expect(info["hasStrings"]?.asBool == true)
        #expect(info["types"]?.asArray?.first?.asString == "public.utf8-plain-text")
        #expect(info["contents"] == nil, "the pasteboard event must never carry what is on the pasteboard")

        let power = try decode("event-platform-power.json").decodePayload([String: JSONValue].self)
        let battery = try #require(power["data"]?.asObject?["userInfo"]?.asObject)
        #expect(battery["level"]?.asDouble == 0.62)
        #expect(battery["lowPowerMode"]?.asBool == true)
    }

    @Test("Call fixtures: every new call, its result, and its error (§6 ext)")
    func platformCallFixtures() throws {
        // calendar
        let calendar = try decode("platform-calendar.json").decodePayload(PlatformPayload.self)
        #expect(calendar.invocation == .calendar(from: "2026-07-25T09:00:00Z", to: "2026-07-26T09:00:00Z"))
        let events = try #require(
            try decode("platform-calendar-result.json")
                .decodePayload(PlatformResultPayload.self).data?.asArray
        )
        #expect(events.count == 2)
        #expect(events.first?.asObject?["title"]?.asString == "Standup")
        #expect(events.first?.asObject?["location"] == nil)
        #expect(events.last?.asObject?["location"]?.asString == "Studio")
        #expect(try decode("platform-calendar-error.json")
            .decodePayload(PlatformResultPayload.self).error?.contains("refused") == true)

        // workspace
        #expect(try decode("platform-workspace.json")
            .decodePayload(PlatformPayload.self).invocation == .workspace)
        let workspace = try #require(
            try decode("platform-workspace-result.json")
                .decodePayload(PlatformResultPayload.self).data?.asObject
        )
        #expect(workspace["frontmost"]?.asObject?["bundleId"]?.asString == "com.apple.dt.Xcode")
        #expect(workspace["idleSeconds"]?.asDouble == 4.5)
        #expect(try decode("platform-workspace-error.json")
            .decodePayload(PlatformResultPayload.self).ok == false)

        // location
        #expect(try decode("platform-location.json")
            .decodePayload(PlatformPayload.self).invocation == .location)
        let fix = try #require(
            try decode("platform-location-result.json")
                .decodePayload(PlatformResultPayload.self).data?.asObject
        )
        #expect(fix["lat"]?.asDouble == 37.7749)
        #expect(fix["accuracyMeters"]?.asDouble == 1200)
        #expect(try decode("platform-location-error.json")
            .decodePayload(PlatformResultPayload.self).error?.contains("timed out") == true)

        // spotlight
        let spotlight = try decode("platform-spotlight.json").decodePayload(PlatformPayload.self)
        #expect(spotlight.invocation == .spotlight(
            query: "kMDItemContentType == \"com.adobe.pdf\"",
            scopes: ["/Users/you/Documents"]
        ))
        let hits = try #require(
            try decode("platform-spotlight-result.json")
                .decodePayload(PlatformResultPayload.self).data?.asArray
        )
        #expect(hits.count == 2)
        #expect(hits.first?.asObject?["modified"]?.asString == "2026-07-20T11:02:00Z")
        #expect(hits.last?.asObject?["modified"] == nil)
        #expect(try decode("platform-spotlight-error.json")
            .decodePayload(PlatformResultPayload.self).error?.contains("predicate") == true)

        // audio + setVolume
        #expect(try decode("platform-audio.json").decodePayload(PlatformPayload.self).invocation == .audio)
        let audio = try #require(
            try decode("platform-audio-result.json")
                .decodePayload(PlatformResultPayload.self).data?.asObject
        )
        #expect(audio["transportType"]?.asString == "bluetooth")
        #expect(audio["batteryPercent"]?.asDouble == 78)
        #expect(try decode("platform-audio-error.json")
            .decodePayload(PlatformResultPayload.self).ok == false)

        // The request asks for 1.4 and the result reports 1: the clamp is
        // visible on the wire, which is the whole reason setVolume answers with
        // a value at all.
        #expect(try decode("platform-set-volume.json")
            .decodePayload(PlatformPayload.self).invocation == .setVolume(1.4))
        #expect(try decode("platform-set-volume-result.json")
            .decodePayload(PlatformResultPayload.self).data?.asObject?["volume"]?.asDouble == 1)
        #expect(try decode("platform-set-volume-error.json")
            .decodePayload(PlatformResultPayload.self).ok == false)

        // speak: a call with no answer carries NO data key, not a null one.
        #expect(try decode("platform-speak.json").decodePayload(PlatformPayload.self).invocation
            == .speak(text: "Standup in five minutes.", voice: nil, rate: 0.5))
        let spoke = try decode("platform-speak-result.json").decodePayload(PlatformResultPayload.self)
        #expect(spoke == .success(id: 27))
        #expect(spoke.data == nil)
        #expect(try decode("platform-speak-error.json")
            .decodePayload(PlatformResultPayload.self).error?.contains("500") == true)

        // quit: the verb is the whole request, and it is answered before the
        // process goes — which is why it has a result fixture at all.
        #expect(try decode("platform-quit.json")
            .decodePayload(PlatformPayload.self).invocation == .quit)
        let quit = try decode("platform-quit-result.json").decodePayload(PlatformResultPayload.self)
        #expect(quit == .success(id: 4))
        #expect(quit.data == nil)
        #expect(try decode("platform-quit-error.json")
            .decodePayload(PlatformResultPayload.self).ok == false)
    }

    @Test("A malformed call is refused by decoding, before any executor sees it")
    func malformedCallsAreRefused() {
        func payload(_ object: [String: JSONValue]) -> PlatformPayload? {
            let envelope = Envelope(app: "x", seq: 1, type: "platform", payload: .object(object))
            return try? envelope.decodePayload(PlatformPayload.self)
        }
        // A verb nobody implements.
        #expect(payload(["id": .int(1), "call": .string("teleport")])?.isSupported == false)
        // spotlight without a query, speak without text: the field the call is
        // *about*, so there is nothing to guess at.
        #expect(payload(["id": .int(1), "call": .string("spotlight")])?.isSupported == false)
        #expect(payload(["id": .int(1), "call": .string("speak"), "text": .string("")])?.isSupported == false)
        // A missing volume is a malformed request, not a 0 — silently muting the
        // machine is the worst possible reading of a typo.
        #expect(payload(["id": .int(1), "call": .string("setVolume")])?.isSupported == false)
        // observe still needs both axes.
        #expect(payload(["id": .int(1), "call": .string("observe"), "kind": .string("power")])?
            .isSupported == false)
        // …and the ones with no required fields at all are always supported.
        #expect(payload(["id": .int(1), "call": .string("workspace")])?.invocation == .workspace)
        #expect(payload(["id": .int(1), "call": .string("calendar")])?.invocation == .calendar(from: nil, to: nil))
    }

    @Test("Panel-wing fixtures mount, update, and reject the reserved side (§5)")
    func wingFixtures() throws {
        let mount = try decode("commit-wing.json")
        let mutations = try mount.decodePayload(CommitPayload.self).mutations
        let tree = ShadowTree()
        #expect(tree.apply(mutations).isSuccess)

        let wing = try #require(mutations.first { $0.kind == "wing" })
        #expect(wing.props?["side"]?.asString == "left")
        // A wing is attachable — the whole point is that it carries content.
        #expect(tree.node(2)?.kind == .wing)
        #expect(tree.node(2)?.children == [3, 4])
        // …and it is a direct child of the root, which is the placement rule.
        #expect(tree.node(2)?.parent == 1)

        // Updates on wing children are ordinary updates.
        let updates = try decode("commit-wing-update.json")
            .decodePayload(CommitPayload.self).mutations
        #expect(updates.allSatisfy { $0.op == .update })
        #expect(tree.apply(updates).isSuccess)

        // `side: "right"` is the shell's zone. This is the one §5 prop checked
        // by *value*: a wrong value here means a tree the protocol cannot
        // express, so the commit is discarded whole (§3.1).
        let rejected = ShadowTree()
        let bad = try decode("invalid-commit-right-wing.json")
            .decodePayload(CommitPayload.self).mutations
        expectFailure(rejected.apply(bad), .badProps(id: 2, key: "side"))
        #expect(rejected.isEmpty)

        let nested = ShadowTree()
        let misplaced = try decode("invalid-commit-nested-wing.json")
            .decodePayload(CommitPayload.self).mutations
        expectFailure(nested.apply(misplaced), .misplacedZone(id: 3, kind: .wing))
        #expect(nested.isEmpty)
    }

    @Test("Rate fixtures carry `rate` on slider and progress (§5)")
    func rateFixtures() throws {
        let mount = try decode("commit-rate.json")
        let mutations = try mount.decodePayload(CommitPayload.self).mutations
        let tree = ShadowTree()
        #expect(tree.apply(mutations).isSuccess)

        func props(_ id: Int) throws -> [String: JSONValue] {
            try #require(mutations.first { $0.op == .create && $0.id == id }?.props)
        }
        // A scrubber in seconds: `min`/`max` are the track, `rate` is one second
        // of value per second of clock.
        #expect(try props(2)["rate"]?.asDouble == 1)
        #expect(try props(2)["max"]?.asDouble == 224)
        #expect(try props(3)["rate"]?.asDouble ?? 0 > 0)
        // Absent is the static behavior — which is how every app that has never
        // heard of `rate` looks on the wire.
        #expect(try props(4)["rate"] == nil)

        let updates = try decode("commit-rate-update.json")
            .decodePayload(CommitPayload.self).mutations
        #expect(tree.apply(updates).isSuccess)
        // Pausing is `rate: 0`; deleting the key (§3.1 null) means the same.
        #expect(updates.first { $0.id == 2 }?.props?["rate"]?.asDouble == 0)
        #expect(updates.first { $0.id == 3 }?.props?["rate"] == JSONValue.null)
    }

    @Test("A wrongly-typed rate or wing side is rejected (§3.1)")
    func newPropsAreTypeChecked() {
        let tree = ShadowTree()
        expectFailure(
            tree.apply([Mutation(op: .create, id: 1, kind: "slider", props: ["rate": .string("fast")])]),
            .badProps(id: 1, key: "rate")
        )
        expectFailure(
            tree.apply([Mutation(op: .create, id: 2, kind: "progress", props: ["rate": .bool(true)])]),
            .badProps(id: 2, key: "rate")
        )
        // Not merely "a string": the ONE enumerated prop on the wire.
        expectFailure(
            tree.apply([Mutation(op: .create, id: 3, kind: "wing", props: ["side": .string("top")])]),
            .badProps(id: 3, key: "side")
        )
    }

    @Test("New-kind fixtures validate against the shadow tree (D6)")
    func newKindFixtures() throws {
        let mount = try decode("commit-new-kinds.json")
        let mutations = try mount.decodePayload(CommitPayload.self).mutations
        let kinds = mutations.compactMap(\.kind).compactMap(ComponentKind.init(rawValue:))
        #expect(Set(kinds) == [.stack, .toggle, .segment, .stepper, .progress, .spinner, .pill])

        // The whole batch has to *validate*, not merely decode: `options` is an
        // array of objects, `format` a string, `on`/`disabled` bools. A prop typed
        // wrong here would discard the commit at runtime and loop on resync.
        let tree = ShadowTree()
        #expect(tree.apply(mutations).isSuccess)

        // And every one of them takes an update in place.
        let update = try decode("commit-new-kinds-update.json")
        let updates = try update.decodePayload(CommitPayload.self).mutations
        #expect(updates.allSatisfy { $0.op == .update })
        #expect(Set(updates.compactMap(\.id)) == Set(2...10))
        #expect(tree.apply(updates).isSuccess)

        // `disabled: null` is the canonical "delete this prop" form (§3.1).
        let reenable = try #require(updates.first { $0.id == 3 })
        #expect(reenable.props?["disabled"] == JSONValue.null)
    }

    @Test("Control-prop fixtures carry the new props on the existing kinds")
    func controlPropFixtures() throws {
        let mount = try decode("commit-control-props.json")
        let mutations = try mount.decodePayload(CommitPayload.self).mutations
        let tree = ShadowTree()
        #expect(tree.apply(mutations).isSuccess)

        func props(_ id: Int) throws -> [String: JSONValue] {
            try #require(mutations.first { $0.op == .create && $0.id == id }?.props)
        }
        #expect(try props(2)["size"]?.asString == "s")
        #expect(try props(3)["size"] == nil)                       // absent ⇒ default m
        #expect(try props(4)["size"]?.asString == "l")
        // Empty *string*, not an absent key: an icon-only button is the empty-label
        // case the centering law is about (L2), so the difference is load-bearing.
        #expect(try props(5)["label"]?.asString == "")
        #expect(try props(6)["disabled"]?.asBool == true)
        #expect(try props(7)["min"]?.asDouble == 60)
        #expect(try props(7)["max"]?.asDouble == 200)
        #expect(try props(7)["step"]?.asDouble == 5)
        #expect(try props(8)["maxLines"]?.asInt == 3)
        #expect(try props(9)["truncate"]?.asBool == false)

        let updates = try decode("commit-control-props-update.json")
            .decodePayload(CommitPayload.self).mutations
        #expect(updates.allSatisfy { $0.op == .update })
        #expect(tree.apply(updates).isSuccess)
    }

    @Test("A wrongly-typed new-kind prop is still rejected (§3.1)")
    func newKindPropsAreTypeChecked() {
        let tree = ShadowTree()
        // `options` must be a list of objects; a list of strings is not "close".
        expectFailure(
            tree.apply([
                Mutation(op: .create, id: 1, kind: "segment", props: ["options": .array([.string("1D")])]),
            ]),
            .badProps(id: 1, key: "options")
        )
        expectFailure(
            tree.apply([Mutation(op: .create, id: 2, kind: "toggle", props: ["on": .string("yes")])]),
            .badProps(id: 2, key: "on")
        )
        expectFailure(
            tree.apply([Mutation(op: .create, id: 3, kind: "button", props: ["size": .int(34)])]),
            .badProps(id: 3, key: "size")
        )

        // A new kind is not attachable: a pill with children is a layout mistake
        // the wire should catch, not something the renderer silently absorbs.
        expectFailure(
            tree.apply([
                Mutation(op: .create, id: 4, kind: "pill", props: ["label": .string("LIVE")]),
                Mutation(op: .create, id: 5, kind: "text", props: ["content": .string("x")]),
                Mutation(op: .insert, id: 5, parent: 4),
            ]),
            .notAttachable(id: 4)
        )
    }

    @Test("Invalid commit fixtures carry the _expect: resyncRequest hint")
    func invalidFixturesHint() throws {
        for name in try Fixtures.jsonNames() where name.hasPrefix("invalid-") {
            let object = try rawObject(name)
            #expect(object["_expect"]?.asString == "resyncRequest", "\(name)")
        }
    }

    @Test("Builder stream: one envelope per line")
    func builderStream() throws {
        let data = try Fixtures.data("builder-stream.jsonl")
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(lines.count == 4)
        let events = try lines.map { line -> BuilderPayload in
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(line.utf8))
            #expect(envelope.kind == .builder)
            return try envelope.decodePayload(BuilderPayload.self)
        }
        #expect(events.first?.event == "text")
        #expect(events.last?.event == "done")
        #expect(events.last?.ok == true)
    }

    // MARK: - Helpers

    private func expectFailure(
        _ result: Result<Void, ShadowTree.Failure>,
        _ expected: ShadowTree.Failure,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .failure(let failure) = result else {
            Issue.record("expected \(expected), got success", sourceLocation: sourceLocation)
            return
        }
        #expect(failure == expected, sourceLocation: sourceLocation)
    }

    private func decode(_ name: String) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: Fixtures.data(name))
    }

    private func rawObject(_ name: String) throws -> [String: JSONValue] {
        try JSONDecoder().decode(JSONValue.self, from: Fixtures.data(name)).asObject ?? [:]
    }
}
