import Foundation

#if canImport(FoundationModels)
@_weakLinked import FoundationModels
#endif

// MARK: - Public namespace (called from Commands.swift)

enum FoundationModelsExecution {

    static func respond(
        opts:   RespondOptions,
        output: UnsafeMutablePointer<FILE>,
        error:  UnsafeMutablePointer<FILE>
    ) -> Int32 {
        guard #available(iOS 27.0, macOS 27.0, *) else {
            fputs("fm: Foundation Models requires iOS 27 / macOS 27 or later\n", error)
            return 69
        }
        #if canImport(FoundationModels)
        return _respond(opts: opts, output: output, error: error)
        #else
        fputs("fm: FoundationModels framework not available in this build\n", error)
        return 69
        #endif
    }

    static func chat(
        opts:   ChatOptions,
        input:  UnsafeMutablePointer<FILE>,
        output: UnsafeMutablePointer<FILE>,
        error:  UnsafeMutablePointer<FILE>
    ) -> Int32 {
        guard #available(iOS 27.0, macOS 27.0, *) else {
            fputs("fm: Foundation Models requires iOS 27 / macOS 27 or later\n", error)
            return 69
        }
        #if canImport(FoundationModels)
        return _chat(opts: opts, input: input, output: output, error: error)
        #else
        fputs("fm: FoundationModels framework not available in this build\n", error)
        return 69
        #endif
    }

    static func tokenCount(
        opts:   TokenCountOptions,
        input:  UnsafeMutablePointer<FILE>,
        output: UnsafeMutablePointer<FILE>,
        error:  UnsafeMutablePointer<FILE>
    ) -> Int32 {
        guard #available(iOS 27.0, macOS 27.0, *) else {
            fputs("fm: Foundation Models requires iOS 27 / macOS 27 or later\n", error)
            return 69
        }
        #if canImport(FoundationModels)
        return _tokenCount(opts: opts, input: input, output: output, error: error)
        #else
        fputs("fm: FoundationModels framework not available in this build\n", error)
        return 69
        #endif
    }

    static func available(
        model:  String?,
        output: UnsafeMutablePointer<FILE>,
        error:  UnsafeMutablePointer<FILE>
    ) -> Int32 {
        guard #available(iOS 27.0, macOS 27.0, *) else {
            for m in model.map({ [$0] }) ?? ["system", "pcc"] {
                fputs("\(m): unavailable (requires iOS 27 / macOS 27)\n", output)
            }
            return 0
        }
        #if canImport(FoundationModels)
        return _available(model: model, output: output, error: error)
        #else
        for m in model.map({ [$0] }) ?? ["system", "pcc"] {
            fputs("\(m): unavailable (FoundationModels not in build)\n", output)
        }
        return 0
        #endif
    }
}

// MARK: - AFM implementations (iOS 27 / macOS 27+)

#if canImport(FoundationModels)

// MARK: respond

