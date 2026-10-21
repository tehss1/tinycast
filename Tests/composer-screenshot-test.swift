import AppKit
import Synchronization

@MainActor
enum Permissions {
    static func ensureAccessibility() -> Bool { false }
}

@MainActor
enum AccessibilityText {
    enum Read: Equatable { case text(String), empty, unavailable }
    static func read(in app: NSRunningApplication) -> Read { .unavailable }
    static func hasInsertionPoint(in app: NSRunningApplication) -> Bool { false }
}

@MainActor
final class TextInjector {
    func copySelection(from app: NSRunningApplication) async -> String? { nil }
}

struct AppleIntelligenceProvider: AIProvider {
    func stream(_ request: AIRequest) -> AIProviderStream { AIProviderStream { $0.finish() } }
}

final class RecordingProvider: AIProvider {
    let request = Mutex<AIRequest?>(nil)
    func stream(_ value: AIRequest) -> AIProviderStream {
        request.withLock { $0 = value }
        return AIProviderStream {
            $0.yield(.text("Screenshot below:\n" + RewriteConversationMessage.Screenshot.marker + "\nSteps"))
            $0.finish()
        }
    }
}

final class ScreenshotPromiseFixture: NSFilePromiseReceiver {
    let png: Data
    let fulfills: Bool

    init(png: Data, fulfills: Bool = true) {
        self.png = png
        self.fulfills = fulfills
        super.init()
    }

    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) { nil }

    override func receivePromisedFiles(atDestination directory: URL, options: [AnyHashable: Any] = [:],
        operationQueue: OperationQueue, reader: @escaping (URL, (any Error)?) -> Void)
    {
        guard fulfills else { return }
        let url = directory.appending(path: "Promised screenshot.png")
        do {
            try png.write(to: url)
            reader(url, nil)
        } catch { reader(url, error) }
    }
}

final class ScreenshotPromiseProviderFixture: NSObject, NSFilePromiseProviderDelegate, Sendable {
    let png: Data
    let queue = OperationQueue()

    init(png: Data) { self.png = png }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType type: String) -> String {
        "Promised screenshot.png"
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void)
    {
        do {
            try png.write(to: url)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }
}

@MainActor
final class MarkedScreenshotField: QuickActionPanel.RequestEditor {
    override func hasMarkedText() -> Bool { true }
}

