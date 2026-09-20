import SwiftUI

struct QuickActionHistorySidebar: View {
    @Environment(\.metrics) private var metrics
    let records: [RewriteHistoryRecord]
    let selectedID: UUID?
    let currentID: UUID
    let height: CGFloat
    let onSelect: (UUID) -> Void
    let onActions: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent drafts")
                .font(metrics.typography.panelTitle)
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
                        }
                    }
                }
                .padding(.horizontal, metrics.spacing.sm)
                .padding(.bottom, metrics.spacing.md)
            }
            .scrollBounceBehavior(.basedOnSize)
            Text("Kept for 7 days")
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
                    if !record.preview.isEmpty {
                        Text(record.preview)
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
            .onHover { hovered = $0 }
        }

        private var timestamp: some View {
            Text(current ? "Now" : record.updatedAt.formatted(date: .omitted, time: .shortened))
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textTertiary)
        }

        private var rowFill: Color {
            hovered ? Theme.Colors.rowHover : .clear
        }
    }
}
