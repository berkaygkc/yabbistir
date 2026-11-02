import Foundation
import Testing
import YabPasteboard
@testable import YabCore
@testable import YabUI

private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)
private let day: TimeInterval = 86_400

@MainActor @Suite struct HistorySettingsModelTests {
    let preferences = Preferences(defaults: UserDefaults(suiteName: "yab-prefs-\(UUID().uuidString)")!)
    let library: Library
    let model: HistorySettingsModel
    let itemID: Int64

    /// One item last used 40 days ago, under a one-year policy.
    init() throws {
        let store = try ItemStore.temporary()
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data("eski not".utf8))]],
                                source: nil, device: .local, capturedAt: now.addingTimeInterval(-40 * day))
        itemID = try #require(try store.ingest(clip)).item.id!
        library = try Library(store: store)
        preferences.retention = .oneYear
        model = HistorySettingsModel(preferences: preferences, library: library, now: { now })
    }

    var itemCount: Int { (try? library.store.history(limit: 10).count) ?? -1 }

    @Test func shorterRetentionAsksFirst() {
        model.requestRetention(.oneMonth)
        #expect(model.pendingRetention == .oneMonth)
        #expect(model.pendingCount == 1)
        #expect(preferences.retention == .oneYear)
        #expect(itemCount == 1)
    }

    @Test func cancellingShorterRetentionKeepsEverything() {
        model.requestRetention(.oneMonth)
        model.cancelRetention()
        #expect(model.pendingRetention == nil)
        #expect(itemCount == 1)
        #expect(preferences.retention == .oneYear)
    }

    @Test func confirmingDeletesAndSaves() {
        model.requestRetention(.oneMonth)
        model.confirmRetention()
        #expect(model.pendingRetention == nil)
        #expect(itemCount == 0)
        #expect(preferences.retention == .oneMonth)
    }

    @Test func nothingToDeleteAppliesAtOnce() {
        model.requestRetention(.threeMonths)
        #expect(model.pendingRetention == nil)
        #expect(preferences.retention == .threeMonths)
        #expect(itemCount == 1)
        model.requestRetention(.unlimited)
        #expect(preferences.retention == .unlimited)
    }

    @Test func ignoredAppsReachTheCaptureFilter() {
        model.addIgnoredApp(bundleID: "dev.example.app")
        model.addIgnoredApp(bundleID: "dev.example.app")
        #expect(model.ignoredApps == CaptureFilter.defaultIgnoredBundleIDs + ["dev.example.app"])
        #expect(preferences.ignoredApps == model.ignoredApps)
        model.removeIgnoredApp(bundleID: "com.apple.Passwords")
        #expect(!model.ignoredApps.contains("com.apple.Passwords"))
        #expect(!preferences.ignoredApps.contains("com.apple.Passwords"))
    }
}
