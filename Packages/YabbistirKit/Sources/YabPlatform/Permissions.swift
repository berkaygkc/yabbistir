import ApplicationServices
import Foundation
import IOKit.hid

public enum AccessibilityPermission {
    public static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that points the user to Accessibility settings.
    public static func prompt() {
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

/// The paste stack hears the user's ⌘V through a listen-only event tap, which needs Input Monitoring.
public enum InputMonitoringPermission {
    public static func isGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the system prompt the first time; after that the user grants it in System Settings.
    public static func request() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}

/// Deep links straight to the relevant System Settings panes.
public enum SystemSettingsLink {
    public static let accessibility = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    public static let inputMonitoring = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
}