@available(iOS 27.0, macOS 27.0, *)
private func _respond(
    opts:   RespondOptions,
    output: UnsafeMutablePointer<FILE>,
    error:  UnsafeMutablePointer<FILE>
) -> Int32 {
    let sem = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task {
        defer { sem.signal() }
        do {
            // Instructions — merge caller's with schema injection
            var instrParts: [String] = []
            if let i = opts.instructions, !i.isEmpty { instrParts.append(i) }

            var schemaMode = false
            if let schemaPath = opts.schemaPath {
                let resolved = resolvePath(schemaPath)
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)),
                      let json = String(data: data, encoding: .utf8)
                else {
                    fputs("fm: cannot read schema file: \(schemaPath)\n", error)
                    exitCode = 66; return
                }
                instrParts.append("""
                    Return only a JSON object matching this schema exactly. \
                    Do not include Markdown code fences, explanations, or any \
                    text outside the JSON object.

                    \(json)
                    """)
                schemaMode = true
            }

            let instrText = instrParts.joined(separator: "\n\n")

            // Build session — use concrete model types (avoids `any LanguageModel`)
            let session = _makeSession(model: opts.model, instructions: instrText)

            if opts.verbose {
                fputs("[fm] model: \(opts.model == "pcc" ? "Private Cloud Compute" : "on-device system")\n", error)
                if let firstInstr = instrParts.first { fputs("[fm] instructions: \(firstInstr)\n", error) }
                if !opts.images.isEmpty { fputs("[fm] images: \(opts.images.joined(separator: ", "))\n", error) }
                if let sp = opts.schemaPath { fputs("[fm] schema: \(sp)\n", error) }
                fflush(error)
            }

            // Build GenerationOptions
            var genOpts = GenerationOptions()
            if opts.greedy { genOpts.samplingMode = .greedy }

            // Build prompt — multimodal or plain text
            let textParts = ([opts.prompt ?? ""] + opts.texts).filter { !$0.isEmpty }
            let combinedText = textParts.joined(separator: "\n")

            // Build the multimodal prompt up front so a bad image fails early.
            var multimodalPrompt: Prompt? = nil
            if !opts.images.isEmpty {
                guard let p = _buildMultimodalPrompt(
                    text: combinedText, imagePaths: opts.images, errFile: error
                ) else { exitCode = 66; return }
                multimodalPrompt = p
            }

            // Run the model call inside runInterruptible so Ctrl-C cancels it.
            let box = ErrorBox()
            let completed = await runInterruptible {
                do {
                    if opts.stream && !schemaMode {
                        // Stream tokens as they arrive.
                        if let prompt = multimodalPrompt {
                            var lastLen = 0
                            for try await partial in session.streamResponse(to: prompt, options: genOpts) {
                                try Task.checkCancellation()
                                let full = partial.content
                                if full.count > lastLen { fputs(String(full.suffix(full.count - lastLen)), output); fflush(output); lastLen = full.count }
                            }
                        } else {
                            var lastLen = 0
                            for try await partial in session.streamResponse(to: combinedText, options: genOpts) {
                                try Task.checkCancellation()
                                let full = partial.content
                                if full.count > lastLen { fputs(String(full.suffix(full.count - lastLen)), output); fflush(output); lastLen = full.count }
                            }
                        }
                        fputs("\n", output); fflush(output)
                    } else {
                        let content: String
                        if let prompt = multimodalPrompt {
                            content = try await session.respond(to: prompt, options: genOpts).content
                        } else {
                            content = try await session.respond(to: combinedText, options: genOpts).content
                        }
                        fputs((schemaMode ? extractJSON(from: content) : content) + "\n", output); fflush(output)
                    }
                } catch is CancellationError {
                    // Surfaced via completed == false.
                } catch {
                    box.error = error
                }
            }
            if !completed {
                fputs("\n^C\n", output); fflush(output)
                exitCode = 130
            } else if let e = box.error {
                exitCode = _handleError(e, errFile: error)
            }
        } catch let caughtError {
            exitCode = _handleError(caughtError, errFile: error)
        }
    }

    sem.wait()
    return exitCode
}

// MARK: chat

