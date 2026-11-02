import Foundation
import YabPlatform

struct FakeLoginItemError: Error {}

/// A login item whose answers the test sets: the status it reports after a change, and whether the change throws.
@MainActor
final class FakeLoginItem: LoginItemControlling {
    var status: LoginItemStatus
    /// What `status` becomes after a successful `setEnabled(true)`.
    var statusAfterEnabling: LoginItemStatus = .enabled
    var throwsOnChange = false
    private(set) var setEnabledCalls: [Bool] = []
    private(set) var openedSystemSettings = 0

    init(status: LoginItemStatus = .disabled) {
        self.status = status
    }

    func setEnabled(_ enabled: Bool) throws {
        setEnabledCalls.append(enabled)
        if throwsOnChange { throw FakeLoginItemError() }
        status = enabled ? statusAfterEnabling : .disabled
    }

    func openSystemSettings() {
        openedSystemSettings += 1
    }
}
