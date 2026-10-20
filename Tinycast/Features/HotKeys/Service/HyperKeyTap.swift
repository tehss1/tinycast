import AppKit
import Carbon.HIToolbox
@preconcurrency import IOKit.hidsystem

// Snapshot the mutable C global `mach_task_self_`, so actor code never reads it raw.
private let machTaskSelf = mach_task_self_

/// C entry point: decode, cross in for a Sendable `Decision`, then apply it out here.
private func hyperKeyEventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HyperKeyTap>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { tap.reenable() }
        return Unmanaged.passUnretained(event)
    }

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let isSynthetic = event.getIntegerValueField(.eventSourceUserData) == HyperKeyTap.syntheticTag
    let flags = event.flags.rawValue

    let decision = MainActor.assumeIsolated {
        tap.decide(
            type: type, keyCode: keyCode, flagsRaw: flags,
            isAutorepeat: isAutorepeat, isSynthetic: isSynthetic)
    }
    switch decision {
    case .pass:
        return Unmanaged.passUnretained(event)
    case .suppress:
        return nil
    case .rewrite(let flags, let keyCode, let asFlagsChanged):
        if asFlagsChanged { event.type = .flagsChanged }
        if let keyCode {
            event.setIntegerValueField(.keyboardEventKeycode, value: keyCode)
        }
        event.flags = CGEventFlags(rawValue: flags)
        return Unmanaged.passUnretained(event)
    }
}

<<<<<<< HEAD
/// HID remap of Caps Lock → F18 while it is Hyper. See docs/features/hotkeys.md#the-hyper-key.
private enum CapsLockRemap {
    // HID usages: keyboard page 0x07, Caps Lock 0x39, F18 0x6D.
    private static let mappingOn =
        #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}"#
    private static let mappingOff = #"{"UserKeyMapping":[]}"#

    // Serial, so rapid on→off→on toggles apply in call order rather than racing.
    private static let queue = DispatchQueue(label: "com.tinycast.capslock-remap", qos: .utility)

    static func setEnabled(_ enabled: Bool) {
        let mapping = enabled ? mappingOn : mappingOff
        queue.async { apply(mapping) }
    }

    /// Synchronous for `applicationWillTerminate`, and queued so no pending toggle lands after it.
    static func clearBlocking() {
        queue.sync { apply(mappingOff) }
    }

    private static func apply(_ mapping: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", mapping]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.runObservingExit().wait()
            if process.terminationStatus != 0 {
                NSLog("Tinycast: hidutil remap exited %d", process.terminationStatus)
            }
        } catch {
            NSLog("Tinycast: hidutil caps lock remap failed: %@", error.localizedDescription)
        }
    }
}

/// The Hyper Key engine, a modifying tap. See docs/features/hotkeys.md#the-hyper-key.
=======
>>>>>>> refs/upstream/v0.12.1
@MainActor
final class HyperKeyTap {
    /// What the callback should do, decided on the actor; `asFlagsChanged` converts in place.
    enum Decision: Sendable {
        case pass
        case suppress
        case rewrite(flags: UInt64, keyCode: Int64? = nil, asFlagsChanged: Bool = false)
    }

    /// Marker on events this tap posts, so it never reacts to its own synthetics.
    nonisolated static let syntheticTag: Int64 = 0x5459_4354

    /// Device-level modifier bits from IOLLEvent.h. See docs/features/hotkeys.md#the-hyper-key.
    private enum DeviceFlag {
        static let leftControl: UInt64 = 0x0000_0001
        static let leftShift: UInt64 = 0x0000_0002
        static let rightShift: UInt64 = 0x0000_0004
        static let leftCommand: UInt64 = 0x0000_0008
        static let rightCommand: UInt64 = 0x0000_0010
        static let leftOption: UInt64 = 0x0000_0020
        static let rightOption: UInt64 = 0x0000_0040
        static let rightControl: UInt64 = 0x0000_2000
    }

