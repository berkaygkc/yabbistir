import Foundation
import Testing
@testable import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization
@testable import YabUI

private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

@MainActor @Suite struct TransformPanelTests {
    let model: PanelViewModel
    let fake = FakeCommands()
    let base64ID: Int64
    let plainID: Int64
    let colorID: Int64
    /// Text that also carries RTF.
    let richID: Int64
    let linkID: Int64
    let defaults: ShiftReturnDefaults

    init() throws {
        let store = try ItemStore.temporary()
        func ingest(_ text: String, minutesAgo: Double, rtf: Bool = false) throws -> Int64 {
            let plain = PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(text.utf8))
            let reps = rtf ? [plain, PasteboardRepresentation(type: TypeIdentifiers.rtf, data: Data("{\\rtf1 \(text)}".utf8))] : [plain]
            let clip = CapturedClip(items: [reps], source: nil, device: .local, capturedAt: now.addingTimeInterval(-minutesAgo * 60))
            return try #require(try store.ingest(clip)).item.id!
        }
        base64ID = try ingest("SGVsbG8sIGTDvG55YQ==", minutesAgo: 0.5)
        plainID = try ingest("merhaba dünya", minutesAgo: 1)
        colorID = try ingest("#6E56CF", minutesAgo: 2)
        richID = try ingest("Perşembe toplantısı\niade akışı demosu", minutesAgo: 3, rtf: true)
        linkID = try ingest("https://ornek.dev/rapor", minutesAgo: 4)
        let library = try Library(store: store)
        let suite = try #require(UserDefaults(suiteName: "yab-xform-\(UUID().uuidString)"))
        let language = LanguageStore(defaults: suite)
        language.language = .turkish
        defaults = ShiftReturnDefaults(defaults: suite)
        fake.transformsByItem[base64ID] = [FakeCommands.command("dev.yabbistir.base64/decode", title: "Base64 çöz", keywords: ["b64", "çöz"]),
                                           FakeCommands.command("dev.yabbistir.base64/encode", title: "Base64 kodla", keywords: ["b64", "kodla"])]
        fake.transformsByItem[colorID] = ["rgb", "hsl", "oklch", "swiftui", "nscolor"].map {
            FakeCommands.command("dev.yabbistir.convert/color#\($0)", title: "\($0.uppercased()) olarak", keywords: ["renk", $0],
                                 extensionName: "Dönüştür")
        }
        model = PanelViewModel(library: library, language: language, extensions: fake, now: { now }, shiftDefaults: defaults)
        model.reset()
    }

    func select(_ id: Int64) { model.select(id, in: .history) }

    @Test func shiftTapOpensTransforms() {
        _ = model.handle(.toggleTransforms)
        #expect(model.layer == .transforms)
        #expect(model.transformSubjectID == base64ID)
        #expect(model.transformRows.map(\.id) == ["dev.yabbistir.base64/decode", "dev.yabbistir.base64/encode"])
        #expect(fake.hintRequests == 1)
    }

    @Test func noTransformsNudges() {
        select(plainID)
        let nudges = model.edgeNudge
        _ = model.handle(.toggleTransforms)
        #expect(model.layer == .none)
        #expect(model.edgeNudge == nudges + 1)
    }

    @Test func typingFiltersTransforms() {
        _ = model.handle(.toggleTransforms)
        for character in "kod" { _ = model.handle(.type(String(character))) }
        #expect(model.transformQuery == "kod")
        #expect(model.transformRows.map(\.id) == ["dev.yabbistir.base64/encode"])
        #expect(model.query.isEmpty)
    }

    @Test func returnRunsTheSelectedTransform() {
        _ = model.handle(.toggleTransforms)
        #expect(model.handle(.confirm(plain: false)) == .runCommand(commandID: "dev.yabbistir.base64/decode", subjectID: base64ID, copy: false))
        #expect(model.layer == .none)
    }

    @Test func commandCCopiesTheSelectedTransform() {
        _ = model.handle(.toggleTransforms)
        _ = model.handle(.move(1))
        #expect(model.handle(.copy) == .runCommand(commandID: "dev.yabbistir.base64/encode", subjectID: base64ID, copy: true))
    }

    @Test func leftArrowClosesTransforms() {
        _ = model.handle(.toggleTransforms)
        _ = model.handle(.moveColumn(-1))
        #expect(model.layer == .none)
        _ = model.handle(.toggleTransforms)
        _ = model.handle(.toggleTransforms)
        #expect(model.layer == .none)
        _ = model.handle(.toggleTransforms)
        _ = model.handle(.escape)
        #expect(model.layer == .none)
    }

    @Test func thePreviewHidesWhileTransformsAreOpen() {
        _ = model.handle(.togglePreview)
        #expect(model.isPreviewVisible)
        _ = model.handle(.toggleTransforms)
        #expect(!model.isPreviewVisible)
        _ = model.handle(.escape)
        #expect(model.isPreviewVisible)
    }

    @Test func transformsAreGroupedByExtension() {
        fake.transformsByItem[plainID] = [FakeCommands.command("a.one/x", title: "X", keywords: ["x"], extensionName: "A"),
                                          FakeCommands.command("b.two/y", title: "Y", keywords: ["y"], extensionName: "B"),
                                          FakeCommands.command("a.one/z", title: "Z", keywords: ["z"], extensionName: "A")]
        select(plainID)
        _ = model.handle(.toggleTransforms)
        #expect(model.transformRows.map(\.id) == ["a.one/x", "a.one/z", "b.two/y"])
    }

    @Test func actionsShowTopThreeAndAll() {
        select(colorID)
        _ = model.handle(.toggleActions)
        let transforms = model.actionItems.filter { if case .transform = $0 { true } else { false } }
        #expect(transforms.count == 3)
        #expect(model.actionItems.contains(.allTransforms))
        #expect(model.actionLabel(.allTransforms) == "Tüm dönüşümler (5)…")
        #expect(model.actionLabel(.transform("dev.yabbistir.convert/color#rgb")) == "RGB olarak")
        #expect(Array(model.actionItems.prefix(3)) == [.paste, .copy, .addToStack])
    }

    @Test func actionsFindTransformsByKeyword() {
        select(colorID)
        _ = model.handle(.toggleActions)
        for character in "oklc" { _ = model.handle(.type(String(character))) }
        #expect(model.actionItems == [.transform("dev.yabbistir.convert/color#oklch")])
        #expect(model.handle(.confirm(plain: false)) == .runCommand(commandID: "dev.yabbistir.convert/color#oklch", subjectID: colorID, copy: false))
    }

    @Test func allTransformsOpensThePanel() {
        select(colorID)
        _ = model.handle(.toggleActions)
        for character in "tüm" { _ = model.handle(.type(String(character))) }
        _ = model.handle(.confirm(plain: false))
        #expect(model.layer == .transforms)
        #expect(model.transformRows.count == 5)
    }

    @Test func aTransformWithoutAHintWaitsToBeUsed() throws {
        fake.transformsByItem[plainID] = [FakeCommands.command("dev.yabbistir.convert/ocr", title: "Metni oku", keywords: ["ocr"], hint: false)]
        select(plainID)
        _ = model.handle(.toggleTransforms)
        guard case .command(let command)? = model.transformRows.first else { Issue.record("no command row"); return }
        #expect(!model.transformRunsAhead(command))
        select(base64ID)
    }

    // MARK: The paste target

    static let finder = TargetInfo(bundleID: "com.apple.finder", name: "Finder", kind: .finder)

    /// A synthetic download job made for Finder.
    static let download = FakeCommands.command("dev.example.download/video", title: "Video olarak indir", keywords: ["indir"],
                                                extensionName: "Video İndir", hint: false, icon: "sf:film", subtitle: "MP4 · 1080p",
                                                output: .file, targets: [.finder], isJob: true, verb: "İndir")

    /// The provider's order puts the download last; the panel still leads with it.
    func offerTheDownload() {
        fake.transformsByItem[base64ID, default: []].append(Self.download)
    }

    @Test func theFinderSectionLeadsTheShiftPanel() {
        fake.target = Self.finder
        offerTheDownload()
        _ = model.handle(.toggleTransforms)
        #expect(model.transformSections.first?.title == "Finder’a")
        #expect(model.transformSections.map(\.title) == ["Finder’a", "Base64"])
        #expect(model.transformRows.map(\.id) == ["dev.example.download/video", "dev.yabbistir.base64/decode", "dev.yabbistir.base64/encode"])
        // Another app is named.
        fake.target = TargetInfo(bundleID: "dev.zed.Zed", name: "Zed", kind: .editor)
        fake.transformsByItem[base64ID]?[2] = FakeCommands.command("dev.example.zed/open", title: "Zed’de aç", keywords: ["zed"],
                                                                   extensionName: "Zed", targets: [.editor])
        _ = model.handle(.escape)
        _ = model.handle(.toggleTransforms)
        #expect(model.transformSections.first?.title == "Zed için")
        // With no target, the download is one extension among the others.
        fake.target = nil
        _ = model.handle(.escape)
        _ = model.handle(.toggleTransforms)
        #expect(model.transformSections.map(\.title) == ["Base64", "Zed"])
    }

    @Test func commandKLeadsWithTargetActions() {
        fake.target = Self.finder
        offerTheDownload()
        _ = model.handle(.toggleActions)
        #expect(model.actionItems.first == .transform("dev.example.download/video"))
        #expect(Array(model.actionItems.prefix(4)) == [.transform("dev.example.download/video"), .paste, .copy, .addToStack])
        #expect(model.isForTarget(.transform("dev.example.download/video")))
        #expect(!model.isForTarget(.transform("dev.yabbistir.base64/decode")))
    }

    @Test func theFooterNamesTheVerb() {
        fake.target = Self.finder
        offerTheDownload()
        _ = model.handle(.toggleTransforms)
        #expect(model.transformKeyLabels.confirm == "İndir")
        #expect(model.transformKeyLabels.copy == "İndir ve kopyala")
        _ = model.handle(.move(1))
        #expect(model.transformKeyLabels.confirm == "Yapıştır")
        #expect(model.transformKeyLabels.copy == "Kopyala")
        // A job without a verb starts.
        fake.transformsByItem[base64ID] = [FakeCommands.command("dev.example.job/run", title: "Çalıştır", keywords: ["iş"], hint: false, isJob: true)]
        _ = model.handle(.escape)
        _ = model.handle(.toggleTransforms)
        #expect(model.transformKeyLabels.confirm == "Başlat")
        #expect(model.transformKeyLabels.copy == "Başlat ve kopyala")
    }

    /// The file strip says where the file goes, without naming Finder's folder;
    /// for any other app ↵ pastes the file into it, so the strip says so.
    @Test func aFileResultSaysWhereItGoes() {
        offerTheDownload()
        _ = model.handle(.toggleTransforms)
        #expect(model.transformFileDestination == "Dosya olarak yapıştırılır")
        _ = model.handle(.escape)
        fake.target = Self.finder
        _ = model.handle(.toggleTransforms)
        #expect(model.transformFileDestination == "Açık Finder klasörüne")
    }

    @Test func theFooterKnowsWhenThereAreTransforms() {
        #expect(model.selectedTransformCount == 2)
        select(plainID)
        #expect(model.selectedTransformCount == 0)
    }

    // MARK: ⇧↵

    /// A synthetic transform that accepts any text.
    static let b64 = FakeCommands.command("fake.ext/b64", title: "Base64 kodla", keywords: ["b64"])

    func isShiftReturn(_ item: PanelActionItem) -> Bool {
        ActionMenuView.keys(item, shiftReturn: model.shiftReturnItem) == ["⇧", "↵"]
    }

    @Test func shiftReturnOnRichTextPastesPlain() {
        select(richID)
        #expect(model.shiftReturnAction == .plainText)
        #expect(model.handle(.confirm(plain: true)) == .paste(itemID: richID, plain: true))
    }

    /// A transform that accepts the link is never run by ⇧↵ unless the user made it the default.
    @Test func shiftReturnOnALinkPastesItAsIs() {
        fake.transformsByItem[linkID] = [Self.b64]
        select(linkID)
        #expect(model.shiftReturnAction == .paste)
        #expect(model.handle(.confirm(plain: true)) == .paste(itemID: linkID, plain: false))
    }

    @Test func shiftReturnRunsThePinnedDefault() {
        fake.transformsByItem[plainID] = [Self.b64]
        defaults.pin("fake.ext/b64", for: .text)
        select(plainID)
        #expect(model.handle(.confirm(plain: true)) == .runCommand(commandID: "fake.ext/b64", subjectID: plainID, copy: false))
    }

    @Test func removingThePinnedExtensionFallsBack() {
        fake.transformsByItem[plainID] = [Self.b64]
        defaults.pin("fake.ext/b64", for: .text)
        select(plainID)
        #expect(model.handle(.confirm(plain: true)) == .runCommand(commandID: "fake.ext/b64", subjectID: plainID, copy: false))
        fake.transformsByItem[plainID] = nil
        #expect(model.handle(.confirm(plain: true)) == .paste(itemID: plainID, plain: false))
    }

    /// No item behind a command row: ⇧↵ runs it like ↵.
    @Test func shiftReturnOnACommandRowRunsIt() throws {
        fake.generators = [FakeCommands.command("dev.yabbistir.uuid/v4", title: "UUID oluştur", keywords: ["uuid"], input: .none,
                                                extensionName: "UUID")]
        for character in "uuid" { _ = model.handle(.type(String(character))) }
        let row = try #require(model.columns[0].rows.first)
        #expect(row.command != nil)
        #expect(model.shiftReturnAction == nil)
        #expect(model.handle(.confirm(plain: true)) == model.handle(.confirm(plain: false)))
    }

    @Test func theShiftPanelLeadsWithPlainTextForRichText() {
        fake.transformsByItem[richID] = [Self.b64]
        select(richID)
        _ = model.handle(.toggleTransforms)
        #expect(model.transformRows.first == .plainText)
        #expect(model.transformRows.map(\.id) == [ShiftReturn.plainTextID, "fake.ext/b64"])
        #expect(model.transformSections.first?.title == "yabbistir")
        #expect(model.transformSections.first?.mark == .app)
        #expect(model.transformSections.map(\.title) == ["yabbistir", "Base64"])
    }

    /// Rich text with no transforms still has the plain-text row, so ⇧ opens on it.
    @Test func plainTextAloneOpensTheShiftPanel() {
        select(richID)
        #expect(model.selectedTransformCount == 1)
        _ = model.handle(.toggleTransforms)
        #expect(model.layer == .transforms)
        #expect(model.transformRows == [.plainText])
    }

    @Test func aPinnedDefaultLeadsUnderDefault() {
        fake.transformsByItem[richID] = [Self.b64]
        defaults.pin("fake.ext/b64", for: .text)
        select(richID)
        _ = model.handle(.toggleTransforms)
        #expect(model.transformRows.map(\.id) == ["fake.ext/b64", ShiftReturn.plainTextID])
        #expect(model.transformRows[1] == .plainText)
        #expect(model.transformSections.first?.title == "Varsayılan")
        #expect(model.transformSections.first?.mark == .pinned)
        #expect(model.transformSections.map(\.title) == ["Varsayılan", "yabbistir"])
    }

    /// A default the item does not take leaves the order as it was, with no "Varsayılan".
    @Test func aDefaultThatDoesNotApplyLeavesTheOrder() {
        defaults.pin("dev.yabbistir.base64/encode", for: .color)
        _ = model.handle(.toggleTransforms)
        #expect(model.transformRows.map(\.id) == ["dev.yabbistir.base64/decode", "dev.yabbistir.base64/encode"])
        #expect(model.transformSections.map(\.title) == ["Base64"])
    }

    @Test func plainTextIsOfferedOnlyForRichText() {
        select(richID)
        _ = model.handle(.toggleActions)
        #expect(model.actionItems.contains(.pastePlain))
        _ = model.handle(.escape)
        select(plainID)
        _ = model.handle(.toggleActions)
        #expect(!model.actionItems.contains(.pastePlain))
    }

    @Test func commandKMarksWhatShiftReturnRuns() {
        fake.transformsByItem[richID] = [Self.b64]
        select(richID)
        _ = model.handle(.toggleActions)
        #expect(isShiftReturn(.pastePlain))
        #expect(!isShiftReturn(.transform("fake.ext/b64")))
        _ = model.handle(.escape)
        defaults.pin("fake.ext/b64", for: .text)
        _ = model.handle(.toggleActions)
        #expect(model.shiftReturnItem == .transform("fake.ext/b64"))
        #expect(isShiftReturn(.transform("fake.ext/b64")))
        #expect(!isShiftReturn(.pastePlain))
        #expect(ActionMenuView.keys(.paste, shiftReturn: model.shiftReturnItem) == ["↵"])
        // ⇧↵ pastes like ↵ on the link: no row carries it.
        _ = model.handle(.escape)
        fake.transformsByItem[linkID] = [Self.b64]
        select(linkID)
        _ = model.handle(.toggleActions)
        #expect(model.shiftReturnItem == nil)
        #expect(!model.actionItems.contains { isShiftReturn($0) })
    }

    /// The default joins the first three transforms in ⌘K, at their head.
    @Test func aDefaultPastTheFirstThreeLeadsThem() {
        defaults.pin("dev.yabbistir.convert/color#nscolor", for: .color)
        select(colorID)
        _ = model.handle(.toggleActions)
        let transforms = model.actionItems.filter { if case .transform = $0 { true } else { false } }
        #expect(transforms == ["nscolor", "rgb", "hsl"].map { .transform("dev.yabbistir.convert/color#\($0)") })
        #expect(isShiftReturn(.transform("dev.yabbistir.convert/color#nscolor")))
    }

    @Test func returnOnThePlainRowPastesPlain() {
        select(richID)
        _ = model.handle(.toggleTransforms)
        #expect(model.handle(.confirm(plain: false)) == .paste(itemID: richID, plain: true))
        #expect(model.layer == .none)
        // ⇧↵ in the panel is ↵.
        _ = model.handle(.toggleTransforms)
        #expect(model.handle(.confirm(plain: true)) == .paste(itemID: richID, plain: true))
    }

    @Test func copyOnThePlainRowCopiesPlain() {
        select(richID)
        _ = model.handle(.toggleTransforms)
        #expect(model.handle(.copy) == .copyPlain(itemID: richID))
        #expect(model.layer == .none)
    }

    /// The plain row's preview is the item's text; typing its name finds it.
    @Test func thePlainRowShowsAndFindsThePlainText() {
        fake.transformsByItem[richID] = [Self.b64]
        select(richID)
        _ = model.handle(.toggleTransforms)
        #expect(model.transformPlainText == "Perşembe toplantısı\niade akışı demosu")
        #expect(model.transformKeyLabels.confirm == "Yapıştır")
        for character in "düz" { _ = model.handle(.type(String(character))) }
        #expect(model.transformRows == [.plainText])
    }
}
