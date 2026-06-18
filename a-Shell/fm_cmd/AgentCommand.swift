import Foundation

#if canImport(FoundationModels)
@_weakLinked import FoundationModels
#endif

// MARK: - Options

struct AgentOptions {
    var model:         String  = "system"  // default to on-device, like other fm subcommands
    var modelExplicit: Bool    = false   // did the user pass --model?
    var shellConfirm:  Bool    = true
    var systemFile:    String? = nil
    var noTools:       Bool    = false
    var stream:        Bool    = true
    var initialPrompt: String? = nil
}

// MARK: - Entry point

enum AgentCommand {
    static func run(
        args:   [String],
        input:  UnsafeMutablePointer<FILE>,
        output: UnsafeMutablePointer<FILE>,
        error:  UnsafeMutablePointer<FILE>
    ) -> Int32 {
        var parser = ArgParser(args)
        var opts   = AgentOptions()
        var positional: [String] = []

        if let v = ProcessInfo.processInfo.environment["SHELL_TOOL_CONFIRMATION"] {
            opts.shellConfirm = v != "0" && v.lowercased() != "false"
        }

        while let arg = parser.next() {
            switch arg {
            case "--help", "-h":
                Help.printAgent(to: output)
                return 0
            case "-m", "--model":
                guard let v = parser.next() else {
                    fputs("Error: '--model' requires a value (system, pcc).\n", error); return 64
                }
                guard v == "system" || v == "pcc" else {
                    fputs("Error: Unknown model '\(v)'. Valid models: system, pcc.\n", error); return 64
                }
                opts.model = v
                opts.modelExplicit = true
            case "--system":
                guard let v = parser.next() else {
                    fputs("Error: '--system' requires a file path.\n", error); return 64
                }
                opts.systemFile = v
            case "--no-tools":
                opts.noTools = true
            case "--no-confirm", "--yolo":
                opts.shellConfirm = false
            case "--no-stream":
                opts.stream = false
            default:
                if arg.hasPrefix("-") {
                    fputs("Error: Unknown option '\(arg)'\n  See 'fm agent --help' for more information.\n", error)
                    return 64
                }
                positional.append(arg)
            }
        }

        if !positional.isEmpty {
            opts.initialPrompt = positional.joined(separator: " ")
        }

        guard #available(iOS 27.0, macOS 27.0, *) else {
            fputs("fm agent: Foundation Models requires iOS 27 / macOS 27 or later\n", error)
            return 69
        }
        #if canImport(FoundationModels)
        let sem = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task {
            defer { sem.signal() }
            exitCode = await runAgent(opts: opts, input: input, output: output, error: error)
        }
        sem.wait()
        return exitCode
        #else
        fputs("fm agent: FoundationModels framework not available in this build\n", error)
        return 69
        #endif
    }

    // MARK: - System prompt

    static func buildSystemPrompt(opts: AgentOptions) -> String {
        if let file = opts.systemFile {
            let path = resolvePath(file)
            if let content = try? String(contentsOfFile: path, encoding: .utf8) { return content }
        }
        let agentsMd = FileManager.default.currentDirectoryPath + "/AGENTS.md"
        if let content = try? String(contentsOfFile: agentsMd, encoding: .utf8) { return content }

#if os(iOS)
        let plat = "iOS (a-Shell)"
#else
        let plat = "macOS"
#endif
        return """
        You are a coding agent running inside the fm CLI on \(plat), powered by \
        Apple Foundation Models.

        You have tools to read/write/edit files, search code (grep/glob), list \
        directories, run shell commands, search the web, and read URLs. Use them \
        to accomplish the user's request.

        Guidelines:
        - Read files before editing them.
        - Prefer small, targeted edits over full rewrites.
        - Keep replies concise; summarise what you did when a task is complete.
        - run_shell supports pipes (|) and chaining commands with &&, || and ; \
          within a single call.
        - The shell is dash (not bash/zsh), and commands follow BSD syntax \
          (e.g. `ls`, `sed`, `find` behave as on macOS/BSD, not GNU/Linux). \
          Run the `help` command via run_shell to see the available commands and \
          what this environment supports.

        Current directory: \(FileManager.default.currentDirectoryPath)
        """
    }
}

// MARK: - Agent loop (FoundationModels)

#if canImport(FoundationModels)

@available(iOS 27.0, macOS 27.0, *)
private func makeAgentSession(
    model:        String,
    instructions: String,
    tools:        [any Tool]
) -> LanguageModelSession {
    let instr = Instructions(instructions)
    if model == "pcc" {
        return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instr)
    } else {
        return LanguageModelSession(model: SystemLanguageModel(), tools: tools, instructions: instr)
    }
}

/// True if the error means the chosen model is unavailable (so we should fall back).
@available(iOS 27.0, macOS 27.0, *)
private func isModelUnavailable(_ e: Error) -> Bool {
    if e is PrivateCloudComputeLanguageModel.Error { return true }
    if e is SystemLanguageModel.Error { return true }
    return false
}

@available(iOS 27.0, macOS 27.0, *)
private func isContextExceeded(_ e: Error) -> Bool {
    if let le = e as? LanguageModelError, case .contextSizeExceeded = le { return true }
    return false
}

