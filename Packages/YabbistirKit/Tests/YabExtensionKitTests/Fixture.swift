import Foundation
import YabTestSupport

/// Writes an extension folder for a test: manifest, locales and (optionally) index.js.
struct Fixture {
    let root: URL

    init(id: String = "dev.example.sample", folderName: String? = nil, manifest: [String: Any]? = nil,
         locales: [String: [String: Any]] = Fixture.locales, indexJS: String? = "exports.actions = {};") throws {
        root = TestScratch.url("yab-ext")
            .appendingPathComponent(folderName ?? id)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("locales"), withIntermediateDirectories: true)
        let body = manifest ?? Fixture.manifest(id: id)
        try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]).write(to: root.appendingPathComponent("manifest.json"))
        for (language, table) in locales {
            try JSONSerialization.data(withJSONObject: table).write(to: root.appendingPathComponent("locales/\(language).json"))
        }
        if let indexJS { try indexJS.write(to: root.appendingPathComponent("index.js"), atomically: true, encoding: .utf8) }
    }

    static var locales: [String: [String: Any]] { [
        "en": ["name": "Sample", "description": "A sample", "decode.title": "Decode", "decode.keywords": ["decode", "b64"],
               "encode.title": "Encode", "encode.keywords": ["encode"], "tag": "base64", "upper": "Uppercase",
               "hello": "Hello {name}"],
        "tr": ["decode.title": "Çöz", "decode.keywords": ["çöz"], "hello": "Merhaba {name}"],
    ] }

    static func manifest(id: String) -> [String: Any] {
        [
            "id": id, "version": "1.0.0", "apiVersion": 1, "defaultLocale": "en", "name": "name",
            "description": "description", "icon": "sf:number", "author": "berkaygkc", "license": "MIT",
            "categories": ["text"],
            "preferences": [["id": "upper", "type": "toggle", "title": "upper", "default": false]],
            "contributes": [
                "actions": [
                    ["id": "decode", "title": "decode.title", "keywords": "decode.keywords", "input": "item",
                     "accepts": ["kinds": ["text"], "tags": ["base64"]], "output": "text", "hint": true, "priority": 2],
                    ["id": "encode", "title": "encode.title", "keywords": "encode.keywords", "input": "item",
                     "accepts": ["kinds": ["text", "code"]], "output": "text"],
                ],
                "detectors": [
                    ["id": "base64", "tag": "tag", "accepts": ["kinds": ["text"], "pattern": "^[A-Za-z0-9+/]{8,}={0,2}$"],
                     "validate": true, "preview": true, "suggests": ["decode"]],
                ],
            ],
        ]
    }
}

extension Dictionary where Key == String, Value == Any {
    /// A copy with a value replaced at a dotted path ("contributes.actions.0.id").
    func setting(_ path: String, _ value: Any?) -> [String: Any] {
        func apply(_ node: Any, _ parts: ArraySlice<String>) -> Any? {
            guard let head = parts.first else { return value }
            if var array = node as? [Any], let index = Int(head) {
                if let next = apply(array[index], parts.dropFirst()) { array[index] = next } else { array.remove(at: index) }
                return array
            }
            var dictionary = node as? [String: Any] ?? [:]
            dictionary[head] = parts.count == 1 ? value : apply(dictionary[head] ?? [String: Any](), parts.dropFirst())
            return dictionary
        }
        return apply(self, ArraySlice(path.split(separator: ".").map(String.init))) as? [String: Any] ?? self
    }
}
