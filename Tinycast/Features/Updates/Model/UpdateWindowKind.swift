enum UpdateWindowKind: CaseIterable, Sendable {
    case work, statusItemHost, passiveHUD

    static func blocksUpdate(_ visibleKinds: [Self]) -> Bool {
        visibleKinds.contains(.work)
    }
}
