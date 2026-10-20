import AppKit
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Reads the selection and transforms it; replacing the text is the coordinator's call, not this.
@MainActor
final class QuickActionRunner {
    enum Input: Equatable {
        case selection(String)
        case insertionPoint
    }

    /// The ceiling lives here, not at the provider, where it returns as an opaque context error.
    static let maxSelectionBytes = 32_768

    /// A borrowed ⌘C synthesises a keystroke into somebody's app, so it is never the first try.
    static func input(
        for action: QuickAction, in targetApp: NSRunningApplication?, using injector: TextInjector
    ) async throws -> Input {
        // A shortcut press is an explicit gesture, so it may prompt, as snippet expansion does.
        guard Permissions.ensureAccessibility() else { throw QuickActionFailure.needsAccessibility }
        guard let targetApp,
            targetApp.bundleIdentifier != Bundle.main.bundleIdentifier
        else { throw QuickActionFailure.noTarget }

        let reported = AccessibilityText.read(in: targetApp)
        if case .text(let text) = reported { return .selection(try accepted(text)) }
        if action == .rewrite, reported == .empty,
            AccessibilityText.hasInsertionPoint(in: targetApp)
        {
            return .insertionPoint
        }
        if let copied = await injector.copySelection(from: targetApp) {
            return .selection(try accepted(copied))
        }
        // Only when Accessibility saw a text element is "nothing is selected" the honest answer.
        throw reported == .empty
            ? QuickActionFailure.noSelection
            : .unreadableApp(targetApp.localizedName)
    }

    static func accepted(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuickActionFailure.noSelection
        }
        guard text.utf8.count <= maxSelectionBytes else { throw QuickActionFailure.tooLong }
        return text
    }

    /// No transcript to grow, so a caller showing progress reads `onDelta` and the rest just await.
    static func run(
        _ action: QuickAction, selection: String, using provider: any AIProvider,
        instructionOverride: String?, context: QuickActionContext? = nil,
        selectionIsWritingInstruction: Bool = false, audience: ComposerAudience? = nil,
        screenshot: RewriteConversationMessage.Screenshot? = nil, hasScreenshot: Bool = false,
        onDelta: @MainActor (String) -> Void = { _ in }
    ) async throws -> String {
        let instructions =
            selectionIsWritingInstruction
            ? QuickActionPrompt.compositionInstructions(
                override: instructionOverride, audience: audience)
            : QuickActionPrompt.instructions(
                for: action, override: instructionOverride, audience: audience)
        let message =
            selectionIsWritingInstruction
            ? QuickActionPrompt.compositionMessage(instruction: selection, context: context)
            : QuickActionPrompt.message(for: action, selection: selection, context: context)
        // Edited instructions can ask for more than the selection, as a custom action's can. Only
        // the on-device window needs a selection-sized cap: a remote thinking model spends the
        // same budget on thinking, so a short selection would leave it no room to answer.
        let outgrowsSelection = selectionIsWritingInstruction || instructionOverride != nil
            || !(provider is AppleIntelligenceProvider)
        let request = AIRequest(
            instructions: screenshotInstructions(instructions, attached: hasScreenshot, visible: screenshot != nil),
            messages: [AIMessage(role: .user, text: message, images: imageInput(screenshot))],
            maxOutputTokens: QuickActionPrompt.maxOutputTokens(
                for: action, selection: selection, outgrowsSelection: outgrowsSelection))
        let text = try await stream(
            request, using: provider,
            selectionSized: QuickActionPrompt.budgetFollowsSelection(
                for: action, outgrowsSelection: outgrowsSelection),
            onDelta: onDelta)
        return try action == .rewrite
            ? composerDraft(text, source: selectionIsWritingInstruction ? "" : selection) : text
    }

    static func refineRewrite(
        original: String, latestDraft: String, messages: [AIMessage],
        context: QuickActionContext?, using provider: any AIProvider,
        instructionOverride: String?, originalIsWritingInstruction: Bool = false,
        audience: ComposerAudience? = nil,
        screenshot: RewriteConversationMessage.Screenshot? = nil, hasScreenshot: Bool = false,
        onDelta: @MainActor (String) -> Void = { _ in }
    ) async throws -> String {
        let originalMessage = AIMessage(
            role: .user,
            text: originalIsWritingInstruction
                ? QuickActionPrompt.compositionMessage(instruction: original, context: context)
                : QuickActionPrompt.message(
                    for: .rewrite, selection: original, context: context))
        var turns = [originalMessage] + messages
        if let index = turns.lastIndex(where: { $0.role == .user }), let screenshot {
            turns[index] = AIMessage(role: .user, text: turns[index].text, images: imageInput(screenshot))
        }
        let instructions = QuickActionPrompt.refinementInstructions(
                override: instructionOverride,
                originalIsWritingInstruction: originalIsWritingInstruction,
                audience: audience)
        let request = AIRequest(
            instructions: screenshotInstructions(instructions, attached: hasScreenshot, visible: screenshot != nil),
            messages: turns,
            maxOutputTokens: QuickActionPrompt.maxOutputTokens(
                for: .rewrite, selection: latestDraft, outgrowsSelection: true))
        return try composerDraft(
            try await stream(request, using: provider, selectionSized: false, onDelta: onDelta),
            source: latestDraft)
    }

    private static func imageInput(_ screenshot: RewriteConversationMessage.Screenshot?) -> [AIImage] {
        screenshot.map { [AIImage(data: $0.png, mimeType: "image/png")] } ?? []
    }

    private static func screenshotInstructions(_ instructions: String, attached: Bool, visible: Bool) -> String {
        guard attached else { return instructions }
        return instructions + "\n\n" + RewriteConversationMessage.Screenshot.instructions
            + (visible ? "" : "\nThis model cannot see the screenshot. Do not describe its contents.")
    }

    private static func composerDraft(_ text: String, source: String) throws -> String {
        guard !QuickActionOutput.composerBody(in: text, source: source).isEmpty else {
            throw AIProviderError.responseFailed("The model returned a subject with no message.")
        }
        return text
    }

    private static func stream(
        _ request: AIRequest, using provider: any AIProvider, selectionSized: Bool,
        onDelta: @MainActor (String) -> Void
    ) async throws -> String {
        var text = ""
        for try await event in provider.stream(request) {
            // A cut-off reply would replace the whole selection with part of it.
            if event == .outputLimitReached {
                throw QuickActionFailure.replyTooLong(selectionSized: selectionSized)
            }
            guard case .text(let delta) = event else { continue }
            text += delta
            onDelta(delta)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AIProviderError.responseFailed(String(localized: "The model returned nothing."))
        }
        return trimmed
    }
}

