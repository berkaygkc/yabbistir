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
        model.confirmRetention(.oneMonth)
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

    @Test func clearingHistoryReportsTheDeletedIDsAndClosesTheDialog() {
        var reported: [Int64]?
        model.onCleared = { reported = $0 }
        model.confirmingClear = true
        model.clearHistory()
        #expect(reported == [itemID])
        #expect(!model.confirmingClear)
        #expect(itemCount == 0)
    }

    @Test func confirmingWorksEvenWhenTheDialogClearedThePendingPolicyFirst() {
        model.requestRetention(.oneMonth)
        model.cancelRetention()
        model.confirmRetention(.oneMonth)
        #expect(itemCount == 0)
        #expect(preferences.retention == .oneMonth)
    }

    @Test func confirmingPurgesWithTheDateTheCountWasMadeAt() {
        var clock = now
        let timed = HistorySettingsModel(preferences: preferences, library: library, now: { clock })
        timed.requestRetention(.oneMonth)
        #expect(timed.pendingCount == 1)
        // The clock moves on; the purge still uses the date of the count.
        clock = now.addingTimeInterval(-60 * day)
        timed.confirmRetention(.oneMonth)
        #expect(itemCount == 0)
    }

    @Test func aFailedCountKeepsTheCurrentPolicy() throws {
        try library.store.dbPool.write { db in try db.drop(table: "item") }
        model.requestRetention(.oneMonth)
        #expect(model.pendingRetention == nil)
        #expect(preferences.retention == .oneYear)
    }

    @Test func appliedRetentionTellsTheApp() {
        var told = 0
        model.onRetentionApplied = { told += 1 }
        model.requestRetention(.oneMonth)
        model.confirmRetention(.oneMonth)
        #expect(told == 1)
    }

    @Test func theConfirmationCountsTheItemsInTheLanguage() {
        for (count, en, tr) in [(1, "This removes 1 item now.", "Bu ayar 1 öğeyi hemen siler."),
                                (1355, "This removes 1,355 items now.", "Bu ayar 1.355 öğeyi hemen siler.")] {
            #expect(HistorySettingsModel.retentionTitle(count: count, language: .english) == en)
            #expect(HistorySettingsModel.retentionTitle(count: count, language: .turkish) == tr)
        }
    }

    @Test func confirmingWithoutACountedRequestDoesNothing() {
        model.confirmRetention(.oneMonth)
        #expect(preferences.retention == .oneYear)
        #expect(itemCount == 1)
    }

    @Test func confirmingAnotherPolicyThanTheCountedOneDoesNothing() {
        model.requestRetention(.oneMonth)
        model.confirmRetention(.oneWeek)
        #expect(preferences.retention == .oneYear)
        #expect(itemCount == 1)
    }

    @Test func aFailedLaterCountDropsTheEarlierPendingRequest() throws {
        model.requestRetention(.oneMonth)
        #expect(model.pendingRetention == .oneMonth)
        try library.store.dbPool.write { db in try db.drop(table: "item") }
        model.requestRetention(.oneWeek)
        #expect(model.pendingRetention == nil)
        model.confirmRetention(.oneMonth)
        #expect(preferences.retention == .oneYear)
    }

    @Test func appNamesLoseOnlyATrailingDotApp() {
        #expect(AppNames.display("Notes.app") == "Notes")
        #expect(AppNames.display("x.us") == "x.us")
        #expect(AppNames.display("Notes") == "Notes")
        #expect(AppNames.display("a.app.app") == "a.app")
    }
}
