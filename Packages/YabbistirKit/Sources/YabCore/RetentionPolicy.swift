import Foundation
import GRDB

/// How long an item survives without being used. The clock restarts on every use
/// (paste, copy, re-copy); items in a category are never purged.
public enum RetentionPolicy: String, CaseIterable, Sendable, Codable {
    case oneWeek, oneMonth, threeMonths, oneYear, unlimited

    public static let `default`: RetentionPolicy = .oneYear

    public func cutoff(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .oneWeek: calendar.date(byAdding: .day, value: -7, to: now)
        case .oneMonth: calendar.date(byAdding: .month, value: -1, to: now)
        case .threeMonths: calendar.date(byAdding: .month, value: -3, to: now)
        case .oneYear: calendar.date(byAdding: .year, value: -1, to: now)
        case .unlimited: nil
        }
    }
}

extension ItemStore {
    /// Records a use: renews retention and moves the item to the top of history (back into it,
    /// for an item kept only in a category).
    public func markUsed(_ itemID: Int64, at date: Date) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE item SET lastUsedAt = ?, lastCopiedAt = ?, inHistory = 1 WHERE id = ?",
                           arguments: [date, date, itemID])
        }
    }

    /// The items a purge removes: unused since the cutoff and in no category. Shared by the purge and its count.
    private static let expiredCondition = """
        lastUsedAt < ?
          AND NOT EXISTS (SELECT 1 FROM categoryMembership m WHERE m.itemID = item.id)
        """

    /// How many items `purgeExpired` would delete right now, for the same policy and time.
    public func countExpired(policy: RetentionPolicy, now: Date) throws -> Int {
        guard let cutoff = policy.cutoff(now: now) else { return 0 }
        return try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE \(Self.expiredCondition)", arguments: [cutoff]) ?? 0
        }
    }

    /// Deletes items unused since the policy's cutoff that belong to no category.
    public func purgeExpired(policy: RetentionPolicy, now: Date) throws -> [Int64] {
        guard let cutoff = policy.cutoff(now: now) else { return [] }
        // One transaction: an item renewed by a concurrent copy is never deleted after being selected.
        return try dbPool.write { db in
            let expired = try Int64.fetchAll(db, sql: "SELECT id FROM item WHERE \(Self.expiredCondition)", arguments: [cutoff])
            try deleteItems(expired, db)
            return expired
        }
    }
}
