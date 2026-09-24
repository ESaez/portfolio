import Darwin
import MonitorCore

/// macOS implementations of the MonitorCore sources (libproc, sysctl, IOKit, Security).
public enum MonitorDarwin {
    /// The real user ID of this process.
    public static func currentUID() -> UInt32 { getuid() }
}
