// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YabbistirKit",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "YabCore", targets: ["YabCore"]),
        .library(name: "YabPasteboard", targets: ["YabPasteboard"]),
        .library(name: "YabPlatform", targets: ["YabPlatform"]),
        .library(name: "YabLocalization", targets: ["YabLocalization"]),
        .library(name: "YabUI", targets: ["YabUI"]),
        .library(name: "YabImport", targets: ["YabImport"]),
        .library(name: "YabStack", targets: ["YabStack"]),
        .library(name: "YabExtensionKit", targets: ["YabExtensionKit"]),
        .library(name: "YabExtensionRuntime", targets: ["YabExtensionRuntime"]),
        .library(name: "YabExtensions", targets: ["YabExtensions"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .target(name: "YabCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "YabPasteboard", dependencies: ["YabCore"]),
        .target(name: "YabPlatform", dependencies: ["KeyboardShortcuts"]),
        .target(name: "YabLocalization", resources: [.process("Localizable.xcstrings")]),
        .target(name: "YabStack", dependencies: ["YabCore", "YabPasteboard"]),
        .target(name: "YabUI", dependencies: ["YabCore", "YabPasteboard", "YabPlatform", "YabLocalization", "YabStack", "YabExtensions", "YabExtensionKit", "YabImport"]),
        .target(name: "YabExtensionKit"),
        .target(name: "YabExtensionRuntime", dependencies: ["YabExtensionKit"]),
        .target(name: "YabExtensions", dependencies: ["YabExtensionKit", "YabExtensionRuntime", "YabCore", "YabPasteboard", "YabLocalization", "YabPlatform"]),
        .target(name: "YabImport", dependencies: ["YabCore", "YabPasteboard", .product(name: "GRDB", package: "GRDB.swift")]),
        // Test-only helpers (synthetic libraries, payload builders); deliberately not part of any product.
        .target(name: "YabImportTestSupport", dependencies: ["YabImport", "YabCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "YabCoreTests", dependencies: ["YabCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "YabPasteboardTests", dependencies: ["YabPasteboard"]),
        .testTarget(name: "YabPlatformTests", dependencies: ["YabPlatform", .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")]),
        .testTarget(name: "YabLocalizationTests", dependencies: ["YabLocalization"]),
        .testTarget(name: "YabUITests", dependencies: ["YabUI", "YabStack", "YabPasteboard", "YabExtensions", "YabExtensionKit", "YabPlatform", "YabImport", "YabImportTestSupport",
                                                .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "YabImportTests", dependencies: ["YabImport", "YabImportTestSupport", "YabCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "YabStackTests", dependencies: ["YabStack"]),
        .testTarget(name: "YabExtensionKitTests", dependencies: ["YabExtensionKit"]),
        .testTarget(name: "YabExtensionRuntimeTests", dependencies: ["YabExtensionRuntime"]),
        .testTarget(name: "YabExtensionsTests", dependencies: ["YabExtensions", "YabPlatform", "YabExtensionRuntime", "YabCore", "YabPasteboard", "YabLocalization",
                                                        .product(name: "GRDB", package: "GRDB.swift")]),
    ]
)
