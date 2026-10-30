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

    init() throws {
        let store = try ItemStore.temporary()
        func ingest(_ text: String, minutesAgo: Double) throws -> Int64 {
            let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(text.utf8))]],
                                    source: nil, device: .local, capturedAt: now.addingTimeInterval(-minutesAgo * 60))
            return try #require(try store.ingest(clip)).item.id!
        }
        base64ID = try ingest("SGVsbG8sIGTDvG55YQ==", minutesAgo: 0.5)
        plainID = try ingest("merhaba dünya", minutesAgo: 1)
        colorID = try ingest("#6E56CF", minutesAgo: 2)
        let library = try Library(store: store)
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-xform-\(UUID().uuidString)")!)
        language.language = .turkish
        fake.transformsByItem[base64ID] = [FakeCommands.command("dev.yabbistir.base64/decode", title: "Base64 çöz", keywords: ["b64", "çöz"]),
                                           FakeCommands.command("dev.yabbistir.base64/encode", title: "Base64 kodla", keywords: ["b64", "kodla"])]
        fake.transformsByItem[colorID] = ["rgb", "hsl", "oklch", "swiftui", "nscolor"].map {
            FakeCommands.command("dev.yabbistir.convert/color#\($0)", title: "\($0.uppercased()) olarak", keywords: ["renk", $0],
                                 extensionName: "Dönüştür")
        }
        model = PanelViewModel(library: library, language: language, extensions: fake, now: { now })
        model.reset()
    }

    func select(_ id: Int64) { model.select(id, in: .history) }

    @Test func shiftTapOpensTransforms() {
        _ = model.handle(.toggleTransforms)
        #expect(model.layer == .transforms)
        #expect(model.transformSubjectID == base64ID)
        #expect(model.transformCommands.map(\.id) == ["dev.yabbistir.base64/decode", "dev.yabbistir.base64/encode"])
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
        #expect(model.transformCommands.map(\.id) == ["dev.yabbistir.base64/encode"])
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
        #expect(model.transformCommands.map(\.id) == ["a.one/x", "a.one/z", "b.two/y"])
    }

    @Test func actionsShowTopThreeAndAll() {
        select(colorID)
        _ = model.handle(.toggleActions)
        let transforms = model.actionItems.filter { if case .transform = $0 { true } else { false } }
        #expect(transforms.count == 3)
        #expect(model.actionItems.contains(.allTransforms))
        #expect(model.actionLabel(.allTransforms) == "Tüm dönüşümler (5)…")
        #expect(model.actionLabel(.transform("dev.yabbistir.convert/color#rgb")) == "RGB olarak")
        #expect(Array(model.actionItems.prefix(4)) == [.paste, .pastePlain, .copy, .addToStack])
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
        #expect(model.transformCommands.count == 5)
    }

    @Test func aTransformWithoutAHintWaitsToBeUsed() throws {
        fake.transformsByItem[plainID] = [FakeCommands.command("dev.yabbistir.convert/ocr", title: "Metni oku", keywords: ["ocr"], hint: false)]
        select(plainID)
        _ = model.handle(.toggleTransforms)
        let command = try #require(model.transformCommands.first)
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
        #expect(model.transformCommands.map(\.id) == ["dev.example.download/video", "dev.yabbistir.base64/decode", "dev.yabbistir.base64/encode"])
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
        #expect(Array(model.actionItems.prefix(5)) == [.transform("dev.example.download/video"), .paste, .pastePlain, .copy, .addToStack])
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
}
