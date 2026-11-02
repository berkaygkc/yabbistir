import AppKit
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
    public private(set) var step: OnboardingStep = .welcome {
        didSet { if step == .setup { sawSetup = true } }
    }
    public private(set) var accessibilityGranted: Bool
    public var launchAtLogin = true
    @ObservationIgnored private var finished = false
    /// The setup step has shown in this showing, so the person has seen the login switch.
    @ObservationIgnored private var sawSetup = false

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

    /// Called by the window when it appears: remembers that a first run has begun, then looks for a library to bring
    /// along.
    public func appear() async {
        if !preferences.firstRunStarted { preferences.firstRunStarted = true }
        await importer.scan()
    }

    /// A new install (nothing copied yet) gets the first run, and so does one whose first run was quit midway, whatever
    /// was copied since. Someone upgrading, with a history and no first run begun, does not.
    public static func shouldShowAtLaunch(onboarded: Bool, historyIsEmpty: Bool, firstRunStarted: Bool) -> Bool {
        !onboarded && (historyIsEmpty || firstRunStarted)
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
    /// a broken library never holds the person in this window. Settings may read the library again after it ended, so
    /// only an import still running holds Continue back.
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
        if case .importing = importer.state { false } else { true }
    }

    public func next() {
        switch step {
        case .welcome:
            // Run again while an earlier import still runs (or just ended): show its progress, never the choice, which
            // could only wait on it.
            if importerHasLibrary {
                step = .importing
            } else {
                step = libraryMissing ? .setup : .importChoice
            }
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

    /// Marks the first run done and closes. The login item follows the switch only if the person saw it (the setup
    /// step showed), and only where the two differ: on registers, off unregisters.
    public func finish() {
        guard !finished else { return }
        finished = true
        preferences.onboarded = true
        if sawSetup, launchAtLogin != opensAtLogin {
            // A refusal stays visible in Settings; it must not hold the person in this window.
            try? loginItem.setEnabled(launchAtLogin)
        }
        onFinish()
    }

    /// Esc and the close button finish too; before the setup step they leave the login item alone.
    public func escape() {
        finish()
    }

    /// How the app opens now: registered counts as on, also while it waits for the person's approval.
    private var opensAtLogin: Bool {
        [.enabled, .requiresApproval].contains(loginItem.status)
    }
}

public enum OnboardingKeyAction: Equatable, Sendable {
    case escape, primary
}

/// The first-run window's keys. Return and keypad Enter press the step's primary button (whatever has focus), Esc
/// finishes. A held key acts once: its repeats are ignored, so holding Return can't run through the steps.
public enum OnboardingKey {
    public static func action(keyCode: UInt16, isRepeat: Bool, modifiers: NSEvent.ModifierFlags = []) -> OnboardingKeyAction? {
        guard !isRepeat, modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        switch keyCode {
        case 53: return .escape
        case 36, 76: return .primary
        default: return nil
        }
    }
}