@available(iOS 27.0, macOS 27.0, *)
private func runAgent(
    opts:   AgentOptions,
    input:  UnsafeMutablePointer<FILE>,
    output: UnsafeMutablePointer<FILE>,
    error:  UnsafeMutablePointer<FILE>
) async -> Int32 {
    let display = AgentDisplay(out: output, err: error)
    let systemPrompt = AgentCommand.buildSystemPrompt(opts: opts)

    let runner = AgentToolRunner(display: display, shellConfirm: opts.shellConfirm, input: input)
    let tools: [any Tool] = opts.noTools ? [] : makeAgentTools(runner: runner)

    var currentModel = opts.model
    var session = makeAgentSession(model: currentModel, instructions: systemPrompt, tools: tools)

    func modelLabel(_ m: String) -> String { m == "pcc" ? "Private Cloud Compute" : "on-device system" }

    display.println("\(display.cyan)\(display.bold)fm agent\(display.reset)  "
        + "\(display.dim)\(modelLabel(currentModel)) · \(tools.count) tools\(display.reset)")

    // Runs one user turn; handles streaming, PCC→system fallback, and context reset.
    func handleTurn(_ prompt: String, allowFallback: Bool) async -> Bool {
        display.spin("Thinking")
        let box = ErrorBox()
        // Generation runs inside runInterruptible so Ctrl-C cancels it.
        let completed = await runInterruptible {
            do {
                if opts.stream {
                    let stream = session.streamResponse(to: prompt)
                    var lastLen = 0
                    for try await partial in stream {
                        try Task.checkCancellation()
                        let full = partial.content
                        if full.count > lastLen {
                            display.stopSpin()
                            display.stream(String(full.suffix(full.count - lastLen)))
                            lastLen = full.count
                        }
                    }
                    display.stopSpin()
                    if lastLen > 0 { display.println() }
                } else {
                    let response = try await session.respond(to: prompt)
                    display.stopSpin()
                    display.renderMarkdown(response.content)
                }
            } catch is CancellationError {
                // Surfaced below as `completed == false`.
            } catch {
                box.error = error
            }
        }
        display.stopSpin()

        if !completed {
            display.println("\n\(display.dim)^C interrupted\(display.reset)")
            return true
        }

        guard let e = box.error else { return true }

        // PCC unavailable and the user didn't pin the model → fall back to system.
        if allowFallback, currentModel == "pcc", !opts.modelExplicit, isModelUnavailable(e) {
            display.println("\(display.dim)\(modelLabel("pcc")) unavailable — falling back to on-device system model.\(display.reset)")
            currentModel = "system"
            session = makeAgentSession(model: currentModel, instructions: systemPrompt, tools: tools)
            return await handleTurn(prompt, allowFallback: false)
        }

        if isContextExceeded(e) {
            display.println("\(display.yellow)Context full — starting a fresh session and retrying.\(display.reset)")
            session = makeAgentSession(model: currentModel, instructions: systemPrompt, tools: tools)
            return await handleTurn(prompt, allowFallback: false)
        }

        display.println("\(display.red)\(briefAgentError(e))\(display.reset)")
        return false
    }

    // Non-interactive single prompt
    if let initial = opts.initialPrompt {
        let ok = await handleTurn(initial, allowFallback: true)
        return ok ? 0 : 1
    }

    // Interactive REPL
    while true {
        fputs("\n\(display.cyan)\(display.bold)▸\(display.reset) ", output)
        fflush(output)
        guard let raw = await readAgentLine(from: input) else { break }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        switch line {
        case "/quit", "/exit", "exit", "quit":
            display.println("\n\(display.dim)Goodbye.\(display.reset)")
            return 0
        case "/clear":
            session = makeAgentSession(model: currentModel, instructions: systemPrompt, tools: tools)
            display.println("\(display.dim)Conversation cleared.\(display.reset)")
            continue
        case "/model":
            display.println("\(display.dim)Model: \(currentModel) (\(modelLabel(currentModel)))\(display.reset)")
            continue
        default:
            break
        }
        _ = await handleTurn(line, allowFallback: true)
    }

    display.println("\n\(display.dim)Goodbye.\(display.reset)")
    return 0
}

@available(iOS 27.0, macOS 27.0, *)
private func briefAgentError(_ e: Error) -> String {
    if let le = e as? LanguageModelError {
        switch le {
        case .guardrailViolation:          return "Content policy — guardrail triggered."
        case .refusal:                     return "The model declined to respond."
        case .contextSizeExceeded:         return "Context size exceeded."
        case .timeout:                     return "Request timed out."
        case .unsupportedLanguageOrLocale: return "Unsupported language or locale."
        default:                           return "Model error: \(le)"
        }
    }
    if e is SystemLanguageModel.Error {
        return "Apple Intelligence unavailable — enable it in Settings."
    }
    if e is PrivateCloudComputeLanguageModel.Error {
        return "Private Cloud Compute unavailable (check the com.apple.developer.private-cloud-compute entitlement)."
    }
    return e.localizedDescription
}

#endif // canImport(FoundationModels)

// MARK: - Async readline helper

private func readAgentLine(from file: UnsafeMutablePointer<FILE>) async -> String? {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInteractive).async {
            var buf = [CChar](repeating: 0, count: 8192)
            guard fgets(&buf, Int32(buf.count), file) != nil else {
                cont.resume(returning: nil); return
            }
            var s = String(cString: buf)
            while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
            cont.resume(returning: s)
        }
    }
}
