import Foundation
import Observation
import YabLocalization
import YabPlatform

public enum OnboardingStep: Equatable, Sendable {
    case welcome, importChoice, importing, setup
}

/// The first-run window: which step shows, what moves between steps, the accessibility request, the login choice
/// and what finishing does. Another clipboard manager's library, when found, adds the two import steps.
@MainActor @Observable
public final class OnboardingModel {
    public private(set) var step: OnboardingStep = .welcome
    public private(set) var accessibilityGranted: Bool
    public var launchAtLogin = true
    @ObservationIgnored private var finished = false

    public let importer: ImportModel
    public let language: LanguageStore

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let loginItem: LoginItemControlling
    @ObservationIgnored private let isTrusted: () -> Bool
    @ObservationIgnored private let promptAccessibility: () -> Void
    @ObservationIgnored private let onFinish: @MainActor () -> Void

    public init(
        importer: ImportModel, preferences: Preferences, language: LanguageStore, loginItem: LoginItemControlling,
        isTrusted: @escaping () -> Bool, promptAccessibility: @escaping () -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) {
        self.importer = importer
        self.preferences = preferences
        self.language = language
        self.loginItem = loginItem
        self.isTrusted = isTrusted
        self.promptAccessibility = promptAccessibility
        self.onFinish = onFinish
        accessibilityGranted = isTrusted()
    }

    /// Called by the window when it appears: looks for a library to bring along.
    public func appear() async {
        await importer.scan()
    }

    public static func shouldShowAtLaunch(onboarded: Bool, historyIsEmpty: Bool) -> Bool {
        !onboarded && historyIsEmpty
    }

    private var libraryMissing: Bool { importer.state == .unavailable }

    public var dots: Int { libraryMissing ? 2 : 3 }

    public var activeDot: Int {
        switch step {
        case .welcome: 0
        case .importChoice, .importing: 1
        case .setup: dots - 1
        }
    }

    public var showsPasteHint: Bool {
        if case .ready = importer.state { true } else { false }
    }

    public var shortcutSubtitleKey: String {
        showsPasteHint || importerHasLibrary
            ? "onboarding.setup.shortcut.fromPaste" : "onboarding.setup.shortcut.change"
    }

    /// A library was found at some point, even if it was imported since.
    private var importerHasLibrary: Bool {
        switch importer.state {
        case .importing, .done: true
        default: false
        }
    }

    /// Import needs a read library and something chosen; Continue waits for the import to end, also when it failed, so
    /// a broken library never holds the person in this window.
    public var primaryEnabled: Bool {
        switch step {
        case .importChoice:
            guard case .ready = importer.state else { return false }
            return importer.selection.history || !importer.selection.boards.isEmpty
        case .importing:
            return importEnded
        default:
            return true
        }
    }

    private var importEnded: Bool {
        switch importer.state {
        case .done, .failed: true
        default: false
        }
    }

    public func next() {
        switch step {
        case .welcome:
            step = libraryMissing ? .setup : .importChoice
        case .importChoice:
            guard primaryEnabled else { return }
            step = .importing
            importer.start()
        case .importing:
            if importEnded { step = .setup }
        case .setup:
            break
        }
    }

    /// Return: the step's primary button, only while it is enabled. On the last step it finishes.
    public func primary() {
        guard primaryEnabled else { return }
        if step == .setup { finish() } else { next() }
    }

    public func skipImport() {
        step = .setup
    }

    public func requestAccessibility() {
        promptAccessibility()
    }

    public func refreshAccessibility() {
        accessibilityGranted = isTrusted()
    }

    public func finish() {
        guard !finished else { return }
        finished = true
        preferences.onboarded = true
        if launchAtLogin {
            // A refusal stays visible in Settings; it must not hold the person in this window.
            try? loginItem.setEnabled(true)
        }
        onFinish()
    }

    public func escape() {
        finish()
    }
}