    var route: HyperKeyRoute? {
        didSet { if route != oldValue { cancelHold() } }
    }

<<<<<<< HEAD
    @ObservationIgnored private var settings: AppSettings?
    // Raw CF handles the tap callback and teardown reach; never a view dependency.
    @ObservationIgnored private var tapPort: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var sessionTokens: [NotificationToken] = []
    @ObservationIgnored private var sessionActive = true
    @ObservationIgnored private var hidConnect: io_connect_t = IO_OBJECT_NULL
=======
    var onUnmappedCapsLock: (() -> Void)?
>>>>>>> refs/upstream/v0.12.1

    private let settings: AppSettings
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hidConnect: io_connect_t = IO_OBJECT_NULL

<<<<<<< HEAD
    /// Mirror of `settings.hyperKey`; the toggles are read live, so nothing goes stale.
    @ObservationIgnored private var key: HyperKeyPhysicalKey = .none

    // Hold state machine, written from the tap callback on every keystroke.
    @ObservationIgnored private var hyperActive = false
    @ObservationIgnored private var hyperDownAt: ContinuousClock.Instant?
    @ObservationIgnored private var otherKeyPressed = false
    @ObservationIgnored private var capsLockRemapEnabled: Bool?
=======
    private var hyperActive = false
    private var hyperDownAt: ContinuousClock.Instant?
    private var otherKeyPressed = false
>>>>>>> refs/upstream/v0.12.1
    private let clock = ContinuousClock()
    private static let quickPressWindow: Duration = .milliseconds(250)

    init(settings: AppSettings) {
        self.settings = settings
    }

    // Isolated so teardown can release the main-actor IOKit connection.
    isolated deinit {
        if hidConnect != IO_OBJECT_NULL { IOServiceClose(hidConnect) }
    }

    var isInstalled: Bool { tapPort != nil }
    var isEnabled: Bool? { tapPort.map { CGEvent.tapIsEnabled(tap: $0) } }
    var runLoopSourceIsValid: Bool? { runLoopSource.map(CFRunLoopSourceIsValid) }

    // MARK: - Hyper chord flags

    /// The flags OR'd in while Hyper is held: the generic masks plus left-side device bits.
    private var hyperFlagsRaw: UInt64 {
        var raw =
            CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue
            | DeviceFlag.leftControl | DeviceFlag.leftOption | DeviceFlag.leftCommand
        if settings.hyperKeyIncludesShift {
            raw |= CGEventFlags.maskShift.rawValue | DeviceFlag.leftShift
        }
        return raw
    }

    /// The Hyper key's own flag residue, scrubbed from every rewritten event.
    private var strippedFlagsRaw: UInt64 {
        guard let key = route?.key else { return 0 }
        if key == .capsLock { return CGEventFlags.maskAlphaShift.rawValue }
        guard let own = key.ownFlag, hyperFlagsRaw & own.rawValue == 0 else { return 0 }
        return own.rawValue | Self.deviceBits(for: own)
    }

    private static func deviceBits(for flag: CGEventFlags) -> UInt64 {
        switch flag {
        case .maskControl: return DeviceFlag.leftControl | DeviceFlag.rightControl
        case .maskShift: return DeviceFlag.leftShift | DeviceFlag.rightShift
        case .maskAlternate: return DeviceFlag.leftOption | DeviceFlag.rightOption
        case .maskCommand: return DeviceFlag.leftCommand | DeviceFlag.rightCommand
        default: return 0
        }
    }

    /// F18 carries fn like any function key; a `flagsChanged` saying so reads as a real fn press.
    private static let functionKeyFlagRaw = CGEventFlags.maskSecondaryFn.rawValue

    private func hyperized(_ flagsRaw: UInt64) -> UInt64 {
        (flagsRaw & ~strippedFlagsRaw) | hyperFlagsRaw
    }

    // MARK: - Event decisions

