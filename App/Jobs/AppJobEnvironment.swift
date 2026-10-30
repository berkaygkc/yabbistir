import AppKit
import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization
import YabStack

/// What a finished job's result meets in the app (`JobCenter`'s environment): the app in front,
/// the panel, the Sıra, history and the clipboard. `JobCenter` decides where a result goes; this
/// does it.
@MainActor
final class AppJobEnvironment: JobEnvironment {
    private unowned let env: AppEnvironment
    private let stack: StackSession
    private let panelVisible: () -> Bool
    /// The app in front's bundle id (tests and previews could give their own).
    private let frontmost: () -> String?

    init(env: AppEnvironment, stack: StackSession, isPanelVisible: @escaping () -> Bool,
         frontmost: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) {
        self.env = env
        self.stack = stack
        self.panelVisible = isPanelVisible
        self.frontmost = frontmost
    }

    func frontmostBundleID() -> String? { frontmost() }

    var isPanelVisible: Bool { panelVisible() }

    var isStackOpen: Bool { stack.isOpen }

    /// As the panel's commands add theirs: from "yabbistir · <extension>". A file result names its
    /// file (or files); anything else is named as its history row is.
    func ingest(_ result: ExtensionResult, from command: ExtensionCommand) -> (itemID: Int64, name: String)? {
        var file: URL?
        if case .image(let data, let uti, let width, let height) = result {
            // An image is also a file, so Finder can take it (a job knows no subject to name it after).
            let name = ResultFiles.fileName(base: "", sourceSize: nil, width: width, height: height, uti: uti,
                                            fallback: L10n.string("extensions.result.image", env.language.language))
            file = try? env.resultFiles.write(data, named: name)
        }
        guard let item = env.ingestExtensionResult(ResultRepresentations.make(result, file: file), from: command.extensionName),
              let itemID = item.id else { return nil }
        let name: String
        switch result {
        case .file(let path): name = URL(fileURLWithPath: path).lastPathComponent
        case .files(let paths): name = paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        default: name = file?.lastPathComponent ?? item.previewText
        }
        return (itemID, name)
    }

    /// Into the app in front, which `JobCenter` has just found to be the job's target. That app is
    /// asked again right before ⌘V goes out (the paste waits a beat first): if the person switched
    /// apps or opened the panel meanwhile, nothing is typed and the result waits on the clipboard.
    func paste(_ itemID: Int64) async -> Bool {
        guard let target = frontmost(),
              let item = try? env.library.store.item(id: itemID),
              let representations = try? env.library.store.representations(of: itemID) else { return false }
        let outcome = await env.makePaster().paste(representations, kind: item.kind, targetBundleID: target, plainText: false,
                                                   onlyIf: { [frontmost, panelVisible] in frontmost() == target && !panelVisible() })
        guard outcome == .pasted else { return false }
        // A paste is a use, as from the panel: it renews retention and moves the item to the top.
        env.markUsed(itemID)
        if stack.isOpen {
            // As after any paste from the panel: the Sıra's head goes back on the clipboard once the target read it.
            try? await Task.sleep(for: stack.settleDuration)
            stack.restoreHead()
        }
        return true
    }

    /// Onto the clipboard the way the panel's ⌘C puts it there (not captured again as a new copy).
    func copy(_ itemID: Int64) {
        env.copyToClipboard(itemID)
    }

    func appendToStack(_ itemID: Int64) {
        stack.append(itemID)
    }

    func restoreStackHead() {
        stack.restoreHead()
    }

    /// Nothing more: the card shows the failure and keeps it until it is closed.
    func notifyFailure(_ job: JobCenter.Job) {}
}
