import AppKit
import ImageIO
import SwiftUI
import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization
import YabPasteboard
import YabPlatform
import YabStack
import YabUI

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let env: AppEnvironment
    private let stack: StackSession
    private let window = PanelWindow()
    private let model: PanelViewModel
    /// A source row's actions: the value pasted or copied without ever joining history.
    private let sourceRunner: SourceRunner
    private let notice = NoticeHUD()
    private let pinSurface = FloatingSurface(canBecomeKey: false)
    /// The ⇧ panel: beside the selected row like a submenu; the keyboard stays with the panel.
    private let transformSurface = FloatingSurface(canBecomeKey: false)
    private let previewSurface = FloatingSurface(canBecomeKey: false)
    private var previewContent: PreviewContent?
    /// What the loaded preview shows: "item:<id>", a command on its subject (with the hint
    /// revision, so a value that arrives later replaces the spinner), or a source's row as it is listed now.
    private var previewKey: String?
    private var previewSide: PreviewSide?
    private var previewLoad: Task<Void, Never>?
    /// The category editor takes keyboard focus while a name is edited.
    private let editorSurface = FloatingSurface(canBecomeKey: true)
    private lazy var editor = CategoryEditorModel(library: env.library, language: env.language, sources: env.sources)
    private var targetApp: NSRunningApplication?
    /// The app the panel opened for, as extensions see it; jobs started from this panel keep it.
    private var panelTarget: TargetInfo?
    /// The screen area the panel was placed in; width changes stay inside it.
    private var visibleFrame: CGRect = .zero
    /// The caret (or anchor) the panel was opened for; surfaces never cover it.
    private var caret: CGRect?
    /// The preview window's content and measured size, so moving it does not rebuild it.
    private var previewShown: (key: String, hints: Bool, size: CGSize)?

    init(env: AppEnvironment, stack: StackController) {
        self.env = env
        self.stack = stack.session
        model = PanelViewModel(library: env.library, language: env.language, stack: stack.session, extensions: env.extensions,
                               sources: env.sources)
        sourceRunner = SourceRunner(sources: env.sources, paste: env.sensitivePaste)
        super.init()
        // Installed, removed, turned on or off, or edited: the open panel's commands follow, after what the app does
        // first (a gone source's rows are forgotten).
        let appFollows = env.extensions.onExtensionsChanged
        env.extensions.onExtensionsChanged = { [weak self] in
            appFollows?()
            guard let self, window.isVisible else { return }
            model.refresh()
        }
        env.extensions.onExtensionTurnedOff = { [weak self] id in self?.extensionDisabled(id) }
        // A hidden panel rebuilds on its next show; refreshing it after every copy wasted the main thread.
        env.library.onChange = { [weak self] in
            guard let self, window.isVisible else { return }
            model.refresh()
        }
        stack.onChange = { [weak self] in
            guard let self, window.isVisible else { return }
            model.refresh()
        }
        window.delegate = self
        window.onCommand = { [weak self] in self?.handle($0) }
        window.showsShiftHint = { [weak self] in self?.model.showsShiftHint ?? false }
        window.contentView = PanelPresentation.host(PanelView(model: model, material: PanelMaterial.current) { [weak self] action in
            self?.perform(action)
        })
        observeWidth()
        observePin()
        observeTransforms()
        observePreview()
        editorSurface.delegate = self
        editorSurface.onCancel = { [weak self] in self?.closeEditor() }
        editorSurface.onKeyDown = { [weak self] in self?.handleEditorKey($0) ?? false }
        editorSurface.onKeyEquivalent = { [weak self] event in
            // ⌘N: a new category, selected and ready to name.
            guard let self, event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "n" else { return false }
            editor.addCategory()
            return true
        }
    }

    var isVisible: Bool { window.isVisible }

    /// The panel on screen while it is open: extensions' notices go over it then.
    var frameOnScreen: CGRect? { window.isVisible ? window.frame : nil }

    /// `anchor` (screen rect) stands in for the caret, e.g. the menu bar icon.
    func toggle(anchor: CGRect? = nil) {
        window.isVisible ? hide() : show(anchor: anchor)
    }

    func show(anchor: CGRect? = nil) {
        // Remember where the user was typing before we take focus.
        targetApp = NSWorkspace.shared.frontmostApplication
        panelTarget = targetApp?.bundleIdentifier.map { id in
            TargetInfo(bundleID: id, name: targetApp?.localizedName ?? id, kind: TargetClassifier.classify(bundleID: id))
        }
        // A new session: hints and generated values from the last one are forgotten. (Not on
        // hide: the command that closes the panel pastes the value its row showed.)
        env.extensions.resetSession()
        // Before the columns are built: the ⇧ panel and ⌘K lead with the target's own actions.
        env.extensions.target = panelTarget
        let anchor = anchor ?? CaretLocator.caretRect() ?? CaretLocator.mouseAnchor()
        caret = anchor
        visibleFrame = CaretLocator.visibleFrame(containing: anchor)
        model.availableWidth = visibleFrame.width - 2 * ColumnStripLayout.screenMargin
        // Columns are current before the width is used for placement (empty until the first show).
        model.refresh()
        let placed = PanelPlacement.place(
            panelSize: CGSize(width: model.sheetWidth, height: Tokens.Metrics.panelHeight),
            caret: anchor, visibleFrame: visibleFrame)

        model.panelHeight = placed.frame.height
        model.growAnchor = UnitPoint(x: min(1, max(0, (anchor.minX - placed.frame.minX) / placed.frame.width)),
                                     y: placed.opensAbove ? 1 : 0)
        PanelPresentation.show(window, frame: placed.frame, model: model)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(360))
            window.invalidateShadow()
        }
    }

    /// The panel's target goes with it, so extensions running meanwhile (detectors on a new copy)
    /// see none. A command that closes the panel takes the target (and the value its row showed)
    /// along before this.
    func hide() {
        pinSurface.hide()
        transformSurface.hide()
        hidePreview()
        editorSurface.hide()
        window.orderOut(nil)
        env.extensions.target = nil
    }

    /// Clicking another app closes the panel; moving focus into our own editor does not.
    /// Decided a turn later, when the new key window is known.
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            // Still ours (the editor, its color popover): keep the panel. Another app: close it.
            // Already hidden (a command closed it): nothing to close.
            guard let self, NSApp.keyWindow == nil, window.isVisible else { return }
            self.hide()
        }
    }

    // MARK: Category editor

    /// Beside the panel: left of it with a 12 pt gap, else right; with no room on either side it
    /// docks to the roomier side, 44 pt below the top of the screen.
    private func openEditor() {
        editor.reload()
        let content = CategoryEditorView(model: editor) { [weak self] in self?.closeEditor() }
        let size = editorSurface.fittingSize(of: content)
        let panel = window.frame
        let gap: CGFloat = 12
        var frame = CGRect(x: 0, y: panel.maxY - size.height, width: size.width, height: size.height)
        if panel.minX - gap - size.width >= visibleFrame.minX + gap {
            frame.origin.x = panel.minX - gap - size.width
        } else if panel.maxX + gap + size.width <= visibleFrame.maxX - gap {
            frame.origin.x = panel.maxX + gap
        } else {
            let roomLeft = panel.minX - visibleFrame.minX, roomRight = visibleFrame.maxX - panel.maxX
            frame.origin.x = roomLeft >= roomRight ? visibleFrame.minX + gap : visibleFrame.maxX - gap - size.width
            frame.origin.y = visibleFrame.maxY - 44 - size.height
        }
        frame.origin.y = max(visibleFrame.minY + gap, min(frame.origin.y, visibleFrame.maxY - gap - size.height))
        editorSurface.show(content, frame: frame, above: window)
        // Attention moves to the editor, so the keyboard does too; the preview steps aside.
        hidePreview()
        editorSurface.makeKey()
    }

    private func closeEditor() {
        editorSurface.hide()
        window.makeKey()
        updatePreview()
    }

    /// The editor's keys: ↑/↓ move between categories, ⇥ flips Always / On select, Esc closes;
    /// everything else (typing, ↵) goes to the selected category's name field.
    private func handleEditorKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 125: editor.moveSelection(by: 1)
        case 126: editor.moveSelection(by: -1)
        case 48: editor.toggleSelectedVisibility()
        case 53: closeEditor()
        default: return false
        }
        return true
    }

    private func handle(_ command: PanelCommand) {
        // The editor is the topmost surface: Esc closes it before anything in the panel.
        if command == .escape, editorSurface.isVisible {
            closeEditor()
            return
        }
        perform(model.handle(command))
    }

    private func perform(_ action: PanelAction?) {
        switch action {
        case .paste(let id, let plain): paste(id, plain: plain)
        case .copy(let id):
            hide()
            // A copy while the Sıra is open joins it, like any other copy; the head stays on the clipboard.
            if stack.isOpen { stack.append(id) } else { env.copyToClipboard(id) }
        case .close: hide()
        case .openEditor: openEditor()
        case .previewChanged, nil: break
        case .pasteFromStack(let entryID, let itemID, let plain): paste(itemID, plain: plain, stackEntry: entryID)
        // The panel stays open: several items can be queued in a row.
        case .addToStack(let itemID): stack.append(itemID)
        case .runCommand(let commandID, let subjectID, let copy): run(commandID, subjectID: subjectID, copy: copy)
        case .copyPlain(let id):
            hide()
            // The plain text goes to the clipboard alone, the Sıra open or not.
            env.copyToClipboard(id, plainTextOnly: true)
        case .runSource(let key, let row, let action, let copy): runSource(key, row: row, action: action, copy: copy)
        case .copySourceCommand(let command):
            let frame = window.frame
            hide()
            // Never history, and never the Sıra: it waits on the clipboard for the person's ⌘V in Terminal.
            notice.show(near: frame, language: env.language.language, kind: sourceRunner.copyCommand(command))
        }
    }

    // MARK: Sources

    /// The panel closes and the source's action runs for the app the panel opened for: a password is pasted
    /// concealed and the clipboard given back (to the Sıra's head while it is open), a username pasted or copied
    /// as text. Nothing joins history or counts as a use. What happened shows as a notice where the panel was.
    private func runSource(_ key: String, row: String, action: String, copy: Bool) {
        guard let descriptor = env.sources.descriptors.first(where: { $0.id == key }) else { return }
        let target = targetApp?.bundleIdentifier
        let frame = window.frame
        let onlyIf = stillThere(target)
        hide()
        Task { @MainActor in
            let restoreInstead: (() -> Void)? = stack.isOpen ? { [stack = self.stack] in stack.restoreHead() } : nil
            let kind = await sourceRunner.run(descriptor, row: row, action: action, copy: copy, target: target, onlyIf: onlyIf,
                                              restoreInstead: restoreInstead)
            if let kind { notice.show(near: frame, language: env.language.language, kind: kind) }
            // Text stays where a secret gives the clipboard back: with the Sıra open, its head goes back once the
            // target has read the paste, as after any other paste from the panel.
            let pastedText = kind == nil && !copy && descriptor.actions.first { $0.id == action }?.kind == .text
            if pastedText, stack.isOpen {
                try? await Task.sleep(for: stack.settleDuration)
                stack.restoreHead()
            }
        }
    }

    // MARK: Extension commands

    /// The panel closes, the command runs (a value its row already showed is used as is), and
    /// the result joins history from "yabbistir · <extension>", then is pasted or copied like
    /// any item. A failure says which extension and why, unless a language pack was offered for it
    /// (that notice, with its "Download", is the failure's); an answer that is only a message shows it.
    /// A job leaves for the job center and its card under the menu bar icon.
    private func run(_ commandID: String, subjectID: Int64?, copy: Bool) {
        guard let command = env.extensions.catalog.commands.first(where: { $0.id == commandID }) else { return }
        if command.isJob { return startJob(command, subjectID: subjectID, copy: copy) }
        let target = targetApp?.bundleIdentifier
        let frame = window.frame
        // Taken before the panel hides and lets its target go: the run is for the app the panel
        // opened for, and a value its row showed (a generator's UUID) is the value pasted.
        let (extensionTarget, shown) = (panelTarget, env.extensions.cachedOutput(of: command, subjectID: subjectID))
        let mark = env.hostCalls.mark(runOf: command.extensionID)
        hide()
        Task { @MainActor in
            let result: ExtensionResult
            do throws(ExtensionError) {
                if let shown { result = shown } else {
                    result = try await env.extensions.output(of: command, subjectID: subjectID, target: extensionTarget)
                }
            } catch {
                guard env.hostCalls.failureNeedsNotice(mark) else { return }
                notice.show(near: frame, language: env.language.language,
                            kind: .extensionFailed(name: command.extensionName, message: error.message))
                return
            }
            if case .none(let message?) = result, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                notice.show(near: frame, language: env.language.language, kind: .extensionMessage(name: command.extensionName, message: message))
                return
            }
            var file: URL?
            if case .image(let data, let uti, let width, let height) = result {
                // An image result is also a file, so Finder can take it; named after its subject.
                let store = env.library.store, files = env.resultFiles
                let fallback = L10n.string("extensions.result.image", env.language.language)
                file = await Task.detached(priority: .userInitiated) {
                    let subject = Self.imageSubject(subjectID, store: store)
                    let name = ResultFiles.fileName(base: subject.name ?? "", sourceSize: subject.size, width: width, height: height,
                                                    uti: uti, fallback: fallback)
                    return try? files.write(data, named: name)
                }.value
            }
            guard let item = env.ingestExtensionResult(ResultRepresentations.make(result, file: file), from: command.extensionName),
                  let itemID = item.id else { return }
            if copy {
                if stack.isOpen { stack.append(itemID) } else { env.copyToClipboard(itemID) }
            } else {
                await paste(itemID, plain: false, target: target, frame: frame)
            }
        }
    }

    /// The panel closes and the job starts for the app the panel opened for; ⌘C (`copy`) sends its
    /// result to the clipboard instead. Its card names the item as the panel's row did.
    private func startJob(_ command: ExtensionCommand, subjectID: Int64?, copy: Bool) {
        let target = panelTarget
        let summary = subjectID.flatMap { env.library.summaries(ids: [$0]).first }
        let title = summary.map { JobRowPresentation.subjectTitle(kind: $0.kind, previewText: $0.previewText) } ?? command.extensionName
        hide()
        env.jobs.start(command, subjectID: subjectID, subjectTitle: title, target: target, toClipboard: copy)
    }

    /// The subject's file name (without its extension) and pixel size, read from the file or the
    /// image's header; nil parts when the subject is neither.
    nonisolated private static func imageSubject(_ itemID: Int64?, store: ItemStore) -> (name: String?, size: CGSize?) {
        guard let itemID, let first = (try? store.representations(of: itemID))?.first else { return (nil, nil) }
        func size(_ source: CGImageSource?) -> CGSize? {
            guard let source, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            return CGSize(width: width, height: height)
        }
        if let raw = first.first(where: { $0.type == TypeIdentifiers.fileURL })?.data,
           let url = URL(string: String(decoding: raw, as: UTF8.self)) {
            return (url.deletingPathExtension().lastPathComponent, size(CGImageSourceCreateWithURL(url as CFURL, nil)))
        }
        let image = [TypeIdentifiers.png, TypeIdentifiers.tiff, TypeIdentifiers.jpeg, TypeIdentifiers.heic].lazy
            .compactMap { type in first.first { $0.type == type }?.data }.first
        return (nil, size(image.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }))
    }

    private func extensionDisabled(_ id: String) {
        let name = env.extensionRegistry.installed.first { $0.id == id }?.name(language: env.language.language.rawValue) ?? id
        // A detector can fail while the panel is closed (or before it ever opened): then the
        // notice sits at the top right of the screen, under the menu bar.
        var frame = window.frame
        if !window.isVisible || frame.isEmpty, let screen = NSScreen.main?.visibleFrame {
            frame = CGRect(x: screen.maxX - 420, y: screen.maxY - 12, width: 0, height: 0)
        }
        notice.show(near: frame, language: env.language.language, kind: .extensionDisabled(name: name))
    }

    /// The ⇧ panel follows the selected row, the filter, arriving outputs and a new ⇧↵ default (the
    /// rows read it; they re-sort under "Varsayılan", so the panel's height can change) while it is open.
    private func observeTransforms() {
        withObservationTracking {
            _ = model.layer
            _ = model.selectedRowFrame
            _ = model.transformRows.count
            _ = model.transformQuery
            _ = model.menuSelection
            _ = model.hintRevision
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateTransforms()
                self?.observeTransforms()
            }
        }
    }

    /// Like a submenu: its left edge 12 pt inside the column's right edge, or flipped to the
    /// column's left when the screen runs out; its top 8 pt above the row, kept on screen.
    private func updateTransforms() {
        guard window.isVisible, model.layer == .transforms, let row = screenRect(of: model.selectedRowFrame) else {
            transformSurface.hide()
            return
        }
        let content = TransformPanelView(model: model) { [weak self] action in self?.perform(action) }
        let size = transformSurface.fittingSize(of: content)
        let column = columnRect()
        var x = column.maxX - 12
        if x + size.width > visibleFrame.maxX - 12 { x = column.minX - size.width + 12 }
        x = max(visibleFrame.minX + 12, min(x, visibleFrame.maxX - 12 - size.width))
        var y = row.maxY + 8 - size.height
        y = max(visibleFrame.minY + 12, min(y, visibleFrame.maxY - 12 - size.height))
        transformSurface.show(content, frame: CGRect(x: x, y: y, width: size.width, height: size.height), above: window)
    }

    /// The focused column on screen.
    private func columnRect() -> CGRect {
        let index = max(0, model.focusedColumn - model.firstVisibleColumn)
        let panel = window.frame
        return CGRect(x: panel.minX + CGFloat(index) * ColumnStripLayout.columnWidth, y: panel.minY,
                      width: ColumnStripLayout.columnWidth, height: panel.height)
    }

    /// ⌘P opens beside the selected row (left edge 40 pt inside the row's right end, top 6 pt
    /// below its top), kept 12 pt inside the screen; it follows the row while open.
    private func observePin() {
        withObservationTracking {
            _ = model.layer
            _ = model.selectedRowFrame
            _ = model.pinOptions.count
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updatePin()
                self?.observePin()
            }
        }
    }

    private func updatePin() {
        guard window.isVisible, model.layer == .pin, let row = screenRect(of: model.selectedRowFrame) else {
            pinSurface.hide()
            return
        }
        let content = PinPopoverView(model: model)
        let size = pinSurface.fittingSize(of: content)
        var x = min(row.maxX - 40, visibleFrame.maxX - 12 - size.width)
        x = max(x, visibleFrame.minX + 12)
        var y = row.maxY - 6 - size.height
        y = max(y, visibleFrame.minY + 12)
        pinSurface.show(content, frame: CGRect(x: x, y: y, width: size.width, height: size.height), above: window)
    }

    // MARK: Preview

    /// The preview follows the selection (also across search and column changes) and the list's
    /// scrolling while it is open.
    private func observePreview() {
        withObservationTracking {
            _ = model.isPreviewVisible
            _ = model.previewSource
            _ = model.selectedItemID
            _ = model.selectedID
            _ = model.selectedSourceRow
            _ = model.hintRevision
            _ = model.selectedRowFrame
            _ = model.focusedColumn
            _ = model.firstVisibleColumn
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updatePreview()
                self?.observePreview()
            }
        }
    }

    /// The selection's preview: an item, a command row's input and output, or a source's row.
    private func updatePreview() {
        guard window.isVisible, !editorSurface.isVisible, model.isPreviewVisible else {
            hidePreview()
            return
        }
        if let source = model.selectedSourceRow {
            showSourcePreview(source)
            return
        }
        let command = model.selectedCommand
        let subjectID = model.subjectID
        let key: String
        if let command, let rowID = model.selectedID {
            key = "command:\(command.id)|\(subjectID ?? 0)|\(model.hintRevision)|\(rowID)"
        } else if let id = model.selectedItemID {
            key = "item:\(id)"
        } else {
            hidePreview()
            return
        }
        guard previewKey != key else {
            placePreview()
            return
        }
        let itemID = model.selectedItemID, rowID = model.selectedID
        previewLoad?.cancel()
        previewLoad = Task { @MainActor [weak self] in
            // Holding ↓ through big items: load only once the selection settles.
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            let content: PreviewContent?
            if let command, let rowID {
                content = await PreviewLoader.load(command: command, rowID: rowID, subjectID: subjectID, library: env.library,
                                                   language: env.language.language, extensions: env.extensions)
            } else if let itemID {
                content = await PreviewLoader.load(itemID: itemID, library: env.library, language: env.language.language,
                                                   extensions: env.extensions)
            } else {
                content = nil
            }
            guard !Task.isCancelled, model.selectedID == rowID, model.selectedCommand?.id == command?.id else { return }
            previewContent = content
            previewKey = key
            placePreview()
        }
    }

    /// A source's row previews what it shows, made at once from the row: the source is never asked for its value.
    private func showSourcePreview(_ source: SourceRowInfo) {
        guard let descriptor = model.selectedSourceDescriptor, let rowID = model.selectedID else {
            hidePreview()
            return
        }
        // A list that renames the row or locks the source changes what it shows, under the same id.
        let key = "source:\(rowID)|\(source.hashValue)"
        guard previewKey != key else {
            placePreview()
            return
        }
        previewLoad?.cancel()
        previewContent = PreviewLoader.load(source: source, descriptor: descriptor, language: env.language.language)
        previewKey = key
        placePreview()
    }

    private func placePreview() {
        guard let content = previewContent, model.isPreviewVisible, !editorSurface.isVisible else {
            hidePreview()
            return
        }
        let language = env.language.language
        let showsHints = model.previewSource == .keyboard
        let key = previewKey ?? ""
        let isSame = previewShown?.key == key && previewShown?.hints == showsHints && previewSurface.isVisible
        let size = isSame ? previewShown!.size
            : previewSurface.fittingSize(of: PreviewView(content: content, language: language, showsHints: showsHints, measuring: true))
        let index = max(0, model.focusedColumn - model.firstVisibleColumn)
        let panel = window.frame
        let column = columnRect()
        let placed = PreviewPlacement.place(panel: panel, column: column, row: screenRect(of: model.selectedRowFrame), caret: caret,
                                            columnIndex: index, visibleColumns: model.visibleColumnCount,
                                            size: size, visibleFrame: visibleFrame)
        if isSame {
            // Only the position changed (scrolling, a wider panel): move the window, keep the view.
            if previewSurface.frame != placed.frame { previewSurface.setFrame(placed.frame, display: true) }
        } else {
            let view = PreviewView(content: content, language: language, showsHints: showsHints) { [weak self] inside in
                self?.model.pointer(inPreview: inside)
            }
            // A new side (or a first appearance) fades in; moving along the same side does not.
            let fades = previewSide != placed.side && !Tokens.Motion.reduceMotion()
            if fades { previewSurface.alphaValue = 0 }
            previewSurface.show(view, frame: placed.frame, above: window)
            if fades {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    previewSurface.animator().alphaValue = 1
                }
            } else {
                previewSurface.alphaValue = 1
            }
            previewShown = (key, showsHints, size)
        }
        previewSide = placed.side
    }

    private func hidePreview() {
        previewLoad?.cancel()
        previewSurface.hide()
        previewContent = nil
        previewKey = nil
        previewSide = nil
        previewShown = nil
    }

    /// A rectangle in the panel's SwiftUI coordinates (top-left origin) on screen (Cocoa, bottom-left).
    private func screenRect(of rect: CGRect?) -> CGRect? {
        guard let rect else { return nil }
        let frame = window.frame
        return CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Any change of the sheet's width (keys, menu clicks, library changes) resizes the window.
    private func observeWidth() {
        withObservationTracking { _ = model.sheetWidth } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncWidth()
                self?.observeWidth()
            }
        }
    }

    /// Opening or closing a column widens or narrows the panel by whole columns; the surfaces
    /// beside it follow once the new width is reached.
    private func syncWidth() {
        PanelPresentation.fitWidth(window, model: model, visibleFrame: visibleFrame) { [weak self] in
            self?.updatePin()
            self?.updateTransforms()
            self?.placePreview()
        }
    }

    /// `stackEntry`: a Sıra row pasted out of order; it leaves the stack once pasted. Any other
    /// paste while the Sıra is open puts the stack's head back on the clipboard afterwards.
    private func paste(_ itemID: Int64, plain: Bool, stackEntry: Int? = nil) {
        let target = targetApp?.bundleIdentifier
        let frame = window.frame
        hide()
        Task { @MainActor in await paste(itemID, plain: plain, stackEntry: stackEntry, target: target, frame: frame) }
    }

    private func paste(_ itemID: Int64, plain: Bool, stackEntry: Int? = nil, target: String?, frame: CGRect) async {
        guard let item = try? env.library.store.item(id: itemID),
              let representations = try? env.library.store.representations(of: itemID) else { return }
        let outcome = await env.makePaster().paste(representations, kind: item.kind, targetBundleID: target, plainText: plain,
                                                   onlyIf: stillThere(target))
        env.markUsed(itemID)
        switch outcome {
        case .pasted:
            if let stackEntry {
                stack.pastedFromPanel(entryID: stackEntry)
            } else if stack.isOpen {
                try? await Task.sleep(for: stack.settleDuration)
                stack.restoreHead()
            }
        case .copiedOnly(let reason):
            // The item stays on the clipboard for the user's own ⌘V.
            let kind: NoticeKind
            switch reason {
            case .secureInput: kind = .secureInput
            case .accessibilityDenied, .keyNotResolvable: kind = .accessibility
            case .targetLeft: kind = .copiedOnly
            }
            notice.show(near: frame, language: env.language.language, kind: kind)
        }
    }

    /// Asked right before ⌘V, as for a job: if the person switched apps (or the panel is back) during the
    /// beat, nothing is typed and the value waits on the clipboard.
    private func stillThere(_ target: String?) -> (() -> Bool)? {
        target.map { target in
            { [weak self] in NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target && self?.window.isVisible != true }
        }
    }
}
