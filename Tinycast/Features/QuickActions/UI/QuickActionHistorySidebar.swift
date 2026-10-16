import SwiftUI

struct QuickActionHistorySidebar: View {
    @Environment(\.metrics) private var metrics
    let records: [RewriteHistoryRecord]
    let selectedID: UUID?
    let currentID: UUID
    let height: CGFloat
    let onSelect: (UUID) -> Void
    let onActions: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: metrics.spacing.sm) {
                Text("Recent drafts")
                    .font(metrics.typography.panelTitle)
                Spacer(minLength: 0)
                Button(action: onCollapse) {
                    SymbolImage(name: "sidebar.left", size: 13, monochrome: true)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Hide recent drafts")
                .accessibilityLabel("Hide recent drafts")
            }
            .padding(.horizontal, metrics.spacing.xl)
            .padding(.top, metrics.spacing.xl)
            .padding(.bottom, metrics.spacing.md)
            ScrollView {
                LazyVStack(spacing: metrics.spacing.xs) {
                    ForEach(records) { record in
                        HistoryRow(
                            record: record,
                            selected: selectedID == record.id,
                            current: record.id == currentID
                        ) {
                            onSelect(record.id)
                        } onActions: {
                            onActions(record.id)
                        } onDelete: {
                            onDelete(record.id)
                        }
                    }
                }
                .padding(.horizontal, metrics.spacing.sm)
                .padding(.bottom, metrics.spacing.md)
            }
            .scrollBounceBehavior(.basedOnSize)
            Text("Kept for \(RewriteHistoryStore.retentionDays) days")
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textTertiary)
                .padding(.horizontal, metrics.spacing.xl)
                .padding(.vertical, metrics.spacing.md)
        }
        .frame(width: metrics.size.quickActionHistorySidebar, height: height)
        .background(Theme.Colors.controlSurface.opacity(0.35))
    }

    private struct HistoryRow: View {
        @Environment(\.metrics) private var metrics
        let record: RewriteHistoryRecord
        let selected: Bool
        let current: Bool
        let action: () -> Void
        let onActions: () -> Void
        let onDelete: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                    HStack(spacing: metrics.spacing.sm) {
                        Text(record.title)
                            .font(metrics.typography.rowTitle)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        timestamp
                    }
                    let preview = record.preview
                    if !preview.isEmpty {
                        Text(preview)
                            .font(metrics.typography.keyCap)
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, metrics.spacing.md)
                .padding(.vertical, metrics.spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                        .fill(selected ? Theme.Colors.selection : rowFill))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onRightClick(perform: onActions)
            .accessibilityAction(named: "Delete Conversation", onDelete)
            .onHover { hovered = $0 }
        }

        private var timestamp: some View {
            Text(current ? "Now" : age)
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textTertiary)
        }

        private var age: String {
            Calendar.current.isDateInToday(record.updatedAt)
                ? record.updatedAt.formatted(date: .omitted, time: .shortened)
                : record.updatedAt.formatted(.dateTime.weekday(.abbreviated))
        }

        private var rowFill: Color {
            hovered ? Theme.Colors.rowHover : .clear
        }
    }
}