extension QuickActionRunner {
    enum ScreenshotReader {
        nonisolated private static let maximumFileBytes = 64 * 1_048_576

        enum Failure: LocalizedError {
            case unreadable
            case clipboardChanged

            var errorDescription: String? {
                switch self {
                case .unreadable: "Couldn't read a screenshot from the clipboard. Copy it again and paste here."
                case .clipboardChanged: "The clipboard changed while attaching. Paste the screenshot again."
                }
            }
        }

        static func hasCandidate(on board: NSPasteboard) -> Bool {
            let types = Set(board.types ?? [])
            return !types.isDisjoint(with: [.png, .tiff, .fileURL, .init("NSFilenamesPboardType")])
                || !types.isDisjoint(with: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
                || pathURL(board.string(forType: .string) ?? "") != nil
        }

        static func read(from board: NSPasteboard, promiseRoot: URL) async throws
            -> RewriteConversationMessage.Screenshot
        {
            let count = board.changeCount
            var urls = PasteboardFiles.urls(on: board).prefix(32).filter { local($0) }
            if let url = pathURL(board.string(forType: .string) ?? "") { urls.append(url) }
            let receivers = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
            let image: RewriteConversationMessage.Screenshot?
            if let file = await fileImage(urls) {
                image = file
            } else if !receivers.isEmpty {
                image = try await promisedImage(receivers, root: promiseRoot)
            } else {
                guard board.changeCount == count else { throw Failure.clipboardChanged }
                var bitmap: RewriteConversationMessage.Screenshot?
                for type in [NSPasteboard.PasteboardType.png, .tiff] {
                    guard let data = board.data(forType: type) else { continue }
                    bitmap = await bitmapImage([data])
                    if bitmap != nil { break }
                }
                image = bitmap
            }
            try Task.checkCancellation()
            guard board.changeCount == count else { throw Failure.clipboardChanged }
            guard let image else { throw Failure.unreadable }
            return image
        }

        private static func local(_ url: URL) -> Bool {
            url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
        }

        private static func pathURL(_ text: String) -> URL? {
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if path.hasPrefix("file://"), let url = URL(string: path), local(url) { return url }
            guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }

        @concurrent private static func fileImage(_ urls: [URL]) async -> RewriteConversationMessage.Screenshot? {
            for url in urls {
                if Task.isCancelled { return nil }
                if let image = readFile(url) { return image }
            }
            return nil
        }

        @concurrent private static func bitmapImage(_ values: [Data]) async -> RewriteConversationMessage.Screenshot? {
            for data in values {
                if Task.isCancelled { return nil }
                if let image = decode(data, fallbackDPI: 72) { return image }
            }
            return nil
        }

        nonisolated private static func readFile(_ url: URL) -> RewriteConversationMessage.Screenshot? {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true, let bytes = values.fileSize, bytes <= maximumFileBytes,
                let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            else { return nil }
            let retina = url.deletingPathExtension().lastPathComponent.hasSuffix("@2x")
            return decode(data, fallbackDPI: retina ? 144 : 72)
        }

        nonisolated private static func decode(_ data: Data, fallbackDPI: Double)
            -> RewriteConversationMessage.Screenshot?
        {
            guard data.count <= maximumFileBytes,
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Double,
                let height = properties[kCGImagePropertyPixelHeight] as? Double,
                let fit = RewriteConversationMessage.Screenshot.fittedSize(
                    pixelWidth: width, pixelHeight: height,
                    dpi: properties[kCGImagePropertyDPIWidth] as? Double ?? fallbackDPI),
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(fit.pixelsWide, fit.pixelsHigh)
                ] as CFDictionary)
            else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyDPIWidth: Double(image.width) / fit.width * 96,
                kCGImagePropertyDPIHeight: Double(image.height) / fit.height * 96
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination), output.length <= AIAttachmentBudget.maxBytes else { return nil }
            return .init(png: output as Data, pixelWidth: image.width, pixelHeight: image.height,
                width: fit.width, height: fit.height)
        }

        static func promisedImage(_ receivers: [NSFilePromiseReceiver], root: URL, attempts: Int = 80) async throws
            -> RewriteConversationMessage.Screenshot?
        {
            let directory = root.appending(path: "composer-promise-" + UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let result = Mutex<(image: RewriteConversationMessage.Screenshot?, completed: Int, closed: Bool)>((nil, 0, false))
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            defer {
                result.withLock { $0.closed = true }
                try? FileManager.default.removeItem(at: directory)
            }
            for receiver in receivers.prefix(32) {
                receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { url, error in
                    if result.withLock({ $0.closed }) {
                        try? FileManager.default.removeItem(at: directory)
                        return
                    }
                    let image = error == nil ? readFile(url) : nil
                    let closed = result.withLock { value in
                        value.image = value.image ?? image
                        value.completed += 1
                        return value.closed
                    }
                    if closed { try? FileManager.default.removeItem(at: directory) }
                }
            }
            let expected = receivers.prefix(32).reduce(0) { $0 + max(1, $1.fileNames.count) }
            for _ in 0..<attempts {
                try Task.checkCancellation()
                if result.withLock({ $0.image != nil || $0.completed >= expected }) { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            return result.withLock { $0.image }
        }
    }

    enum ScreenshotDelivery {
        @concurrent static func item(
            text: String, offset: Int?, image: RewriteConversationMessage.Screenshot
        ) async throws -> sending NSPasteboardItem {
            let parts = RewriteConversationMessage.Screenshot.parts(text, offset: offset)
            let before = parts.before.isEmpty || parts.before.hasSuffix("\n") ? parts.before : parts.before + "\n\n"
            let after = parts.after.isEmpty || parts.after.hasPrefix("\n") ? parts.after : "\n\n" + parts.after
            guard let bitmap = NSBitmapImageRep(data: image.png) else { throw ScreenshotReader.Failure.unreadable }
            let size = NSSize(width: image.width * 0.75, height: image.height * 0.75)
            bitmap.size = size
            guard let tiff = bitmap.representation(using: .tiff, properties: [:]) else {
                throw ScreenshotReader.Failure.unreadable
            }
            let file = FileWrapper(regularFileWithContents: tiff)
            file.preferredFilename = "Screenshot.tiff"
            let attachment = NSTextAttachment(fileWrapper: file)
            attachment.bounds = CGRect(origin: .zero, size: size)
            let rich = NSMutableAttributedString(string: before)
            rich.append(NSAttributedString(attachment: attachment))
            rich.append(NSAttributedString(string: after))
            let rtfd = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtfd
            ])
            let html = "<html><head><meta charset=\"utf-8\"></head><body>" + htmlText(before)
                + "<img src=\"data:image/png;base64,\(image.png.base64EncodedString())\" "
                + "width=\"\(image.width)\" height=\"\(image.height)\" "
                + "style=\"width:\(image.width)px;height:\(image.height)px;max-width:100%;\" alt=\"Screenshot\">"
                + htmlText(after) + "</body></html>"
            let item = NSPasteboardItem()
            guard item.setData(rtfd, forType: .rtfd), item.setString(html, forType: .html),
                item.setString(text, forType: .string)
            else { throw ScreenshotReader.Failure.unreadable }
            return item
        }

        nonisolated private static func htmlText(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
    }
}