@available(iOS 27.0, macOS 27.0, *)
private func _chat(
    opts:   ChatOptions,
    input:  UnsafeMutablePointer<FILE>,
    output: UnsafeMutablePointer<FILE>,
    error:  UnsafeMutablePointer<FILE>
) -> Int32 {
    let isInteractive = isatty(fileno(input)) != 0
    let sem = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task {
        defer { sem.signal() }
        do {
            let session = _makeSession(model: opts.model, instructions: opts.instructions ?? "")

            if isInteractive {
                fputs("fm chat — type /exit or /quit to end, /help for commands\n", output)
                fflush(output)
            }

            var buf = [CChar](repeating: 0, count: 8192)
            loop: while true {
                if isInteractive { fputs("> ", output); fflush(output) }
                guard fgets(&buf, Int32(buf.count), input) != nil else { break }
                let line = String(cString: buf).trimmingCharacters(in: .newlines)
                if line.isEmpty { continue }

                switch line {
                case "/exit", "/quit":
                    if isInteractive { fputs("Bye.\n", output) }
                    break loop
                case "/help":
                    fputs("/help    Show this help\n/exit    Exit chat\n/quit    Exit chat\n/model   Show current model\n\n", output)
                    fflush(output); continue
                case "/model":
                    fputs("Model: \(opts.model == "pcc" ? "pcc (Private Cloud Compute)" : "system (on-device)")\n", output)
                    fflush(output); continue
                default:
                    if line.hasPrefix("/") {
                        fputs("fm chat: '\(line)' is not supported\n", output)
                        fflush(output); continue
                    }
                }

                // Generation runs inside runInterruptible so Ctrl-C cancels it.
                let box = ErrorBox()
                let completed = await runInterruptible {
                    do {
                        let stream = session.streamResponse(to: line)
                        var lastLen = 0
                        for try await partial in stream {
                            try Task.checkCancellation()
                            let full = partial.content
                            if full.count > lastLen {
                                fputs(String(full.suffix(full.count - lastLen)), output)
                                fflush(output)
                                lastLen = full.count
                            }
                        }
                    } catch is CancellationError {
                        // Surfaced below as `completed == false`.
                    } catch {
                        box.error = error
                    }
                }
                if !completed {
                    fputs("\n^C\n", output); fflush(output)
                    continue
                }
                if let e = box.error { throw e }
                fputs("\n", output); fflush(output)
            }
        } catch let caughtError {
            exitCode = _handleError(caughtError, errFile: error)
        }
    }

    sem.wait()
    return exitCode
}

// MARK: token-count

@available(iOS 27.0, macOS 27.0, *)
private func _tokenCount(
    opts:   TokenCountOptions,
    input:  UnsafeMutablePointer<FILE>,
    output: UnsafeMutablePointer<FILE>,
    error:  UnsafeMutablePointer<FILE>
) -> Int32 {
    let sem = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task {
        defer { sem.signal() }
        do {
            let model = SystemLanguageModel()
            let allText = ([opts.instructions ?? "", opts.prompt ?? ""] + opts.texts)
                .filter { !$0.isEmpty }.joined(separator: "\n")

            let count: Int
            if opts.images.isEmpty {
                count = try await model.tokenCount(for: allText)
            } else {
                guard let prompt = _buildMultimodalPrompt(
                    text: allText, imagePaths: opts.images, errFile: error
                ) else { exitCode = 66; return }
                count = try await model.tokenCount(for: prompt)
            }

            let isTerminal = isatty(fileno(output)) != 0
            fputs(opts.quiet || !isTerminal ? "\(count)\n" : "Token count: \(count)\n", output)
            fflush(output)
        } catch let caughtError {
            fputs("fm: token counting unavailable: \(caughtError.localizedDescription)\n", error)
            exitCode = 69
        }
    }

    sem.wait()
    return exitCode
}

// MARK: available

@available(iOS 27.0, macOS 27.0, *)
private func _available(
    model:  String?,
    output: UnsafeMutablePointer<FILE>,
    error:  UnsafeMutablePointer<FILE>
) -> Int32 {
    let targets = model.map { [$0] } ?? ["system", "pcc"]
    let sem = DispatchSemaphore(value: 0)

    Task {
        defer { sem.signal() }
        for target in targets {
            do {
                let session = _makeSession(model: target, instructions: "")
                // Minimal probe — surfaces Apple Intelligence disabled / entitlement missing
                _ = try await session.respond(to: "hi")
                fputs("\(target): available\n", output)
            } catch {
                fputs("\(target): unavailable — \(_briefError(error))\n", output)
            }
            fflush(output)
        }
    }

    sem.wait()
    return 0
}

// MARK: - Shared helpers

