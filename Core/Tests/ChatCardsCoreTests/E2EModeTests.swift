import Testing
@testable import ChatCardsCore

@Suite struct E2EModeTests {
    @Test func switchReadsEnvironmentAndArgument() {
        #expect(E2EMode.isOn(environment: ["E2E": "1"], arguments: []))
        #expect(!E2EMode.isOn(environment: ["E2E": "0"], arguments: []))
        #expect(E2EMode.isOn(environment: [:], arguments: ["ChatCards", "-E2E", "1"]))
        #expect(E2EMode.isOn(environment: [:], arguments: ["ChatCards", "-E2E", "YES"]))
        #expect(!E2EMode.isOn(environment: [:], arguments: ["ChatCards", "-E2E"]))
        #expect(!E2EMode.isOn(environment: [:], arguments: ["ChatCards"]))
    }

    @Test func testModeKeepsAwayFromRealData() {
        guard E2EMode.isOn else { return }
        #expect(SourceStore.defaultURL.path.hasPrefix(E2EMode.dataDirectory.path))
        #expect(!ClaudeSessions.defaultRoot.path.contains("/.claude/projects"))
        #expect(AnkiConnect.defaultURL.port != 8765)
    }
}