    func decide(
        type: CGEventType, keyCode: Int, flagsRaw: UInt64, isAutorepeat: Bool, isSynthetic: Bool
    ) -> Decision {
<<<<<<< HEAD
        guard sessionActive, !isSynthetic, let tapCode = key.tapKeyCode else { return .pass }
=======
        guard !isSynthetic, let route else { return .pass }
>>>>>>> refs/upstream/v0.12.1

        if keyCode == route.tapKeyCode {
            return decideHyperKeyEvent(
                route: route, type: type, flagsRaw: flagsRaw, isAutorepeat: isAutorepeat)
        }
        // A latch carries no release, so it passes as Caps Lock and the keyboard is repaired.
        if route.remap != nil, keyCode == kVK_CapsLock, type == .flagsChanged {
            Task { @MainActor [weak self] in self?.onUnmappedCapsLock?() }
            return .pass
        }
        guard hyperActive else { return .pass }
        // Any other key or modifier going down while Hyper is held makes this a combo, not a tap.
        if type == .keyDown || type == .flagsChanged { otherKeyPressed = true }
        return .rewrite(flags: hyperized(flagsRaw))
    }

    /// docs/features/hotkeys.md#press-tracking-reads-the-event
    private func decideHyperKeyEvent(
        route: HyperKeyRoute, type: CGEventType, flagsRaw: UInt64, isAutorepeat: Bool
    ) -> Decision {
        guard let modifier = route.modifier else {
            return decideFunctionKeyEvent(type: type, flagsRaw: flagsRaw, isAutorepeat: isAutorepeat)
        }
        guard type == .flagsChanged else { return .pass }
        let isDown = ModifierKey.held(in: flagsRaw, globeDown: false).contains(modifier)
        return .rewrite(flags: transition(isDown: isDown, flagsRaw: flagsRaw))
    }

    /// F18 arrives as keyDown/keyUp; both ends become Left Control `flagsChanged` transitions.
    private func decideFunctionKeyEvent(
        type: CGEventType, flagsRaw: UInt64, isAutorepeat: Bool
    ) -> Decision {
        let flagsRaw = flagsRaw & ~Self.functionKeyFlagRaw
        switch type {
        case .keyDown:
            if isAutorepeat { return .suppress }
            let flags = transition(isDown: true, flagsRaw: flagsRaw)
            return .rewrite(flags: flags, keyCode: Int64(kVK_Control), asFlagsChanged: true)
        case .keyUp:
            let flags = transition(isDown: false, flagsRaw: flagsRaw)
            return .rewrite(flags: flags, keyCode: Int64(kVK_Control), asFlagsChanged: true)
        default:
            return .pass
        }
    }

    private func transition(isDown: Bool, flagsRaw: UInt64) -> UInt64 {
        if isDown {
            if !hyperActive { beginHold() }
            return hyperized(flagsRaw)
        }
        if hyperActive { endHold() }
        return flagsRaw & ~strippedFlagsRaw
    }

    // MARK: - Hold state machine

    private func beginHold() {
        hyperActive = true
        hyperDownAt = clock.now
        otherKeyPressed = false
    }

    private func endHold() {
        let isQuick =
            !otherKeyPressed && hyperDownAt.map { clock.now - $0 < Self.quickPressWindow } ?? false
        hyperActive = false
        hyperDownAt = nil
        guard isQuick, let key = route?.key, key.hasOriginalFunction else { return }
        let action = settings.hyperKeyQuickPress
        // Posting or touching IOKit inside the callback risks re-entrancy, so defer a turn.
        Task { @MainActor [weak self] in self?.fireQuickPress(action, for: key) }
    }

    private func fireQuickPress(_ action: HyperKeyQuickPress, for key: HyperKeyPhysicalKey) {
<<<<<<< HEAD
        guard sessionActive else { return }
=======
        // Secure Input hides the key that made this press a chord, so a short hold proves nothing.
        guard !IsSecureEventInputEnabled() else { return }
>>>>>>> refs/upstream/v0.12.1
        switch action {
        case .none:
            break
        case .originalKey:
            if key == .capsLock { setCapsLockState(!capsLockState()) }
        case .escape:
            postKey(CGKeyCode(kVK_Escape))
        }
    }

    func cancelHold() {
        hyperActive = false
        hyperDownAt = nil
        otherKeyPressed = false
    }

<<<<<<< HEAD
    // MARK: - Configuration

