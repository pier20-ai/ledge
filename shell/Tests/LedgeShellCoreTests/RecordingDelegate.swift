import Foundation
@testable import LedgeShellCore

/// Test double capturing every side effect the engine drives, so the control
/// plane and commit pipeline can be exercised headlessly.
@MainActor
final class RecordingDelegate: ProtocolEngineDelegate {
    struct Commit { let app: String; let mutations: [Mutation] }
    struct ErrorCard { let app: String; let message: String; let stack: String? }
    struct Draw { let app: String; let id: Int; let ops: [JSONValue] }

    var commits: [Commit] = []
    var discardedApps: [String] = []
    var discardAllCount = 0
    var errorCards: [ErrorCard] = []
    var lifecycles: [(app: String, state: String)] = []
    var chromeRequests: [
        (app: String, request: String, wing: WingSpec?, ms: Double?, priority: NotificationClass?)
    ] = []
    var draws: [Draw] = []
    var catalogs: [CatalogPayload] = []
    var builderEvents: [BuilderPayload] = []

    func applyCommit(app: String, mutations: [Mutation]) {
        commits.append(Commit(app: app, mutations: mutations))
    }
    func discardApp(_ app: String) { discardedApps.append(app) }
    func discardAllApps() { discardAllCount += 1 }
    func showErrorCard(app: String, message: String, stack: String?) {
        errorCards.append(ErrorCard(app: app, message: message, stack: stack))
    }
    func appLifecycle(app: String, state: String) { lifecycles.append((app, state)) }
    func chromeRequest(
        app: String,
        request: String,
        wing: WingSpec?,
        ms: Double?,
        priority: NotificationClass?
    ) {
        chromeRequests.append((app, request, wing, ms, priority))
    }
    func drawCanvas(app: String, id: Int, ops: [JSONValue]) {
        draws.append(Draw(app: app, id: id, ops: ops))
    }
    func catalogUpdated(_ catalog: CatalogPayload) { catalogs.append(catalog) }
    func builderEvent(_ payload: BuilderPayload) { builderEvents.append(payload) }
}

/// A collecting outbound sink.
@MainActor
final class OutboundRecorder {
    private(set) var sent: [Envelope] = []
    func record(_ envelope: Envelope) { sent.append(envelope) }
    func last(ofType type: String) -> Envelope? { sent.last { $0.type == type } }
    func all(ofType type: String) -> [Envelope] { sent.filter { $0.type == type } }
}
