import Foundation
import Observation
import YabCore
import YabPasteboard
import YabPlatform

public enum AppearanceChoice: String, CaseIterable, Sendable {
    case system, light, dark
}

/// How long the pointer rests on a row before its preview opens.
public enum PreviewDelay: String, CaseIterable, Sendable {
    case short, medium, long

    public var duration: Duration {
        switch self {
        case .short: .milliseconds(100)
        case .medium: .milliseconds(300)
        case .long: .milliseconds(600)
        }
    }
}

/// What Return does with a row: paste it into the app in front, or only put it on the clipboard.
public enum PasteDestination: String, CaseIterable, Sendable {
    case app, clipboard
}

/// The person's preferences, each kept under its own `pref.*` key. An unknown or corrupt value reads as the default.
@MainActor @Observable
public final class Preferences {
    public var appearance: AppearanceChoice { didSet { defaults.set(appearance.rawValue, forKey: "pref.appearance") } }
    public var showsMenuBarIcon: Bool { didSet { defaults.set(showsMenuBarIcon, forKey: "pref.menuBarIcon") } }
    public var hidesFromScreenSharing: Bool {
        didSet { defaults.set(hidesFromScreenSharing, forKey: "pref.hideFromScreenSharing") }
    }
    public var panelPosition: PanelPosition { didSet { defaults.set(panelPosition.rawValue, forKey: "pref.panelPosition") } }
    public var previewDelay: PreviewDelay { didSet { defaults.set(previewDelay.rawValue, forKey: "pref.previewDelay") } }
    public var pasteDestination: PasteDestination {
        didSet { defaults.set(pasteDestination.rawValue, forKey: "pref.pasteDestination") }
    }
    public var alwaysPlainText: Bool { didSet { defaults.set(alwaysPlainText, forKey: "pref.alwaysPlainText") } }
    public var retention: RetentionPolicy { didSet { defaults.set(retention.rawValue, forKey: "pref.retention") } }
    public var ignoredApps: [String] { didSet { defaults.set(ignoredApps, forKey: "pref.ignoredApps") } }
    public var keepsRemoteCopies: Bool { didSet { defaults.set(keepsRemoteCopies, forKey: "pref.keepRemoteCopies") } }
    public var showsExtensionOutputs: Bool {
        didSet { defaults.set(showsExtensionOutputs, forKey: "pref.showExtensionOutputs") }
    }
    /// Whether the first-run window has been finished or dismissed.
    public var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "pref.onboarded") } }
    /// Whether the first-run window has shown at all, finished or not: quitting midway brings it back next launch.
    public var firstRunStarted: Bool { didSet { defaults.set(firstRunStarted, forKey: "pref.firstRunStarted") } }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func choice<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        appearance = choice("pref.appearance", .system)
        showsMenuBarIcon = flag("pref.menuBarIcon", true)
        hidesFromScreenSharing = flag("pref.hideFromScreenSharing", true)
        panelPosition = choice("pref.panelPosition", .caret)
        previewDelay = choice("pref.previewDelay", .short)
        pasteDestination = choice("pref.pasteDestination", .app)
        alwaysPlainText = flag("pref.alwaysPlainText", false)
        retention = choice("pref.retention", .default)
        ignoredApps = defaults.stringArray(forKey: "pref.ignoredApps") ?? CaptureFilter.defaultIgnoredBundleIDs
        keepsRemoteCopies = flag("pref.keepRemoteCopies", true)
        showsExtensionOutputs = flag("pref.showExtensionOutputs", true)
        onboarded = flag("pref.onboarded", false)
        firstRunStarted = flag("pref.firstRunStarted", false)
    }
}
