import Foundation
import Testing
import YabExtensionKit
import YabExtensions
import YabLocalization
import YabPasteboard
@testable import YabUI

/// A source that answers every run with `result`, and writes down what it was asked.
@MainActor
final class FakeSourceRunning: SourceRunning {
    var result: Result<SourceValue, ExtensionError>
    private(set) var runs: [[String]] = []

    init(_ result: Result<SourceValue, ExtensionError>) { self.result = result }

    func run(_ key: String, row: String, action: String) async throws(ExtensionError) -> SourceValue {
        runs.append([key, row, action])
        return try result.get()
    }
}

/// A clipboard that pastes with `outcome`, and writes down every paste and copy (with the give-back handed over).
@MainActor
final class FakeSensitivePasting: SensitivePasting {
    struct Paste: Equatable {
        let text: String
        let concealed: Bool
        let target: String?
    }

    var outcome: PasteOutcome = .pasted
    private(set) var pastes: [Paste] = []
    private(set) var copies: [String] = []
    private(set) var onlyIf: (() -> Bool)?
    private(set) var restoreInstead: (() -> Void)?

    func paste(_ text: String, concealed: Bool, targetBundleID: String?, onlyIf: (() -> Bool)?,
               restoreInstead: (() -> Void)?) async -> PasteOutcome {
        pastes.append(Paste(text: text, concealed: concealed, target: targetBundleID))
        self.onlyIf = onlyIf
        self.restoreInstead = restoreInstead
        return outcome
    }

    func copy(_ text: String) { copies.append(text) }
}

/// The one path a source's value takes: run, a blank check, then a concealed paste (a secret), a paste or a copy (text),
/// and the notice to show, which never carries the value. All values are synthetic.
@MainActor @Suite struct SourceRunnerTests {
    static let secret = "s3cr3t-örnek"
    static let target = "com.example.editor"
    static let vault = FakeSources.vault()

    func make(_ value: SourceValue, _ paste: FakeSensitivePasting = FakeSensitivePasting()) -> (SourceRunner, FakeSourceRunning, FakeSensitivePasting) {
        let sources = FakeSourceRunning(.success(value))
        return (SourceRunner(sources: sources, paste: paste), sources, paste)
    }

    func run(_ runner: SourceRunner, action: String = "password", copy: Bool = false, descriptor: SourceDescriptor = vault,
             restoreInstead: (() -> Void)? = nil) async -> NoticeKind? {
        await runner.run(descriptor, row: "7", action: action, copy: copy, target: Self.target, onlyIf: { true }, restoreInstead: restoreInstead)
    }

    @Test func aSecretIsPastedConcealed() async {
        let (runner, sources, paste) = make(.secret(Self.secret))
        #expect(await run(runner) == .sourcePasted)
        #expect(sources.runs == [[Self.vault.id, "7", "password"]])
        #expect(paste.pastes == [.init(text: Self.secret, concealed: true, target: Self.target)])
        #expect(paste.onlyIf?() == true)
        #expect(paste.copies.isEmpty)
    }

    /// Empty, or spaces and line ends only: nothing is pasted or copied, and the notice says so calmly.
    @Test func aBlankValueIsNeverPasted() async {
        let (secret, _, secretPaste) = make(.secret("  "))
        #expect(await run(secret) == .sourceEmpty)
        #expect(secretPaste.pastes.isEmpty)
        let (text, _, textPaste) = make(.text(" \n\t"))
        #expect(await run(text, action: "username") == .sourceEmpty)
        #expect(await run(text, action: "username", copy: true) == .sourceEmpty)
        #expect(textPaste.pastes.isEmpty)
        #expect(textPaste.copies.isEmpty)
        let (empty, _, emptyPaste) = make(.text(""))
        #expect(await run(empty, action: "username", copy: true) == .sourceEmpty)
        #expect(emptyPaste.copies.isEmpty)
    }

    /// A copy has no concealed path, so a secret never takes it: a secret action is not even run for ⌘C, and a value
    /// that comes back secret anyway is dropped.
    @Test func aSecretIsNeverCopied() async {
        let (runner, sources, paste) = make(.secret(Self.secret))
        #expect(await run(runner, copy: true) == nil)
        #expect(sources.runs.isEmpty)
        #expect(await run(runner, action: "username", copy: true) == nil)
        #expect(sources.runs == [[Self.vault.id, "7", "username"]])
        #expect(paste.pastes.isEmpty)
        #expect(paste.copies.isEmpty)
    }

