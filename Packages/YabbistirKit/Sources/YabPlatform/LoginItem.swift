import Foundation
import ServiceManagement

/// Whether the app opens when the person logs in.
public enum LoginItemStatus: Equatable, Sendable {
    case enabled, disabled, requiresApproval, unavailable
}

@MainActor
public protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

/// The main app as a login item (`SMAppService.mainApp`).
@MainActor
public final class SystemLoginItem: LoginItemControlling {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
