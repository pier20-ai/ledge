import Foundation
import Testing
@testable import LedgeShellCore

/// The host↔shell seam for the builder stream (spec §3.6).
///
/// This suite exists because the two halves were written against the same spec
/// section and still disagreed. `builder` is a CONTROL PLANE frame (§3.6:
/// "shell-level, `app: \"\"`"), so the envelope's app is empty and the payload
/// names the app — but the host was sending it as an ordinary per-app envelope
/// with the app on the frame. That type-checks on both sides and decodes on
/// neither: the decode site is `guard … else { return }`, so the entire builder
/// stream vanished with no error anywhere and the editor rendered nothing.
///
/// The frames below are byte-for-byte what `Router.sendBuilder` emits.
@MainActor
@Suite("Builder wire format (spec §3.6)")
struct BuilderWireTests {
    /// Control-plane framing: `app: ""` on the envelope, the app in the payload.
    private func decode(_ payload: String) throws -> BuilderPayload {
        let raw = #"{"v":1,"app":"","seq":1,"type":"builder","payload":\#(payload)}"#
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(raw.utf8))
        #expect(envelope.app.isEmpty)
        return try envelope.decodePayload(BuilderPayload.self)
    }

    @Test("every event the host emits decodes, and takes its app from the envelope")
    func hostEventsDecode() throws {
        let text = try decode(#"{"app":"stocks","turn":1,"event":"text","delta":"Making the price…"}"#)
        #expect(text.event == "text")
        #expect(text.delta == "Making the price…")
        // Named by the payload, because the envelope cannot name it.
        #expect(text.app == "stocks")
        #expect(text.turn == 1)

        let tool = try decode(#"{"app":"stocks","turn":1,"event":"tool","name":"edit","detail":"app.jsx","state":"completed"}"#)
        #expect(tool.name == "edit")
        #expect(tool.state == "completed")

        let status = try decode(#"{"app":"stocks","turn":1,"event":"status","text":"rate limited — retrying"}"#)
        #expect(status.text == "rate limited — retrying")

        // done.status is an outcome, not a boolean: a failed turn still completes.
        for outcome in ["completed", "interrupted", "failed"] {
            let done = try decode(#"{"app":"stocks","turn":2,"event":"done","status":"\#(outcome)"}"#)
            #expect(done.status == outcome)
        }

        let error = try decode(#"{"app":"stocks","turn":2,"event":"error","message":"not logged in"}"#)
        #expect(error.message == "not logged in")
    }

    @Test("an unexpected or missing field costs that field, never the event")
    func decodingIsForgiving() throws {
        // The builder stream is the one payload a third party (the agent
        // adapter) shapes, and a dropped event is invisible — so a surprise must
        // never take the turn behind it down too.
        let odd = try decode(#"{"app":"stocks","turn":3,"event":"text","delta":"hi","somethingNew":{"a":1}}"#)
        #expect(odd.event == "text")
        #expect(odd.delta == "hi")

        let bare = try decode(#"{"event":"done"}"#)
        #expect(bare.event == "done")
        #expect(bare.turn == 0)
    }
}