@main
@MainActor
struct ComposerScreenshotTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "composer-screenshot-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let png = try image(width: 1600, height: 1000)
        let file = root.appending(path: "Screen shot @2x.png")
        try png.write(to: file)
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        item.setString(file.path, forType: .string)
        item.setData(try image(width: 16, height: 16), forType: .tiff)
        expect(board.writeObjects([item]), "mixed file/icon fixture writes")
        let captured = try await QuickActionRunner.ScreenshotReader.read(from: board, promiseRoot: root)
        expect(captured.width == 640 && captured.height == 400, "file image wins over generic file icon")
        expect(captured.pixelWidth == 1280 && captured.pixelHeight == 800, "retains at most 2x pixels")
        board.clearContents()
        board.setPropertyList([file.path], forType: .init("NSFilenamesPboardType"))
        let legacy = try await QuickActionRunner.ScreenshotReader.read(from: board, promiseRoot: root)
        expect(legacy.width == captured.width, "legacy filename list attaches")
        board.clearContents()
        board.setData(png, forType: .png)
        let bitmap = try await QuickActionRunner.ScreenshotReader.read(from: board, promiseRoot: root)
        expect(bitmap.width == 640, "raw PNG attaches")
        board.clearContents()
        let small = try image(width: 240, height: 160)
        let rep = NSBitmapImageRep(data: small)!
        board.setData(rep.representation(using: .tiff, properties: [:])!, forType: .tiff)
        let tiff = try await QuickActionRunner.ScreenshotReader.read(from: board, promiseRoot: root)
        expect(tiff.width == 240 && tiff.pixelWidth == 240, "TIFF attaches without upscaling")
        board.clearContents()
        board.setString(file.path, forType: .string)
        let path = try await QuickActionRunner.ScreenshotReader.read(from: board, promiseRoot: root)
        expect(path.width == 640, "absolute text path attaches instead of inserting text")
        board.clearContents()
        board.setString("https://example.com/screenshot.png", forType: .string)
        expect(!QuickActionRunner.ScreenshotReader.hasCandidate(on: board), "remote URL is never fetched")
        board.clearContents()
        board.setData(Data([0, 1, 2]), forType: .png)
        do {
            _ = try await QuickActionRunner.ScreenshotReader.read(from: board, promiseRoot: root)
            fatalError("invalid image must report failure")
        } catch is QuickActionRunner.ScreenshotReader.Failure { checks += 1 }
        let promised = try await QuickActionRunner.ScreenshotReader.promisedImage(
            [ScreenshotPromiseFixture(png: png)], root: root)
        expect(promised?.width == 640, "file promise attaches screenshot")
        let timedOut = try await QuickActionRunner.ScreenshotReader.promisedImage(
            [ScreenshotPromiseFixture(png: png, fulfills: false)], root: root, attempts: 1)
        expect(timedOut == nil, "unfulfilled promise times out")
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        expect(contents.allSatisfy {
            !$0.hasPrefix("composer-promise-")
        }, "promise scratch removed after success and timeout")
        try await pasteRouting(board: board, file: file, png: png, root: root)
        try await delivery(captured)
        try await providers(captured)
        print("\(checks) screenshot checks passed")
    }

    static func pasteRouting(board: NSPasteboard, file: URL, png: Data, root: URL) async throws {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let editor = QuickActionPanel.RequestEditor(frame: content.bounds)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.pasteboard = board
        content.addSubview(editor)
        let panel = QuickActionPanel(content: content)
        panel.onKey = { _ in fatalError("paste is not a delivery shortcut") }
        expect(!editor.isFieldEditor, "multiline request is a text view, not a field editor")
        expect(panel.makeFirstResponder(editor), "request field accepts focus without showing a window")
        var attachments = 0
        editor.onPasteScreenshot = { board in
            guard QuickActionRunner.ScreenshotReader.hasCandidate(on: board) else { return false }
            attachments += 1
            return true
        }
        func reset() {
            board.clearContents()
            editor.string = "testing "
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        }
        let media = root.appending(
            path: "Library/Application Support/CleanShot/media/media_Wy1LFDcQMj", directoryHint: .isDirectory)
        let cleanShot = media.appending(path: "CleanShot 2026-10-20 at 9.23.25 PM@2x.png")
        try FileManager.default.createDirectory(at: cleanShot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: cleanShot)
        reset()
        let item = NSPasteboardItem()
        item.setString(cleanShot.absoluteString, forType: .fileURL)
        item.setString(cleanShot.path, forType: .string)
        expect(board.writeObjects([item]), "CleanShot file URL and plain path fixture writes")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        expect(editor.performKeyEquivalent(with: event), "command-V reaches the request responder")
        expect(attachments == 1 && editor.string == "testing ", "command-V consumes file URL and path without insertion")
        let mixed = try await QuickActionRunner.ScreenshotReader.read(from: board, promiseRoot: root)
        expect(mixed.width == 640, "intercepted CleanShot fixture decodes through chip reader")
        reset()
        board.setString(cleanShot.path, forType: .string)
        let menu = NSMenu()
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.target = editor
        menu.addItem(paste)
        expect(NSApp.sendAction(paste.action!, to: editor, from: paste), "Edit menu dispatches directly to paste action")
        expect(attachments == 2 && editor.string == "testing ", "menu Paste consumes a plain path with spaces and @2x")
        let textPath = try await QuickActionRunner.ScreenshotReader.read(from: board, promiseRoot: root)
        expect(textPath.pixelWidth == 1280, "plain path reader retains Retina image")
        reset()
        board.setString(file.absoluteString, forType: .fileURL)
        board.setData(png, forType: .png)
        expect(editor.readSelection(from: board), "context Paste handles PNG plus file URL")
        expect(attachments == 3 && editor.string == "testing ", "context Paste attaches once without path text")
        let pngAndFile = try await QuickActionRunner.ScreenshotReader.read(from: board, promiseRoot: root)
        expect(pngAndFile.width == 640 && pngAndFile.pixelWidth == 1280, "PNG plus file URL decodes through chip reader")
        reset()
        board.setString(cleanShot.absoluteString, forType: .string)
        expect(editor.readSelection(from: board, type: .string), "typed selection reader handles file URL text")
        expect(attachments == 4 && editor.string == "testing ", "file URL text is consumed")
        reset()
        board.setPropertyList([file.path], forType: .init("NSFilenamesPboardType"))
        expect(editor.readSelection(from: board), "legacy filename list attaches through untyped selection reader")
        expect(attachments == 5 && editor.string == "testing ", "legacy filenames do not enter the request")
        reset()
        let promiseDelegate = ScreenshotPromiseProviderFixture(png: png)
        let promise = NSFilePromiseProvider(fileType: "public.png", delegate: promiseDelegate)
        expect(board.writeObjects([promise]), "isolated board accepts real image file promise")
        expect(editor.validateUserInterfaceItem(paste), "Paste menu remains enabled for an image-only promise")
        expect(editor.readSelection(from: board), "promise Paste consumes unresolved image promise")
        expect(attachments == 6 && editor.string == "testing ", "promise paste attaches before any filename resolves")
        reset()
        board.setString("ordinary text", forType: .string)
        editor.paste(nil)
        expect(attachments == 6 && editor.string == "testing ordinary text", "ordinary text pastes after existing text")
        editor.undoManager?.undo()
        expect(editor.string == "testing ", "ordinary Paste remains undoable")
        editor.undoManager?.redo()
        expect(editor.string == "testing ordinary text", "ordinary Paste remains redoable")
        let document = root.appending(path: "notes.txt")
        try Data("not an image".utf8).write(to: document)
        reset()
        board.setString(document.path, forType: .string)
        board.setString(document.absoluteString, forType: .fileURL)
        editor.paste(nil)
        expect(attachments == 6 && editor.string == "testing " + document.path, "non-image file URL and path paste as text")
        reset()
        board.setString(root.appending(path: "missing.png").path, forType: .string)
        editor.paste(nil)
        expect(attachments == 6 && editor.string.contains("missing.png"), "missing image paths remain ordinary text")
        var recovered: [URL] = []
        editor.onPasteImageFiles = { recovered = $0; return true }
        editor.onPasteScreenshot = { _ in false }
        reset()
        board.setString(cleanShot.path, forType: .string)
        editor.paste(nil)
        expect(editor.string == "testing " && recovered == [cleanShot],
            "post-paste safety net strips only the inserted image path")
        let references = QuickActionRunner.ScreenshotReader.imageReferences(in: "testing " + cleanShot.path + " then explain it")
        expect(references.text == "testing  then explain it" && references.urls == [cleanShot],
            "submit guard removes embedded CleanShot path while retaining request text")
        let nested = QuickActionRunner.ScreenshotReader.imageReferences(in: "Ignore /missing and describe " + cleanShot.path)
        expect(nested.text == "Ignore /missing and describe " && nested.urls == [cleanShot],
            "submit guard finds an image path after unrelated slash text")
        board.clearContents()
        board.setString("newer unrelated clipboard text", forType: .string)
        expect(!QuickActionRunner.ScreenshotReader.hasCandidate(on: board), "submit fixture has a changed, text-only clipboard")
        let recoveredImage = try await QuickActionRunner.ScreenshotReader.readFiles(references.urls)
        expect(recoveredImage.width == 640, "submit guard resolves image independently of current clipboard")
        let urlReferences = QuickActionRunner.ScreenshotReader.imageReferences(in: "Describe " + cleanShot.absoluteString)
        expect(urlReferences.text == "Describe " && urlReferences.urls == [cleanShot], "submit guard removes encoded file URLs")
        expect(QuickActionRunner.ScreenshotReader.imageReferences(in: "Keep " + document.path).urls.isEmpty,
            "submit guard keeps non-image paths")
        let marked = MarkedScreenshotField(frame: content.bounds)
        marked.pasteboard = board
        marked.string = "Keep marked text"
        marked.onPasteScreenshot = { _ in attachments += 1; return true }
        content.addSubview(marked)
        expect(panel.makeFirstResponder(marked), "marked request editor accepts focus")
        expect(marked.performKeyEquivalent(with: event), "image paste routes during composition")
        expect(attachments == 7 && marked.string == "Keep marked text", "image attachment preserves marked text")
        panel.close()
    }

    static func image(width: Int, height: Int) throws -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 128, bitmap.bytesPerRow * height)
        return bitmap.representation(using: .png, properties: [:])!
    }

    static func delivery(_ image: RewriteConversationMessage.Screenshot) async throws {
        let text = "Before <&>\n\nSteps"
        let item = try await QuickActionRunner.ScreenshotDelivery.item(text: text, offset: 12, image: image)
        expect(item.string(forType: .string) == text, "plain text is exactly marker-free draft")
        let html = item.string(forType: .html)!
        expect(html.contains("width=\"640.0\"") && html.contains("height=\"400.0\""), "HTML carries explicit CSS sizes")
        expect(html.contains("Before &lt;&amp;&gt;") && html.contains("data:image/png;base64,"),
            "HTML escapes text and embeds PNG")
        expect(html.range(of: "<img")!.lowerBound < html.range(of: "Steps")!.lowerBound, "HTML puts image before steps")
        let rich = try NSAttributedString(data: item.data(forType: .rtfd)!, options: [
            .documentType: NSAttributedString.DocumentType.rtfd
        ], documentAttributes: nil)
        let range = (rich.string as NSString).range(of: "\u{fffc}")
        expect(range.location != NSNotFound, "RTFD contains inline attachment")
        let attachment = rich.attribute(.attachment, at: range.location, effectiveRange: nil) as! NSTextAttachment
        let decoded = NSBitmapImageRep(data: attachment.fileWrapper!.regularFileContents!)!
        expect(decoded.pixelsWide == 1280 && decoded.pixelsHigh == 800, "TIFF retains retina resolution")
        expect(abs(decoded.size.width - 480) < 1 && abs(decoded.size.height - 300) < 1, "RTFD uses 480pt for 640 CSS px")
        expect(!rich.string.contains(RewriteConversationMessage.Screenshot.marker), "RTFD never carries marker")
    }

    static func providers(_ image: RewriteConversationMessage.Screenshot) async throws {
        let provider = RecordingProvider()
        _ = try await QuickActionRunner.run(.rewrite, selection: "Explain the screenshot", using: provider,
            instructionOverride: nil, screenshot: image, hasScreenshot: true)
        let initial = provider.request.withLock { $0! }
        expect(initial.messages.first?.images.first?.data == image.png, "initial request carries PNG bytes")
        expect(initial.instructions?.contains(RewriteConversationMessage.Screenshot.marker) == true,
            "request defines marker contract")
        _ = try await QuickActionRunner.refineRewrite(original: "Source", latestDraft: "Draft", messages: [
            .init(role: .assistant, text: "Old draft"), .init(role: .user, text: "Move image above steps")
        ], context: nil, using: provider, instructionOverride: nil, screenshot: image, hasScreenshot: true)
        let refinement = provider.request.withLock { $0! }
        expect(refinement.messages.last?.images.first?.data == image.png, "refinement attaches to latest user turn")
        expect(refinement.messages.dropLast().allSatisfy { $0.images.isEmpty }, "image sent only once per request")
        _ = try await QuickActionRunner.run(.rewrite, selection: "Notes", using: provider,
            instructionOverride: nil, hasScreenshot: true)
        let deliveryOnly = provider.request.withLock { $0! }
        expect(deliveryOnly.messages.allSatisfy { $0.images.isEmpty }, "unsupported provider receives no image")
        expect(deliveryOnly.instructions?.contains("cannot see") == true, "unsupported provider is told not to describe image")
    }
}