    /// The username goes to the clipboard alone, as text (transient, never history), and the notice is the action's own
    /// words; without them, "Kopyalandı.".
    @Test func aTextCopyIsTransientAndSaysItsMessage() async {
        let (runner, _, paste) = make(.text("deniz.k"))
        let notice = await run(runner, action: "username", copy: true)
        #expect(notice == .sourceCopied(message: "Kullanıcı adı kopyalandı."))
        #expect(notice?.titleText(.turkish) == "Kullanıcı adı kopyalandı.")
        #expect(paste.copies == ["deniz.k"])
        #expect(paste.pastes.isEmpty)
        let plain = SourceDescriptor(extensionID: "dev.example.notlar", extensionName: "Notlar", sourceID: "notes", title: "Notlar",
                                     sensitive: false, actions: [
                                         SourceActionDescriptor(id: "body", kind: .text, title: "Notu yapıştır", label: "Not", copyTitle: "Notu kopyala"),
                                     ])
        let silent = await run(runner, action: "body", copy: true, descriptor: plain)
        #expect(silent == .sourceCopied(message: nil))
        #expect(silent?.titleText(.turkish) == "Kopyalandı.")
        #expect(silent?.titleText(.english) == "Copied.")
        // Pasted, the username says nothing: it is in the field.
        #expect(await run(runner, action: "username") == nil)
        #expect(paste.pastes == [.init(text: "deniz.k", concealed: false, target: Self.target)])
    }

    @Test func aFailedRunNamesTheExtension() async {
        let sources = FakeSourceRunning(.failure(ExtensionError(.script, "vault-cli: not logged in")))
        let paste = FakeSensitivePasting()
        let runner = SourceRunner(sources: sources, paste: paste)
        #expect(await run(runner) == .extensionFailed(name: "Kasa", message: "vault-cli: not logged in"))
        #expect(await run(runner, action: "username", copy: true) == .extensionFailed(name: "Kasa", message: "vault-cli: not logged in"))
        #expect(paste.pastes.isEmpty)
        #expect(paste.copies.isEmpty)
    }

    /// The person moved to another app before ⌘V: a secret says it was not pasted (and its clipboard is back already);
    /// text waits on the clipboard, as an item does. Without Accessibility a secret waits for ⌘V, for 30 seconds.
    @Test func aTargetThatLeftIsSaidPlainly() async {
        let left = FakeSensitivePasting()
        left.outcome = .copiedOnly(.targetLeft)
        let (secret, _, _) = make(.secret(Self.secret), left)
        #expect(await run(secret) == .sourceNotPasted)
        let (text, _, _) = make(.text("deniz.k"), left)
        #expect(await run(text, action: "username") == .copiedOnly)
        for reason in [CopiedOnlyReason.accessibilityDenied, .keyNotResolvable, .secureInput] {
            let paste = FakeSensitivePasting()
            paste.outcome = .copiedOnly(reason)
            let (secret, _, _) = make(.secret(Self.secret), paste)
            #expect(await run(secret) == .secretCopiedOnly)
        }
        for (reason, notice) in [(CopiedOnlyReason.accessibilityDenied, NoticeKind.accessibility), (.keyNotResolvable, .accessibility),
                                 (.secureInput, .secureInput)] {
            let paste = FakeSensitivePasting()
            paste.outcome = .copiedOnly(reason)
            let (text, _, _) = make(.text("deniz.k"), paste)
            #expect(await run(text, action: "username") == notice)
        }
    }

    /// Whatever happened, no notice's words (Turkish or English, title or line) hold the value.
    @Test func noNoticeCarriesTheValue() async {
        var notices: [NoticeKind] = []
        let outcomes: [PasteOutcome] = [.pasted, .copiedOnly(.targetLeft), .copiedOnly(.accessibilityDenied), .copiedOnly(.keyNotResolvable),
                                        .copiedOnly(.secureInput)]
        for value in [SourceValue.secret(Self.secret), .text(Self.secret)] {
            for outcome in outcomes {
                let paste = FakeSensitivePasting()
                paste.outcome = outcome
                let (runner, _, _) = make(value, paste)
                for (action, copy) in [("password", false), ("password", true), ("username", false), ("username", true)] {
                    if let notice = await run(runner, action: action, copy: copy) { notices.append(notice) }
                }
            }
        }
        let (runner, _, _) = make(.text(Self.secret))
        notices.append(runner.copyCommand("kasa login <e-posta>"))
        #expect(notices.contains(.sourcePasted))
        #expect(notices.contains(.sourceCopied(message: "Kullanıcı adı kopyalandı.")))
        for notice in notices {
            for language in [AppLanguage.turkish, .english] {
                #expect(!notice.titleText(language).contains("s3cr3t"))
                #expect(!notice.bodyText(language).contains("s3cr3t"))
            }
        }
    }

    /// With the Sıra open, the give-back is the Sıra's: it puts its own head back.
    @Test func theSiraTakesTheRestore() async {
        let (runner, _, paste) = make(.secret(Self.secret))
        var handed = 0
        _ = await run(runner, restoreInstead: { handed += 1 })
        paste.restoreInstead?()
        #expect(handed == 1)
        _ = await run(runner)
        #expect(paste.restoreInstead == nil)
    }

    /// The locked row's command goes to the clipboard as text, and the notice says what to do with it.
    @Test func theCommandIsCopied() {
        let (runner, sources, paste) = make(.text(""))
        #expect(runner.copyCommand("kasa login <e-posta>") == .sourceCommandCopied)
        #expect(paste.copies == ["kasa login <e-posta>"])
        #expect(sources.runs.isEmpty)
    }
}
