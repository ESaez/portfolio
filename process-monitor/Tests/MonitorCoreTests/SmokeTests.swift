import Testing
@testable import MonitorCore

@Test func versionIsSet() {
    #expect(!MonitorCore.version.isEmpty)
}
