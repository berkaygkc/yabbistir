import Foundation
import Testing
import YabCore
@testable import YabUI

@MainActor @Suite struct CategoryRowRulesTests {
    private func row(source: String?) throws -> CategoryEditorModel.Row {
        var json: [String: Any] = ["id": 1, "name": "Notes", "color": "slate", "visibility": "always", "position": 0]
        if let source { json["source"] = source }
        let category = try JSONDecoder().decode(ClipCategory.self, from: JSONSerialization.data(withJSONObject: json))
        return CategoryEditorModel.Row(category: category, count: 3)
    }

    @Test func sourceRowsAreReadOnly() throws {
        #expect(CategoryRowRules.canEdit(try row(source: "dev.example.links/list")) == false)
        #expect(CategoryRowRules.canEdit(try row(source: nil)) == true)
    }
}
