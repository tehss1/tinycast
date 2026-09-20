import Foundation
import Observation

@MainActor
@Observable
final class RewriteHistoryStore {
    private(set) var records: [RewriteHistoryRecord] = []
    private(set) var isAvailable = true

    static let retention: TimeInterval = 7 * 24 * 60 * 60

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let now: () -> Date

    init(directory: URL, now: @escaping () -> Date = Date.init) {
        fileURL = directory.appendingPathComponent("rewrite-history.json")
        self.now = now
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([RewriteHistoryRecord].self, from: data)
        else {
            isAvailable = false
            return
        }
        let retained = Self.retained(decoded, now: now())
        records = retained
        if retained.count != decoded.count { _ = persist(retained) }
    }

    @discardableResult
    func save(_ record: RewriteHistoryRecord) -> Bool {
        guard isAvailable else { return false }
        var updated = records.filter { $0.id != record.id }
        updated.append(record)
        updated = Self.retained(updated, now: now())
        guard persist(updated) else { return false }
        records = updated
        return true
    }

    func prune() {
        guard isAvailable else { return }
        let retained = Self.retained(records, now: now())
        guard retained.count != records.count, persist(retained) else { return }
        records = retained
    }

    func resumableRecord(
        selection: String, context: QuickActionContext?
    ) -> RewriteHistoryRecord? {
        prune()
        let selected = Self.normalized(selection)
        let matches = records.filter {
            Self.matches($0, selection: selected, context: context)
        }
        guard let preferred = matches.max(by: Self.prefersSecond) else { return nil }
        guard let context, let identity = context.historyIdentity else { return preferred }

        let resumed = RewriteHistoryRecord(
            id: preferred.id, createdAt: preferred.createdAt, updatedAt: preferred.updatedAt,
            subject: context.subject ?? preferred.subject,
            recipient: context.recipient ?? preferred.recipient,
            contextIdentity: identity, contextFingerprints: context.historyFingerprints,
            original: preferred.original,
            messages: preferred.messages,
            pendingInstruction: preferred.pendingInstruction,
            originalIsWritingInstruction: preferred.originalIsWritingInstruction,
            draftAnchor: preferred.draftAnchor,
            audienceOverride: preferred.audienceOverride)
        guard matches.count > 1 || preferred.contextIdentity != identity else { return resumed }

        var updated = records.filter { record in
            !matches.contains { $0.id == record.id }
        }
        updated.append(resumed)
        updated = Self.retained(updated, now: now())
        guard persist(updated) else { return preferred }
        records = updated
        return resumed
    }

    @discardableResult
    func savePendingInstruction(_ instruction: String?, id: UUID) -> Bool {
        guard isAvailable else { return false }
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return instruction == nil
        }
        var updated = records
        updated[index].pendingInstruction = instruction
        updated = Self.retained(updated, now: now())
        guard persist(updated) else { return false }
        records = updated
        return true
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        guard isAvailable else { return false }
        let updated = records.filter { $0.id != id }
        guard persist(updated) else { return false }
        records = updated
        return true
    }

    @discardableResult
    func clearAll() -> Bool {
        guard isAvailable, persist([]) else { return false }
        records = []
        return true
    }

    private func persist(_ values: [RewriteHistoryRecord]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(values).write(to: fileURL, options: .atomic)
            return true
        } catch {
            isAvailable = false
            return false
        }
    }

    private static func retained(
        _ values: [RewriteHistoryRecord], now: Date
    ) -> [RewriteHistoryRecord] {
        let cutoff = now.addingTimeInterval(-retention)
        return values.filter { $0.updatedAt >= cutoff }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func matches(
        _ record: RewriteHistoryRecord, selection: String, context: QuickActionContext?
    ) -> Bool {
        guard let context, let identity = context.historyIdentity else { return false }
        if record.latestDraft == nil {
            guard context.recentThread != nil || context.documentIdentity != nil,
                record.contextIdentity == identity
            else { return false }
            return true
        }
        let contentMatches = normalized(record.original) == selection
            || record.latestDraft.map { normalized($0) == selection } == true
        if let storedIdentity = record.contextIdentity {
            if storedIdentity == identity {
                return context.recentThread != nil || context.documentIdentity != nil || contentMatches
            }
            return sharesThread(record, context: context) && sameSubject(record, context: context)
        }
        return contentMatches && sameEnvelope(record, context: context)
    }

    private static func sharesThread(
        _ record: RewriteHistoryRecord, context: QuickActionContext
    ) -> Bool {
        let stored = Set(record.contextFingerprints ?? [])
        return !stored.isDisjoint(with: context.historyFingerprints)
    }

    private static func sameSubject(
        _ record: RewriteHistoryRecord, context: QuickActionContext
    ) -> Bool {
        guard let recordSubject = record.subject, let contextSubject = context.subject else { return false }
        return normalized(recordSubject) == normalized(contextSubject)
    }

    private static func sameEnvelope(
        _ record: RewriteHistoryRecord, context: QuickActionContext
    ) -> Bool {
        let subjectMatches = record.subject == nil || context.subject == nil
            || sameSubject(record, context: context)
        let recipientMatches = record.recipient == nil || context.recipient == nil
            || normalized(record.recipient ?? "") == normalized(context.recipient ?? "")
        return subjectMatches && recipientMatches
    }

    private static func prefersSecond(
        _ first: RewriteHistoryRecord, _ second: RewriteHistoryRecord
    ) -> Bool {
        if first.messages.count != second.messages.count {
            return first.messages.count < second.messages.count
        }
        return first.updatedAt < second.updatedAt
    }
}