/// Build a `LanguageModelSession` using the concrete model type for the
/// requested model (on-device `system` or Private Cloud Compute `pcc`).
@available(iOS 27.0, macOS 27.0, *)
private func _makeSession(model: String, instructions: String) -> LanguageModelSession {
    if model == "pcc" {
        let pcc = PrivateCloudComputeLanguageModel()
        if instructions.isEmpty {
            return LanguageModelSession(model: pcc)
        } else {
            return LanguageModelSession(model: pcc, instructions: Instructions(instructions))
        }
    } else {
        if instructions.isEmpty {
            return LanguageModelSession(model: SystemLanguageModel())
        } else {
            return LanguageModelSession(model: SystemLanguageModel(), instructions: Instructions(instructions))
        }
    }
}

/// Build a multimodal `Prompt` from text + file paths.
/// Uses `Attachment(imageURL:)` — no UIKit/AppKit dependency.
@available(iOS 27.0, macOS 27.0, *)
private func _buildMultimodalPrompt(
    text:       String,
    imagePaths: [String],
    errFile:    UnsafeMutablePointer<FILE>
) -> Prompt? {
    var attachments: [Attachment<ImageAttachmentContent>] = []
    for (i, path) in imagePaths.enumerated() {
        let url = URL(fileURLWithPath: resolvePath(path))
        guard FileManager.default.fileExists(atPath: url.path) else {
            fputs("fm: image file not found: \(path)\n", errFile)
            return nil
        }
        attachments.append(Attachment(imageURL: url).label("image_\(i)"))
    }

    return Prompt {
        text
        for att in attachments {
            att
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
private func _handleError(_ e: Error, errFile: UnsafeMutablePointer<FILE>) -> Int32 {
    if let le = e as? LanguageModelError {
        switch le {
        case .guardrailViolation:
            fputs("fm: content policy — guardrail triggered\n", errFile)
        case .refusal:
            fputs("fm: content policy — the model declined to respond\n", errFile)
        case .contextSizeExceeded:
            fputs("fm: context size exceeded — shorten the prompt\n", errFile)
        case .timeout:
            fputs("fm: request timed out\n", errFile)
        case .unsupportedLanguageOrLocale:
            fputs("fm: unsupported language or locale\n", errFile)
        default:
            fputs("fm: model error: \(le)\n", errFile)
        }
        return 70
    }
    if let sle = e as? SystemLanguageModel.Error {
        fputs("fm: Apple Intelligence unavailable: \(sle)\n", errFile)
        return 69
    }
    if let pce = e as? PrivateCloudComputeLanguageModel.Error {
        fputs("fm: Private Cloud Compute unavailable: \(pce)\n", errFile)
        fputs("fm: ensure the com.apple.developer.private-cloud-compute entitlement is present\n", errFile)
        return 69
    }
    fputs("fm: \(e.localizedDescription)\n", errFile)
    return 70
}

@available(iOS 27.0, macOS 27.0, *)
private func _briefError(_ e: Error) -> String {
    if let le = e as? LanguageModelError {
        switch le {
        case .guardrailViolation: return "guardrail violation"
        case .refusal:            return "refusal"
        case .contextSizeExceeded: return "context size exceeded"
        case .timeout:            return "timeout"
        case .unsupportedLanguageOrLocale: return "unsupported language/locale"
        default: return "\(le)"
        }
    }
    if e is SystemLanguageModel.Error { return "Apple Intelligence unavailable" }
    if e is PrivateCloudComputeLanguageModel.Error { return "PCC unavailable (check entitlement)" }
    return e.localizedDescription
}

#endif  // canImport(FoundationModels)

// MARK: - JSON extraction for --schema (prompt + extract fallback)

func extractJSON(from text: String) -> String {
    let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("```") {
        var inner = s.dropFirst(3)
        if inner.hasPrefix("json") { inner = inner.dropFirst(4) }
        if let nl = inner.firstIndex(of: "\n") { inner = inner[inner.index(after: nl)...] }
        if let fence = inner.range(of: "\n```", options: .backwards) {
            return String(inner[..<fence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if s.hasPrefix("{") || s.hasPrefix("[") { return s }
    if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") {
        return String(s[start...end])
    }
    return s
}
