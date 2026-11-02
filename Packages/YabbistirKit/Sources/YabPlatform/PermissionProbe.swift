import AppKit
import Foundation

/// What macOS lets yabbistir do with the general pasteboard.
public enum PasteboardAccess: Sendable {
    case notAsked, ask, allowed, denied
}

/// Reads the live state of every permission the app uses.
@MainActor
public protocol PermissionProbing {
    var accessibility: Bool { get }
    var inputMonitoring: Bool { get }
    var pasteboard: PasteboardAccess { get }
    var loginItem: LoginItemStatus { get }
}

@MainActor
public struct SystemPermissionProbe: PermissionProbing {
    private let loginItemSource: LoginItemControlling

    public init(loginItem: LoginItemControlling) {
        loginItemSource = loginItem
    }

    public var accessibility: Bool { AccessibilityPermission.isTrusted() }

    public var inputMonitoring: Bool { InputMonitoringPermission.isGranted() }

    /// Reads the setting only; the pasteboard's contents are never touched.
    public var pasteboard: PasteboardAccess {
        switch NSPasteboard.general.accessBehavior {
        case .default: .notAsked
        case .ask: .ask
        case .alwaysAllow: .allowed
        case .alwaysDeny: .denied
        @unknown default: .notAsked
        }
    }

    public var loginItem: LoginItemStatus { loginItemSource.status }
}