    private func applyKey(_ newKey: HyperKeyPhysicalKey) {
        guard newKey != key else { return }
        cancelHold()
        let wasCapsLock = key == .capsLock
        key = newKey
        syncTapPresence()
        if wasCapsLock || newKey == .capsLock { syncCapsLockRemap() }
    }

    private func syncCapsLockRemap() {
        let secureInput = IsSecureEventInputEnabled()
        let shouldEnable = sessionActive && key == .capsLock && status == .active && !secureInput
        if secureInput { cancelHold() }
        guard capsLockRemapEnabled != shouldEnable else { return }
        if shouldEnable { setCapsLockState(false) }
        capsLockRemapEnabled = shouldEnable
        CapsLockRemap.setEnabled(shouldEnable)
    }

    /// The HID remap outlives the process, so hand the key back before exiting.
    func prepareForTermination() {
        if key == .capsLock { CapsLockRemap.clearBlocking() }
    }

    // MARK: - Tap lifecycle

    private func syncTapPresence() {
        if key == .none {
            tearDownTap()
            healthTicker?.unsubscribe(self)
            status = .off
        } else {
            healthTicker?.subscribe(self)
            installTapIfNeeded()
        }
    }

    private func installTapIfNeeded() {
        guard sessionActive, tapPort == nil, key != .none else { return }
=======
    // MARK: - Tap lifecycle

    /// False when Accessibility is missing: only a trusted process may modify events.
    @discardableResult
    func install() -> Bool {
        guard tapPort == nil else { return true }
>>>>>>> refs/upstream/v0.12.1
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: hyperKeyEventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        tapPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    func tearDown() {
        cancelHold()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
            CFMachPortInvalidate(tapPort)
            self.tapPort = nil
        }
    }

    /// Called when the system disables the tap; any half-tracked hold is stale by then.
    func reenable() {
        cancelHold()
        guard sessionActive else { return }
        if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
    }

<<<<<<< HEAD
    /// One-second watchdog while a key is configured. See docs/features/hotkeys.md#lifecycle.
    func healthCheck() {
        guard sessionActive, key != .none else { return }
        if tapPort == nil {
            installTapIfNeeded()
        } else if !Permissions.isAccessibilityTrusted() {
            tearDownTap()
            status = .needsAccessibility
        } else if let tapPort, !CGEvent.tapIsEnabled(tap: tapPort) {
            CGEvent.tapEnable(tap: tapPort, enable: true)
        }
        if key == .capsLock { syncCapsLockRemap() }
    }

    private func sessionDidResign() {
        sessionActive = false
        cancelHold()
        if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: false) }
        if key == .capsLock {
            capsLockRemapEnabled = false
            CapsLockRemap.setEnabled(false)
        }
    }

    private func sessionDidBecomeActive() {
        sessionActive = true
        healthCheck()
    }

=======
>>>>>>> refs/upstream/v0.12.1
    // MARK: - Synthetics & caps state

    /// Synthesize a bare key press for Quick Press, tagged so `decide` ignores it.
    private func postKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        for event in [down, up] {
            // The session source still carries our injected chord, and a modified Escape is eaten.
            event?.flags = []
            event?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Remapping takes Caps Lock's own function away, so a latched lock would stay stuck on.
    func unlatchCapsLock() {
        setCapsLockState(false)
    }

    /// The IOHIDSystem connection for the Caps Lock LED and lock state.
    private func hidConnection() -> io_connect_t {
        if hidConnect != IO_OBJECT_NULL { return hidConnect }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { return IO_OBJECT_NULL }
        var connect: io_connect_t = IO_OBJECT_NULL
        IOServiceOpen(service, machTaskSelf, UInt32(kIOHIDParamConnectType), &connect)
        IOObjectRelease(service)
        hidConnect = connect
        return connect
    }

    private func capsLockState() -> Bool {
        let connect = hidConnection()
        guard connect != IO_OBJECT_NULL else { return false }
        var on = false
        IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &on)
        return on
    }

    private func setCapsLockState(_ on: Bool) {
        let connect = hidConnection()
        guard connect != IO_OBJECT_NULL else { return }
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), on)
    }
}
