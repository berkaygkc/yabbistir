import SwiftUI
import YabImport
import YabLocalization

/// Settings → Import: a summary of the other library, a choice of what to bring, progress and the result.
public struct ImportSettingsView: View {
    let model: ImportModel
    let presence: SettingsPresence

    public init(model: ImportModel, presence: SettingsPresence) {
        self.model = model
        self.presence = presence
    }

    public var body: some View {
        Form {
            switch model.state {
            case .scanning:
                Section { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
            case .unavailable:
                Section { note("import.none") }
            case .failed:
                Section { note("import.error") }
            case .ready(let summary, _):
                source
                choice(summary)
            case .importing(let progress):
                source
                progressSection(progress)
            case .done:
                resultSection
            }
            if model.otherAppRunning { running }
        }
        .formStyle(.grouped)
        .navigationTitle(string("settings.section.import"))
        .task(id: presence.isVisible) {
            guard presence.isVisible else { return }
            model.refreshOtherApp()
            if case .scanning = model.state { await model.scan() }
            // Polls only while the window is on screen, so the running notice goes away once the app quits.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.refreshOtherApp()
            }
        }
    }

    // MARK: Sections

    private var source: some View {
        Section {
            LabeledContent {
                Text(model.statsLine).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            } label: {
                Text(model.sourceLine).font(.headline)
            }
            note("import.body")
        }
    }

    private func choice(_ summary: PasteSummary) -> some View {
        @Bindable var model = model
        return Section {
            Toggle(isOn: $model.selection.history) {
                LabeledContent(string("import.allHistory")) {
                    Text(model.historyCountText()).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            ForEach(summary.boards) { board in
                Toggle(isOn: Binding(
                    get: { model.selection.boards.contains(board.id) },
                    set: { on in
                        if on { model.selection.boards.insert(board.id) } else { model.selection.boards.remove(board.id) }
                    })) {
                    LabeledContent(board.name) {
                        Text(model.boardCountText(board)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            if !model.noteLine.isEmpty {
                Text(model.noteLine).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Button(string("import.start")) { model.start() }
                .disabled(!model.selection.history && model.selection.boards.isEmpty)
        }
    }

    private func progressSection(_ progress: ImportProgress) -> some View {
        Section {
            Text(string("import.progress.title")).font(.headline)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            HStack(spacing: 4) {
                Text(model.number(progress.done)).monospacedDigit()
                Text(L10n.string("import.progress.of", model.language.language, model.number(progress.total))).monospacedDigit()
            }
            .font(.callout).foregroundStyle(.secondary)
            note("import.progress.body")
        }
    }

    private var resultSection: some View {
        Section {
            Text(string("import.done.title")).font(.headline)
            Text(model.resultLine).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            if let failed = model.failedLine {
                Text(failed).font(.callout).foregroundStyle(.orange).monospacedDigit()
            }
        }
    }

    private var running: some View {
        Section {
            Text(string("import.running.title")).font(.headline)
            note("import.running.body")
            Button(string("import.running.quit")) { model.quitOtherApp() }
        }
    }

    private func string(_ key: String) -> String { L10n.string(key, model.language.language) }

    private func note(_ key: String) -> some View {
        Text(string(key)).font(.callout).foregroundStyle(.secondary)
    }
}
