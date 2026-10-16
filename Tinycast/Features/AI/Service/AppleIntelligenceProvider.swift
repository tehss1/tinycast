import FoundationModels
import Foundation

/// The only provider with nothing to configure, so a first run may select it unasked.
struct AppleIntelligenceProvider: AIProvider {
    /// The caller's, not a constant: the default filter refuses text the reader already wrote.
    let guardrails: SystemLanguageModel.Guardrails

    init(guardrails: SystemLanguageModel.Guardrails = .default) {
        self.guardrails = guardrails
    }

    static func status() -> AppleIntelligenceStatus {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        @unknown default: return .modelNotReady
        }
    }

    func stream(_ request: AIRequest) -> AIProviderStream {
        AIProviderStream { continuation in
            // Session and stream are born here: `ResponseStream` is `sending` and cannot cross.
            let task = Task.detached {
                do {
                    if let message = Self.status().message {
                        throw AIProviderError.unavailable(message)
                    }
                    let turn = Self.turn(for: request)
                    guard let prompt = turn.prompt else {
                        throw AIProviderError.responseFailed("There was nothing to send.")
                    }
                    let model = SystemLanguageModel(guardrails: guardrails)
                    let session = LanguageModelSession(model: model, transcript: turn.transcript)
                    let limit = min(request.maxOutputTokens, AppleIntelligence.maxOutputTokens)
                    let options = GenerationOptions(maximumResponseTokens: limit)
                    var delta = AppleIntelligenceDelta()
                    var reply = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        try Task.checkCancellation()
                        let text = delta.delta(from: snapshot.content)
                        reply = snapshot.content
                        if !text.isEmpty { continuation.yield(.text(text)) }
                    }
                    if await Self.reachedLimit(limit, with: reply, of: model) {
                        continuation.yield(.outputLimitReached)
                    }
                    continuation.yield(.finished)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: Self.providerError(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The session stops at the limit without saying so, so the reply is counted again. Re-tokenizing
    /// can differ by a token or two; a reply that ends that close to the cap is cut off in practice.
    private static func reachedLimit(
        _ limit: Int, with reply: String, of model: SystemLanguageModel
    ) async -> Bool {
        guard #available(macOS 26.4, *),
            let count = try? await model.tokenCount(for: reply)
        else { return false }
        return count >= limit - 4
    }

    /// Split the way a session takes it: the newest user turn is the prompt, the rest a transcript.
    static func turn(for request: AIRequest) -> (prompt: String?, transcript: Transcript) {
        var entries: [Transcript.Entry] = []
        if let instructions = request.instructions, !instructions.isEmpty {
            entries.append(
                .instructions(
                    Transcript.Instructions(
                        segments: [.text(Transcript.TextSegment(content: instructions))],
                        toolDefinitions: [])))
        }
        let promptIndex = request.messages.lastIndex { $0.role == .user }
        for message in request.messages[..<(promptIndex ?? request.messages.endIndex)]
        where !message.text.isEmpty {
            let segment = Transcript.Segment.text(Transcript.TextSegment(content: message.text))
            switch message.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(segments: [segment])))
            case .assistant:
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [segment])))
            // The on-device route offers no tools, so a tool turn can only be foreign history.
            case .system, .tool:
                continue
            }
        }
        let prompt = promptIndex.map {
            request.messages[$0].text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (prompt?.isEmpty == true ? nil : prompt, Transcript(entries: entries))
    }

    /// Plain sentences: the only detail these carry is a `debugDescription` written for a log.
    static func providerError(_ error: LanguageModelSession.GenerationError) -> AIProviderError {
        switch error {
        case .exceededContextWindowSize:
            return .responseFailed(
                "This conversation is longer than the on-device model can hold. Start a new chat.")
        case .guardrailViolation, .refusal:
            return .responseFailed("Apple Intelligence declined to answer that.")
        case .unsupportedLanguageOrLocale:
            return .responseFailed("Apple Intelligence does not support this language yet.")
        case .assetsUnavailable:
            return .unavailable("Apple Intelligence is still downloading its model.")
        case .rateLimited:
            return .responseFailed("Apple Intelligence is busy. Try again shortly.")
        case .concurrentRequests:
            return .responseFailed("Apple Intelligence is already answering. Try again shortly.")
        case .decodingFailure, .unsupportedGuide:
            return .malformedResponse
        @unknown default:
            return .responseFailed("Apple Intelligence could not complete the response.")
        }
    }
}
