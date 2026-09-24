/// Platform-independent logic for Process Monitor: the safety policy, usage math,
/// grouping and list building. Nothing in this module talks to the operating system;
/// all system access goes through the protocols in `Sources.swift`.
public enum MonitorCore {
    public static let version = "0.1.0"
}
