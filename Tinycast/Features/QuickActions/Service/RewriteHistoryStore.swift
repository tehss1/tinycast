import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class RewriteHistoryStore {
    private(set) var records: [RewriteHistoryRecord] = []

    static let retentionDays = 7
    static let retention = TimeInterval(retentionDays * 24 * 60 * 60)

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let unsealedURL: URL
    @ObservationIgnored private let keySource: () -> SymmetricKey?
    /// Asked once: a key arriving after a failed load would let a save replace unread history.
    @ObservationIgnored private lazy var key: SymmetricKey? = keySource()
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var dayObserver: NotificationToken?
    @ObservationIgnored private var unreadableFile = false

    init(directory: URL, key: @escaping () -> SymmetricKey?, now: @escaping () -> Date = Date.init) {
        fileURL = directory.appendingPathComponent("rewrite-history.sealed")
        unsealedURL = directory.appendingPathComponent("rewrite-history.json")
        keySource = key
        self.now = now
    }

    func load() {
        observeDayChange()
        try? FileManager.default.removeItem(at: unsealedURL)
        if isExpiredOnDisk { try? FileManager.default.removeItem(at: fileURL) }
        unreadableFile = FileManager.default.fileExists(atPath: fileURL.path)
        guard let key, let sealed = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = Self.opened(sealed, with: key) else {
            return
        }
        unreadableFile = false
        let retained = Self.retained(decoded, now: now())
        records = retained
        if retained.count != decoded.count { _ = persist(retained) }
    }

    /// Every save rewrites the file, so one this old holds only expired records, key or no key.
    private var isExpiredOnDisk: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let written = attributes[.modificationDate] as? Date
        else { return false }
        return now().timeIntervalSince(written) > Self.retention
    }

    private static func opened(_ sealed: Data, with key: SymmetricKey) -> [RewriteHistoryRecord]? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
            let data = try? AES.GCM.open(box, using: key)
        else { return nil }
        return try? JSONDecoder().decode([RewriteHistoryRecord].self, from: data)
    }

    private func observeDayChange() {
        guard dayObserver == nil else { return }
        let center = NotificationCenter.default
        let token = center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
        dayObserver = NotificationToken(token, center: center)
    }

    @discardableResult
    func save(_ record: RewriteHistoryRecord) -> Bool {
        var updated = records.filter { $0.id != record.id }
        updated.append(record)
        updated = Self.retained(updated, now: now())
        guard persist(updated) else { return false }
        records = updated
        return true
    }

    func prune() {
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
        let updated = records.filter { $0.id != id }
        guard persist(updated) else { return false }
        records = updated
        return true
    }

    private func persist(_ values: [RewriteHistoryRecord]) -> Bool {
        guard let key else { return false }
        do {
            if unreadableFile {
                guard isExpiredOnDisk else { return false }
                try FileManager.default.removeItem(at: fileURL)
                unreadableFile = false
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let sealed = try AES.GCM.seal(encoder.encode(values), using: key).combined else {
                return false
            }
            try sealed.write(to: fileURL, options: .atomic)
            try seal()
            return true
        } catch {
            return false
        }
    }

    /// An atomic write replaces the file, so both attributes are set again after every save.
    private func seal() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var url = fileURL
        try url.setResourceValues(excluded)
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
