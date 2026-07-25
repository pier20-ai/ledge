import Testing
@testable import LedgeShellCore

@Suite("Shell presentation state")
struct ShellStateTests {
    @Test("Expansion returns to the last app that filled the panel")
    func expansionMemory() {
        var state = ShellState(presentation: .expanded(app: "music"))
        state.toggleExpansion()
        #expect(state.presentation == .collapsed)
        state.toggleExpansion()
        #expect(state.presentation == .expanded(app: "music"))
    }

    @Test("Expanding with nothing to show lands on the placeholder")
    func expandsWithoutAnApp() {
        var state = ShellState()
        state.toggleExpansion()
        #expect(state.presentation == .expanded(app: nil))
        #expect(state.isExpanded)
        #expect(state.presentedApp == nil)
    }

    @Test("The first catalog seeds the hover-reopen memory, later ones don't")
    func seededMemory() {
        var state = ShellState()
        state.rememberIfUnset("stocks")
        state.toggleExpansion()
        #expect(state.presentation == .expanded(app: "stocks"))

        state.present(.expanded(app: "deals"))
        state.rememberIfUnset("stocks")
        state.toggleExpansion()                       // collapse
        state.toggleExpansion()                       // reopen
        #expect(state.presentation == .expanded(app: "deals"))
    }

    @Test("Chat toggles against the presented app and back")
    func chatToggle() {
        var state = ShellState(presentation: .expanded(app: "stocks"))
        state.toggleChat()
        #expect(state.presentation == .chat(app: "stocks"))
        state.toggleChat()
        #expect(state.presentation == .expanded(app: "stocks"))
    }

    @Test("Chat is a no-op where there is no app to talk about")
    func chatNeedsAnApp() {
        var state = ShellState(presentation: .newApp)
        state.toggleChat()
        #expect(state.presentation == .newApp)

        state.present(.expanded(app: nil))
        state.toggleChat()
        #expect(state.presentation == .expanded(app: nil))
    }

    @Test("Chat keeps the app's icon lit and keeps it as the remembered app")
    func chatStaysOnTheApp() {
        var state = ShellState(presentation: .expanded(app: "stocks"))
        state.toggleChat()
        #expect(state.presentation.app == "stocks")
        #expect(state.presentation.isChat)
        state.collapse()
        state.toggleExpansion()
        #expect(state.presentation == .expanded(app: "stocks"))
    }

    @Test("The [+] surface does not replace the remembered app")
    func temporaryChrome() {
        var state = ShellState(presentation: .expanded(app: "deals"))
        state.present(.newApp)
        #expect(state.presentation.app == nil)
        state.collapse()
        state.toggleExpansion()
        #expect(state.presentation == .expanded(app: "deals"))
    }

    @Test("Selecting the presented app toggles its chat; a different app switches")
    func selection() {
        var state = ShellState(presentation: .expanded(app: "stocks"))
        state.selectApp("music")
        #expect(state.presentation == .expanded(app: "music"))
        state.selectApp("music")
        #expect(state.presentation == .chat(app: "music"))
        state.selectApp("music")
        #expect(state.presentation == .expanded(app: "music"))
        state.selectApp("stocks")
        #expect(state.presentation == .expanded(app: "stocks"))
    }

    @Test("App ids are runtime strings — the shell has no built-in app list")
    func runtimeAppIDs() {
        var state = ShellState()
        state.present(.expanded(app: "flight-ua884"))
        #expect(state.presentedApp == "flight-ua884")
        #expect(state.lastPresentedApp == "flight-ua884")
    }
}
