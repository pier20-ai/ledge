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

    @Test("Chrome fixtures: expand, and the four wing shapes (§3.3)")
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

        // A meter — the stock right-wing bar (flow.md's third wing form). The
        // app names a fraction; every other number belongs to the shell.
        let meter = try decode("chrome-wing-meter.json").decodePayload(ChromePayload.self)
        #expect(meter.wing?.text == "12:04")
        #expect(meter.wing?.meter == WingMeterSpec(value: 0.42))
        #expect(meter.wing?.canvas == nil)
        #expect(meter.wing?.isEmpty == false)

        // The host clamps `value` on the way out; the shell clamps it again on
        // the way in, because a fill wider than its track is the one thing this
        // must never draw — and a fixture is the only place both can be proved.
        let clamped = try decode("chrome-wing-meter-clamp.json").decodePayload(ChromePayload.self)
        #expect(clamped.wing?.meter?.value == 1.8)
        #expect(clamped.wing?.meter?.fraction == 1)
        #expect(WingMeterSpec(value: -0.5).fraction == 0)
        #expect(WingMeterSpec(value: .nan).fraction == 0)

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
            ("platform-observe-focus.json", "focus", "changed"),
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
            "event-platform-audio.json", "event-platform-focus.json",
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

    /// **`recordStart`'s defaults and refusals** (G3). Decoding is where the
    /// vocabulary is settled: the executor is handed `[RecordingSource]` and a
    /// `RecordingFormat` and never sees a string, so anything the shell has
    /// never heard of has to die here or not at all.
    ///
    /// The refusals matter more than the defaults. A source the shell cannot
    /// open must fail the whole call rather than quietly recording the half it
    /// understood — an app that asked for both sides of a call and got one is
    /// worse off than an app that got an error, because it does not find out
    /// until someone plays the file back.
    @Test("recordStart defaults to both sources in AAC, and refuses a vocabulary it does not know")
    func recordStartParsing() {
        func payload(_ object: [String: JSONValue]) -> PlatformPayload? {
            let envelope = Envelope(app: "scribe", seq: 1, type: "platform", payload: .object(object))
            return try? envelope.decodePayload(PlatformPayload.self)
        }
        func start(_ fields: [String: JSONValue] = [:]) -> PlatformPayload? {
            payload(["id": .int(1), "call": .string("recordStart")].merging(fields) { _, new in new })
        }

        // "record" with no fields at all: both sources, AAC. An app that says
        // nothing means "record the conversation", which is two-sided.
        #expect(start()?.invocation == .recordStart(sources: [.mic, .system], format: .aac))

        // Named explicitly, in either order, the list comes back sorted — so the
        // wire, the session's `sources`, and `meta.json` all agree on one order
        // and a test never has to care which the app wrote.
        #expect(start(["sources": .array([.string("system"), .string("mic")])])?.invocation
            == .recordStart(sources: [.mic, .system], format: .aac))
        #expect(start(["sources": .array([.string("mic")]), "format": .string("wav")])?.invocation
            == .recordStart(sources: [.mic], format: .wav))

        // A repeat is a duplicate ask, not two streams: deduped rather than
        // refused, because it costs nothing and the intent is unambiguous.
        #expect(start(["sources": .array([.string("mic"), .string("mic")])])?.invocation
            == .recordStart(sources: [.mic], format: .aac))

        // A source or a format the shell cannot open is malformed, whole.
        #expect(start(["sources": .array([.string("mic"), .string("bluetooth")])])?.isSupported == false)
        #expect(start(["format": .string("flac")])?.isSupported == false)
        // An explicitly empty list is not "the default": it is a request to
        // record nothing, which is a bug in the app rather than a session.
        #expect(start(["sources": .array([])])?.isSupported == false)

        // The other three verbs take no fields — the envelope's own `app` is the
        // only context ownership needs.
        #expect(payload(["id": .int(1), "call": .string("recordStatus")])?.invocation == .recordStatus)
        #expect(payload(["id": .int(1), "call": .string("recordStop")])?.invocation == .recordStop)
        #expect(payload(["id": .int(1), "call": .string("recordLevels")])?.invocation == .recordLevels)
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

    @Test("Summary fixtures mount, update, and reject a nested zone (§5 `summary`)")
    func summaryFixtures() throws {
        let mount = try decode("commit-summary.json")
        let mutations = try mount.decodePayload(CommitPayload.self).mutations
        let tree = ShadowTree()
        #expect(tree.apply(mutations).isSuccess)

        let summary = try #require(mutations.first { $0.kind == "summary" })
        // No props at all: what a summary says is its children, and *when* it
        // shows is the shell's. An app can neither ask for one nor pin one open,
        // and the chevron on it is drawn outside this node entirely.
        #expect(summary.props?.isEmpty ?? true)
        // A root-level zone, exactly like `wing` and `mini`.
        #expect(tree.node(2)?.kind == .summary)
        #expect(tree.node(2)?.parent == 1)
        #expect(tree.node(2)?.children == [3])
        // The heavy thing it stands in for is a *sibling*, not a child: a heavy
        // session is one that owes the hover a cheap line instead of a board.
        #expect(tree.node(6)?.kind == .canvas)
        #expect(tree.node(6)?.parent == 1)

        // Updates on summary descendants are ordinary updates.
        let updates = try decode("commit-summary-update.json")
            .decodePayload(CommitPayload.self).mutations
        #expect(updates.allSatisfy { $0.op == .update })
        #expect(tree.apply(updates).isSuccess)

        // …and a summary nested in the layout is the same §3.1 failure a nested
        // wing or mini is: it would render into a surface its parent cannot see.
        let nested = ShadowTree()
        let misplaced = try decode("invalid-commit-nested-summary.json")
            .decodePayload(CommitPayload.self).mutations
        expectFailure(nested.apply(misplaced), .misplacedZone(id: 3, kind: .summary))
        #expect(nested.isEmpty)
    }

    @Test("A peek carries its priority class, and absent is ambient (§3.3)")
    func peekClassFixtures() throws {
        let alert = try decode("chrome-peek-alert.json")
        #expect(alert.kind == .chrome)
        let payload = try alert.decodePayload(ChromePayload.self)
        #expect(payload.request == "peek")
        // `class` on the wire, `priority` in Swift — `class` is a keyword here.
        #expect(payload.priority == .alert)

        // The ordinary peek names no class, and must stay that way: a default
        // spelled out on the wire is a default kept in sync in two places.
        let ambient = try decode("chrome-peek.json").decodePayload(ChromePayload.self)
        #expect(ambient.priority == nil)
        // Absent — and anything the shell has not heard of — reads as ambient,
        // so a forward-compatible wire can never produce a swell that never
        // goes away.
        #expect(NotificationClass(token: ambient.priority?.rawValue) == .ambient)
        #expect(NotificationClass(token: "urgent") == .ambient)
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

        // `progress.color` (G3) is a *token*, never a hex string: one bar names
        // a hue family, the other names nothing and is ink.
        #expect(try props(3)["color"]?.asString == "accent")
        #expect(try props(5)["color"] == nil)

        let updates = try decode("commit-rate-update.json")
            .decodePayload(CommitPayload.self).mutations
        #expect(tree.apply(updates).isSuccess)
        // Pausing is `rate: 0`; deleting the key (§3.1 null) means the same.
        #expect(updates.first { $0.id == 2 }?.props?["rate"]?.asDouble == 0)
        #expect(updates.first { $0.id == 3 }?.props?["rate"] == JSONValue.null)
        // …and the hue goes the same two ways in one commit: deleted on one bar,
        // added on the other.
        #expect(updates.first { $0.id == 3 }?.props?["color"] == JSONValue.null)
        #expect(updates.first { $0.id == 5 }?.props?["color"]?.asString == "green")
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
        // `progress.color` is a token string, so a raw number is refused on the
        // wire rather than silently ignored by the renderer (G3).
        expectFailure(
            tree.apply([Mutation(op: .create, id: 4, kind: "progress", props: ["color": .int(0xFF)])]),
            .badProps(id: 4, key: "color")
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

    @Test("Type-ramp fixtures validate: two new sizes, a new weight, and `caps` (§5)")
    func typeRampFixtures() throws {
        let mount = try decode("commit-type-ramp.json")
        let mutations = try mount.decodePayload(CommitPayload.self).mutations
        let tree = ShadowTree()
        #expect(tree.apply(mutations).isSuccess)

        func props(_ id: Int) throws -> [String: JSONValue] {
            try #require(mutations.first { $0.op == .create && $0.id == id }?.props)
        }
        #expect(try props(2)["size"]?.asString == "hero")
        #expect(try props(2)["weight"]?.asString == "light")
        #expect(try props(3)["size"]?.asString == "display")
        // `caps` is a *bool*, and it has to be type-checked as one: a `caps: "on"`
        // that validated would reach the renderer and render as no caps at all.
        #expect(try props(4)["caps"]?.asBool == true)
        // The pre-existing ramp is untouched — §3.1's headline price still xl/bold.
        #expect(try props(5)["size"]?.asString == "xl")

        let update = try decode("commit-type-ramp-update.json")
        let updates = try update.decodePayload(CommitPayload.self).mutations
        #expect(updates.allSatisfy { $0.op == .update })
        #expect(tree.apply(updates).isSuccess)
        // `caps: null` is the canonical delete (§3.1): the label goes back to the
        // casing the app wrote rather than staying shouted.
        #expect(updates.first { $0.id == 4 }?.props?["caps"] == JSONValue.null)

        // And the wrong type still fails, on the new prop as on every other one.
        expectFailure(
            tree.apply([Mutation(op: .update, id: 4, props: ["caps": .string("on")])]),
            .badProps(id: 4, key: "caps")
        )
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

    @Test("App-control fixtures: `variant=\"ghost\"` and `image.stroke` (F2.3)")
    func appControlFixtures() throws {
        let mount = try decode("commit-app-controls.json")
        let mutations = try mount.decodePayload(CommitPayload.self).mutations
        let tree = ShadowTree()
        #expect(tree.apply(mutations).isSuccess)

        func props(_ id: Int) throws -> [String: JSONValue] {
            try #require(mutations.first { $0.op == .create && $0.id == id }?.props)
        }
        // `stroke` is a *string* token on an image, the same way it is on a
        // stack — a raw colour would put theming in the app (§5).
        #expect(try props(2)["stroke"]?.asString == "hairline")
        #expect(try props(3)["stroke"]?.asString == "accent")
        #expect(try props(4)["stroke"] == nil)                     // absent ⇒ unframed
        #expect(try props(5)["variant"]?.asString == "ghost")
        // `bead` validates on the wire — it is a string, and the wire's job is
        // types. Refusing it is the *renderer's* ruling, and the shell suite's
        // AppControlsTests is where that is pinned.
        #expect(try props(7)["variant"]?.asString == "bead")

        let updates = try decode("commit-app-controls-update.json")
            .decodePayload(CommitPayload.self).mutations
        #expect(updates.allSatisfy { $0.op == .update })
        #expect(tree.apply(updates).isSuccess)
        // `stroke: null` is the canonical delete (§3.1): the well loses its ring
        // rather than keeping a stale one.
        #expect(updates.first { $0.id == 2 }?.props?["stroke"] == JSONValue.null)
        // …and a symbol node swaps its `src` in place (G3). Still an `sf:` src
        // on both sides of the pair: a src that changes *kind* is a different
        // component, not an update.
        #expect(try props(3)["src"]?.asString == "sf:waveform")
        #expect(updates.first { $0.id == 3 }?.props?["src"]?.asString == "sf:waveform.badge.mic")

        // And the wrong type is still refused on the new prop.
        expectFailure(
            tree.apply([Mutation(op: .update, id: 2, props: ["stroke": .int(1)])]),
            .badProps(id: 2, key: "stroke")
        )
    }

    @Test("`lifecycle` carries Reduce Motion beside the phase (§4.2)")
    func reduceMotionRidesLifecycle() throws {
        let payload = try rawObject("lifecycle-reduce-motion.json")["payload"]?.asObject ?? [:]
        #expect(payload["phase"]?.asString == "collapsed")
        #expect(payload["reduceMotion"]?.asBool == true)
        // Same envelope, same screen block: the flag is a *rider*, not a new
        // shape, which is the whole reason it needs no version bump.
        #expect(payload["screen"]?.asObject?["notchWidth"]?.asDouble == 189)

        // The pre-existing fixture has no such key, and that has to stay legal:
        // absent means "unchanged", so a shell that predates the flag is not a
        // shell claiming motion is fine.
        let older = try rawObject("lifecycle-expanded.json")["payload"]?.asObject ?? [:]
        #expect(older["reduceMotion"] == nil)
        #expect(older["phase"]?.asString == "expanded")
    }

    // MARK: - `meta.settings` on the catalog (G4)

    /// **The wire says `default`; Swift cannot.** `default` is a keyword, so
    /// the field is `defaultValue` in Swift and the `CodingKeys` carry the
    /// mapping — which is exactly the kind of rename that is silently wrong
    /// until something reads a real payload. This reads a real payload.
    @Test("A declared control decodes, `default` and all (G4 §1)")
    func settingSpecDecodesTheWireShape() throws {
        let json = """
        { "apps": [ { "id": "radio", "name": "Radio", "icon": "sf:radio",
          "order": 0, "enabled": true, "running": true,
          "settings": [
            { "key": "dial-size", "label": "Stations on the dial", "type": "number",
              "min": 6, "max": 36, "step": 6, "default": 24 },
            { "key": "clicks", "label": "Report listens", "type": "toggle",
              "default": true, "hint": "Radio Browser counts a tune-in." },
            { "key": "format", "label": "Recording format", "type": "choice",
              "options": ["aac", "wav"], "default": "aac" },
            { "key": "model", "label": "Model", "type": "text", "default": "gpt-5.6-luna" }
          ],
          "values": { "dial-size": 12, "clicks": false, "format": "wav", "model": "gpt-5.6-luna" }
        } ] }
        """
        let apps = try JSONDecoder().decode(CatalogPayload.self, from: Data(json.utf8)).apps
        let radio = try #require(apps.first)
        let settings = try #require(radio.settings)
        #expect(settings.count == 4)

        let dial = settings[0]
        #expect(dial.key == "dial-size")
        #expect(dial.kind == .number)
        #expect(dial.defaultValue == .int(24))
        #expect(dial.min == 6)
        #expect(dial.max == 36)
        #expect(dial.step == 6)
        // The bounds belong to `number` alone, and absence is absence.
        #expect(settings[1].min == nil)

        #expect(settings[1].kind == .toggle)
        #expect(settings[1].defaultValue == .bool(true))
        #expect(settings[1].hint == "Radio Browser counts a tune-in.")

        #expect(settings[2].kind == .choice)
        #expect(settings[2].options == ["aac", "wav"])
        #expect(settings[2].defaultValue == .string("aac"))

        #expect(settings[3].kind == .text)
        #expect(settings[3].hint == nil)

        // `values` is the EFFECTIVE map — the stored value wins over the
        // declared default, and it is the *catalog* that resolves that, never
        // the shell (G4 §3).
        #expect(radio.values?["dial-size"] == .int(12))
        #expect(radio.values?["clicks"] == .bool(false))
        #expect(radio.values?["format"] == .string("wav"))

        // A round trip puts `default` back on the wire under its own name.
        let reencoded = try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(radio)
        ).asObject
        let first = try #require(reencoded?["settings"]?.asArray?.first?.asObject)
        #expect(first["default"]?.asInt == 24)
        #expect(first["defaultValue"] == nil, "the Swift spelling must not reach the wire")
    }

    /// A type this build has never heard of is not an error and not a guess:
    /// `kind` is nil, and the window skips the row whole. Growing the
    /// vocabulary must never take a shell down.
    @Test("A `type` from the future decodes with no kind, and everything else survives")
    func anUnknownTypeHasNoKind() throws {
        let json = """
        { "apps": [ { "id": "scribe", "name": "Scribe", "icon": "sf:mic",
          "order": 0, "enabled": true, "running": true,
          "settings": [
            { "key": "highlight", "label": "Highlight", "type": "colour-picker",
              "default": "#ff0000" },
            { "key": "keep", "label": "Keep the audio", "type": "toggle", "default": false }
          ] } ] }
        """
        let apps = try JSONDecoder().decode(CatalogPayload.self, from: Data(json.utf8)).apps
        let settings = try #require(apps.first?.settings)

        #expect(settings[0].type == "colour-picker", "the raw word is kept — it is not ours to lose")
        #expect(settings[0].kind == nil)
        #expect(settings[0].defaultValue == .string("#ff0000"))
        // The neighbour is untouched: one unreadable row is one row.
        #expect(settings[1].kind == .toggle)
    }

    /// **Backwards compatibility, pinned.** Apps that declare no settings carry
    /// neither field — absent, not empty (G4 §3) — and the golden catalog from
    /// before G4 must go on decoding exactly as it did. A shell that required
    /// the new keys would refuse every catalog an older host sends.
    @Test("A catalog from before `meta.settings` decodes unchanged")
    func oldCatalogsStillDecode() throws {
        let apps = try decode("catalog.json").decodePayload(CatalogPayload.self).apps
        #expect(apps.count == 4)
        for app in apps {
            #expect(app.settings == nil, "\(app.id) invented a settings array")
            #expect(app.values == nil, "\(app.id) invented a values map")
        }
        // …and absent stays absent on the way back out, rather than becoming
        // `"settings": []` — which a host would read as "declared nothing on
        // purpose" and is a different statement from "did not say".
        let encoded = try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(apps[0])
        ).asObject
        #expect(encoded?["settings"] == nil)
        #expect(encoded?["values"] == nil)
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
