import Darwin
import Testing
@testable import MonitorDarwin

@Test func currentUIDMatchesGetuid() {
    #expect(MonitorDarwin.currentUID() == getuid())
}
