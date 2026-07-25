import Foundation
import Testing
@testable import LedgeShellCore

/// The real thing: these tests actually compile and run AppleScript in the test
/// process. Nothing here drives another application, so no Automation consent is
/// involved — which is precisely the point of the round trip: it proves
/// `ctx.apple.script` computes and returns a value end to end, and the *only*
/// remaining variable in production is TCC's answer for a given target app.
///
/// `.serialized`, and every call goes through one `AppleExecutor`: concurrent
/// `NSAppleScript` execution from several threads fails with OSA error −1751,
/// which is exactly why the executor owns a serial queue in the first place.
/// (Running the tests in parallel found that; the suite is now shaped like the
/// production path rather than around it.)
@Suite("AppleScript execution (spec §6)", .serialized)
struct AppleExecutorTests {
    private let executor = AppleExecutor(label: "com.ledge.tests.apple")

    private func run(_ invocation: AppleInvocation) async -> Result<JSONValue, CapabilityError> {
        await withCheckedContinuation { continuation in
            executor.run(invocation) { continuation.resume(returning: $0) }
        }
    }

    @Test("`return 1 + 2` really runs and comes back as the number 3")
    func scriptReturnsNumber() async throws {
        let value = try await run(.script("return 1 + 2")).get()
        #expect(value.asInt == 3)
    }

    @Test("Strings, booleans and lists survive the descriptor conversion")
    func scriptValueShapes() async throws {
        #expect(try await run(.script("return \"hi \" & (2 * 3)")).get().asString == "hi 6")
        #expect(try await run(.script("return true")).get().asBool == true)
        let list = try await run(.script("return {1, 2, 3}")).get()
        #expect(list.asArray?.count == 3)
        #expect(list.asArray?.first?.asInt == 1)
    }

    @Test("A script error is a CapabilityError carrying AppleScript's own message")
    func scriptErrorIsReported() async {
        switch await run(.script("error \"nope\" number 42")) {
        case let .success(value):
            Issue.record("expected a failure, got \(value)")
        case let .failure(error):
            #expect(error.message.contains("nope"))
        }
    }

    @Test("A script that will not compile fails without crashing the shell")
    func uncompilableScript() async {
        let result = await run(.script("tell application without"))
        #expect((try? result.get()) == nil)
    }

    @Test("A missing Shortcut fails with the CLI's message rather than hanging")
    func missingShortcut() async {
        // `shortcuts run` on a name nobody has exits nonzero; the point of the
        // test is that the failure is a value, not a wedged bridge.
        let result = await run(.shortcut(name: "ledge-test-shortcut-that-does-not-exist", input: nil))
        #expect((try? result.get()) == nil)
    }
}
