import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization
@testable import YabUI

private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

@MainActor @Suite struct PanelCommandsTests {
    let library: Library
    let model: PanelViewModel
    let fake = FakeCommands()
    let base64ID: Int64
    let plainID: Int64

    init() throws {
        let store = try ItemStore.temporary()
        func ingest(_ text: String, minutesAgo: Double) throws -> Int64 {
            let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(text.utf8))]],
                                    source: nil, device: .local, capturedAt: now.addingTimeInterval(-minutesAgo * 60))
            return try #require(try store.ingest(clip)).item.id!
        }
        base64ID = try ingest("SGVsbG8sIGTDvG55YQ==", minutesAgo: 0.5)
        plainID = try ingest("merhaba dünya", minutesAgo: 1)
        library = try Library(store: store)
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-cmd-\(UUID().uuidString)")!)
        language.language = .turkish
        fake.generators = [FakeCommands.command("dev.yabbistir.uuid/v4", title: "UUID oluştur", keywords: ["uuid", "guid"], input: .none,
                                                extensionName: "UUID"),
                           FakeCommands.command("dev.yabbistir.uuid/v7", title: "UUID oluştur (v7)", keywords: ["uuid"], input: .none,
                                                extensionName: "UUID")]
        fake.transformsByItem[base64ID] = [FakeCommands.command("dev.yabbistir.base64/decode", title: "Base64 çöz", keywords: ["b64", "çöz"])]
        fake.transformsByItem[plainID] = [FakeCommands.command("dev.yabbistir.base64/encode", title: "Base64 kodla", keywords: ["b64", "kodla"])]
        model = PanelViewModel(library: library, language: language, extensions: fake, now: { now })
        library.onChange = { [model] in model.refresh() }
        model.reset()
    }

    var history: PanelColumn { model.columns.first { $0.id == .history }! }

    func type(_ text: String) { for character in text { _ = model.handle(.type(String(character))) } }

    @Test func twoLettersShowCommandsAboveHistory() {
        type("uu")
        #expect(history.sections.first?.title == "Komutlar")
        #expect(history.sections.first?.rows.map { $0.command?.commandID } == ["dev.yabbistir.uuid/v4", "dev.yabbistir.uuid/v7"])
        #expect(model.selectedCommand?.id == "dev.yabbistir.uuid/v4")
        #expect(model.selectedItemID == nil)
    }

    @Test func oneLetterShowsNoCommands() {
        type("u")
        #expect(history.sections.first?.title != "Komutlar")
        #expect(model.selectedCommand == nil)
    }

    @Test func theSubjectIsTheItemSelectedWhenTypingBegan() {
        _ = model.handle(.move(1))
        type("b6")
        #expect(model.subjectID == plainID)
        #expect(fake.queries.last?.subjectID == plainID)
    }

    @Test func typingRightAwayUsesTheLatestItem() {
        type("b6")
        #expect(model.subjectID == base64ID)
        #expect(history.sections.first?.rows.first?.command?.commandID == "dev.yabbistir.base64/decode")
    }

    @Test func returnOnACommandRunsIt() {
        type("uu")
        #expect(model.handle(.confirm(plain: false)) == .runCommand(commandID: "dev.yabbistir.uuid/v4", subjectID: base64ID, copy: false))
        #expect(model.handle(.pasteIndex(2)) == .runCommand(commandID: "dev.yabbistir.uuid/v7", subjectID: base64ID, copy: false))
    }

    @Test func commandCOnACommandCopiesItsOutput() {
        type("uu")
        #expect(model.handle(.copy) == .runCommand(commandID: "dev.yabbistir.uuid/v4", subjectID: base64ID, copy: true))
    }

    @Test func aRemovedExtensionsCommandLeavesTheOpenPanel() {
        type("uu")
        fake.generators = []
        model.refresh()
        #expect(!history.rows.contains { $0.command != nil })
        #expect(model.selectedCommand == nil)
    }

    @Test func clearingTheQueryForgetsTheSubject() {
        type("b6")
        _ = model.handle(.deleteBackward)
        _ = model.handle(.deleteBackward)
        #expect(model.subjectID == nil)
    }

    @Test func aTransformersPreviewShowsItsInputOutputAndLength() async throws {
        let command = FakeCommands.command("dev.yabbistir.base64/decode", title: "Base64 çöz", keywords: ["b64", "çöz"])
        fake.outputs[command.id] = .text("Hello, dünya")
        let content = await PreviewLoader.load(command: command, rowID: RowModel.commandIDBase, subjectID: base64ID, library: library,
                                               language: .turkish, extensions: fake)
        guard case .command(let preview) = content.body else { Issue.record("not a command preview"); return }
        guard case .text(let input)? = preview.input, case .text(let output) = preview.output else { Issue.record("not text"); return }
        #expect(input == "SGVsbG8sIGTDvG55YQ==")
        #expect(output == "Hello, dünya")
        #expect(content.info.map(\.label) == ["Uzantı", "Tür", "Anahtar kelimeler", "Uzunluk"])
        #expect(content.info.map(\.value) == ["Base64 · Yerleşik", "Dönüştürücü · seçili öğeye uygulanır", "", "20 → 12 karakter"])
        #expect(content.info[2].chips == ["b64", "çöz"])
    }

    /// Selecting a row never runs a command that has no hint; it runs when used.
    @Test func aTransformerWithoutAHintIsNotRunByItsPreview() async throws {
        let command = FakeCommands.command("dev.yabbistir.convert/ocr", title: "Metni oku", keywords: ["ocr"], hint: false)
        let content = await PreviewLoader.load(command: command, rowID: RowModel.commandIDBase, subjectID: plainID, library: library,
                                               language: .turkish, extensions: fake)
        guard case .command(let preview) = content.body, case .runsWhenUsed = preview.output else {
            Issue.record("the preview should say it runs when used")
            return
        }
        #expect(fake.outputCalls == 0)
    }

    @Test func aGeneratorsPreviewHasNoInputAndWaitsForItsValue() async throws {
        let command = fake.generators[0]
        let content = await PreviewLoader.load(command: command, rowID: RowModel.commandIDBase, subjectID: base64ID, library: library,
                                               language: .english, extensions: fake)
        guard case .command(let preview) = content.body else { Issue.record("not a command preview"); return }
        #expect(preview.input == nil)
        guard case .pending = preview.output else { Issue.record("a generator's preview never runs it"); return }
        #expect(content.info.map(\.value).prefix(2) == ["UUID · Built-in", "Generator · takes no input"])
        #expect(content.info.count == 3)
    }

    @Test func anImageFilesPreviewShowsThePicture() async throws {
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("yab-cmd-\(UUID().uuidString).png")
        let context = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.fileURL, data: Data(png.absoluteString.utf8))]],
                                source: nil, device: .local, capturedAt: now)
        let fileID = try #require(try library.store.ingest(clip)).item.id!
        let command = FakeCommands.command("dev.yabbistir.convert/ocr", title: "Metni oku", keywords: ["ocr"], extensionName: "Dönüştür")
        let content = await PreviewLoader.load(command: command, rowID: RowModel.commandIDBase, subjectID: fileID, library: library,
                                               language: .turkish, extensions: fake)
        guard case .command(let preview) = content.body, case .image(let image)? = preview.input else {
            Issue.record("the input is not the picture")
            return
        }
        #expect(image?.width == 64)
    }

    @Test func rowsShowTheirTags() throws {
        let tag = StoredTag(extensionID: "dev.yabbistir.base64", tag: "base64")
        fake.labels[tag] = "base64"
        try library.store.setTags([tag], for: base64ID, extensionID: "dev.yabbistir.base64")
        library.tagsChanged([base64ID])
        #expect(history.rows.first { $0.id == base64ID }?.tags == ["base64"])
        #expect(history.rows.first { $0.id == plainID }?.tags == [])
    }
}
