import Foundation
import GRDB
@testable import YabCore

extension ItemStore {
    /// Inserts `count` short text items in one transaction (fast setup for performance tests).
    func insertSyntheticItems(count: Int, now: Date) throws {
        try dbPool.write { db in
            for index in 0..<count {
                let text = "kayıt \(index) örnek metin içerik"
                let date = now.addingTimeInterval(Double(-index))
                try db.execute(sql: """
                    INSERT INTO item (kind, previewText, searchText, contentHash, device, firstCopiedAt, lastCopiedAt, lastUsedAt)
                    VALUES ('text', ?, ?, ?, 'local', ?, ?, ?)
                    """, arguments: [text, SearchNormalizer.normalize(text), "synthetic-\(index)", date, date, date])
            }
        }
    }
}
