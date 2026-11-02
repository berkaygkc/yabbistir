import Foundation

/// Builds a synthetic payload: [{types, dataByType}] as a binary plist.
public func pastePlist(_ items: [[(String, String)]]) throws -> Data {
    let array: [[String: Any]] = items.map { reps in
        ["types": reps.map(\.0), "dataByType": Dictionary(uniqueKeysWithValues: reps.map { ($0.0, Data($0.1.utf8)) })]
    }
    return try PropertyListSerialization.data(fromPropertyList: array, format: .binary, options: 0)
}

public func lzfse(_ data: Data) throws -> Data {
    try (data as NSData).compressed(using: .lzfse) as Data
}

public let sampleItems = [[("public.utf8-plain-text", "hello"), ("public.html", "<b>hello</b>")]]
