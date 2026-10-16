import CryptoKit
import Darwin
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
        removeStagedFiles()
        if isExpiredOnDisk { try? FileManager.default.removeItem(at: fileURL) }
        unreadableFile = FileManager.default.fileExists(atPath: fileURL.path)
        guard let sealed = try? Data(contentsOf: fileURL), let key,
            let data = Self.opened(sealed, with: key),
            let decoded = try? JSONDecoder().decode(DecodedRecords.self, from: data).records
        else { return }
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

    private static func opened(_ sealed: Data, with key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
            let data = try? AES.GCM.open(box, using: key)
        else { return nil }
        return data
    }

    private struct DecodedRecords: Decodable {
        let records: [RewriteHistoryRecord]

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var records: [RewriteHistoryRecord] = []
            while !container.isAtEnd {
                let recordDecoder = try container.superDecoder()
                if let record = try? RewriteHistoryRecord(from: recordDecoder) {
                    records.append(record)
                }
            }
            self.records = records
        }
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
        guard let context, let identity = context.historyIdentity else { return nil }
        let selected = Self.normalized(selection)
        let matches = records.filter {
            Self.matches($0, selection: selected, context: context)
        }
        let editor = context.documentIdentity
        let sameEditor = matches.filter { editor != nil && $0.editorIdentity == editor }
        let candidates = sameEditor.isEmpty
            ? matches.filter { Self.mayFollow($0, selection: selected, into: context) } : sameEditor
        let addressed = Self.addresses(in: context.recipient)
        guard let preferred = candidates.max(by: { Self.prefersSecond($0, $1, addressed: addressed) })
        else { return nil }

        let resumed = RewriteHistoryRecord(
            id: preferred.id, createdAt: preferred.createdAt, updatedAt: preferred.updatedAt,
            subject: context.subject ?? preferred.subject,
            recipient: context.recipient ?? preferred.recipient,
            contextIdentity: identity, contextFingerprints: context.historyFingerprints,
            editorIdentity: editor ?? preferred.editorIdentity,
            original: preferred.original,
            messages: preferred.messages,
            pendingInstruction: preferred.pendingInstruction,
            originalIsWritingInstruction: preferred.originalIsWritingInstruction,
            draftAnchor: preferred.draftAnchor,
            audienceOverride: preferred.audienceOverride)
        // Another editor's row, or one found only through a shared quote, may be a separate reply.
        let duplicates = candidates.filter { record in
            record.id != preferred.id
                && (record.editorIdentity == nil || record.editorIdentity == editor)
                && (record.contextIdentity == nil || record.contextIdentity == identity)
        }
        guard !duplicates.isEmpty || resumed != preferred else { return resumed }

        let replaced = Set(duplicates.map(\.id)).union([preferred.id])
        var updated = records.filter { !replaced.contains($0.id) }
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
            return try write(sealed)
        } catch {
            return false
        }
    }

    private static let stagedPrefix = ".rewrite-history-"

    private static let stagedFileLifetime: TimeInterval = 60 * 60

    /// Only an old one is abandoned: a fresh one may be another instance's save in flight.
    private func removeStagedFiles() {
        let directory = fileURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.stagedPrefix) {
            let staged = directory.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: staged.path),
                let written = attributes[.modificationDate] as? Date,
                now().timeIntervalSince(written) > Self.stagedFileLifetime
            else { continue }
            try? FileManager.default.removeItem(at: staged)
        }
    }

    private func write(_ sealed: Data) throws -> Bool {
        var staged = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(Self.stagedPrefix)\(UUID().uuidString)")
        let descriptor = Darwin.open(staged.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { return false }
        defer { try? FileManager.default.removeItem(at: staged) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: sealed)
        try handle.close()
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        try staged.setResourceValues(excluded)
        return Darwin.rename(staged.path, fileURL.path) == 0
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
        if let editor = context.documentIdentity, record.editorIdentity == editor {
            guard context.recentThread == nil else {
                return record.contextIdentity == identity || sharesThread(record, context: context)
            }
            return !addressesDisjoint(record, context: context)
        }
        if record.latestDraft == nil {
            guard context.recentThread != nil || context.documentIdentity != nil,
                record.contextIdentity == identity
            else { return false }
            return true
        }
        if let storedIdentity = record.contextIdentity {
            if storedIdentity == identity {
                return context.recentThread != nil || context.documentIdentity != nil
                    || contentMatches(record, selection: selection)
            }
            return sharesThread(record, context: context) && sameSubject(record, context: context)
        }
        // A record with no headers came from another app, so its text alone proves nothing here.
        guard record.subject != nil || record.recipient != nil else { return false }
        return contentMatches(record, selection: selection) && sameEnvelope(record, context: context)
    }

    private static func contentMatches(_ record: RewriteHistoryRecord, selection: String) -> Bool {
        normalized(record.original) == selection || selectsLatestDraft(record, selection: selection)
    }

    private static func selectsLatestDraft(_ record: RewriteHistoryRecord, selection: String) -> Bool {
        record.latestDraft.map { normalized($0) == selection } == true
    }

    /// Two replies quoting the same messages are told apart only by whom each one addresses.
    private static func mayFollow(
        _ record: RewriteHistoryRecord, selection: String, into context: QuickActionContext
    ) -> Bool {
        guard let stored = addresses(in: record.recipient),
            let current = addresses(in: context.recipient), stored != current
        else { return true }
        guard !stored.isDisjoint(with: current) else { return false }
        return !sameSnapshot(record, context: context)
            || (!selection.isEmpty && selectsLatestDraft(record, selection: selection))
    }

    private static func sameSnapshot(
        _ record: RewriteHistoryRecord, context: QuickActionContext
    ) -> Bool {
        let fingerprints = Set(context.historyFingerprints)
        return record.contextIdentity == context.historyIdentity
            || (!fingerprints.isEmpty && Set(record.contextFingerprints ?? []) == fingerprints)
    }

    /// Outlook can hand a new email a closed editor's handle, so only the people tell them apart.
    private static func addressesDisjoint(
        _ record: RewriteHistoryRecord, context: QuickActionContext
    ) -> Bool {
        guard let stored = addresses(in: record.recipient),
            let current = addresses(in: context.recipient)
        else { return false }
        return stored.isDisjoint(with: current)
    }

    /// Nil unless every recipient was read, so a partial capture never splits a conversation.
    private static func addresses(in recipient: String?) -> Set<String>? {
        guard let recipient, EmailAddressPattern.recipientDomains(in: recipient) != nil else {
            return nil
        }
        return Set(EmailAddressPattern.matches(in: recipient).map { recipient[$0.range].lowercased() })
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
        _ first: RewriteHistoryRecord, _ second: RewriteHistoryRecord, addressed: Set<String>?
    ) -> Bool {
        let firstAddressed = addressed != nil && addresses(in: first.recipient) == addressed
        let secondAddressed = addressed != nil && addresses(in: second.recipient) == addressed
        if firstAddressed != secondAddressed { return secondAddressed }
        if first.messages.count != second.messages.count {
            return first.messages.count < second.messages.count
        }
        return first.updatedAt < second.updatedAt
    }
}
