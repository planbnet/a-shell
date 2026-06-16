import Foundation

#if canImport(FoundationModels)
@_weakLinked import FoundationModels

// MARK: - FoundationModels Tool wrappers for fm agent
//
// Each tool wraps the shared AgentToolRunner (which holds the real
// implementations) and translates its @Generable Arguments into the
// [String: Any] dictionary the runner expects. Tool invocations and results are
// shown to the user via AgentDisplay panels.
//
// Tools are `@unchecked Sendable`: AgentToolRunner / AgentDisplay serialise
// their own state (display writes go through a serial queue), and tool calls
// are driven one-at-a-time by the model session.

@available(iOS 26.0, macOS 26.0, *)
private func _show(_ display: AgentDisplay, name: String, args: [String: String]) {
    // Single compact line: ⚙ name  key=value …
    let argStr = args.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
    display.header("⚙ \(name)\(argStr.isEmpty ? "" : "  " + argStr)", color: display.cyan)
    display.spin("\(name)…")
}

@available(iOS 26.0, macOS 26.0, *)
private func _result(_ display: AgentDisplay, name: String, _ result: String) -> String {
    display.stopSpin()
    let shown = result.count > 2000 ? String(result.prefix(2000)) + "\n… [truncated for display]" : result
    display.panel(title: "✓ \(name)", content: shown, color: display.green)
    return result
}

// MARK: read_file

@available(iOS 26.0, macOS 26.0, *)
struct ReadFileTool: Tool, @unchecked Sendable {
    let name = "read_file"
    let description = "Read a file from disk and return its contents (line-numbered)."
    let runner: AgentToolRunner

    @Generable
    struct Arguments {
        @Guide(description: "Path to the file to read")
        var path: String
        @Guide(description: "First line to read, 1-based (optional)")
        var startLine: Int?
        @Guide(description: "Last line to read, 1-based (optional)")
        var endLine: Int?
    }

    func call(arguments a: Arguments) async throws -> String {
        var args: [String: Any] = ["path": a.path]
        if let s = a.startLine { args["start_line"] = s }
        if let e = a.endLine { args["end_line"] = e }
        _show(runner.display, name: name, args: ["path": a.path])
        return _result(runner.display, name: name, await runner.run(name: name, args: args))
    }
}

// MARK: write_file

@available(iOS 26.0, macOS 26.0, *)
struct WriteFileTool: Tool, @unchecked Sendable {
    let name = "write_file"
    let description = "Create or overwrite a file with the given content."
    let runner: AgentToolRunner

    @Generable
    struct Arguments {
        @Guide(description: "Path to the file to write")
        var path: String
        @Guide(description: "Full content to write to the file")
        var content: String
    }

    func call(arguments a: Arguments) async throws -> String {
        _show(runner.display, name: name, args: ["path": a.path, "content": "\(a.content.count) chars"])
        return _result(runner.display, name: name,
                       await runner.run(name: name, args: ["path": a.path, "content": a.content]))
    }
}

// MARK: edit_file

@available(iOS 26.0, macOS 26.0, *)
struct EditFileTool: Tool, @unchecked Sendable {
    let name = "edit_file"
    let description = "Replace an exact, unique snippet of text in a file with new text."
    let runner: AgentToolRunner

    @Generable
    struct Arguments {
        @Guide(description: "Path to the file to edit")
        var path: String
        @Guide(description: "Exact text to find (must be unique in the file)")
        var oldContent: String
        @Guide(description: "Replacement text")
        var newContent: String
    }

    func call(arguments a: Arguments) async throws -> String {
        _show(runner.display, name: name, args: ["path": a.path])
        return _result(runner.display, name: name, await runner.run(name: name, args: [
            "path": a.path, "old_content": a.oldContent, "new_content": a.newContent
        ]))
    }
}

// MARK: run_shell

@available(iOS 26.0, macOS 26.0, *)
struct RunShellTool: Tool, @unchecked Sendable {
    let name = "run_shell"
    let description = "Run a shell command and return its combined stdout/stderr. Supports pipes (|) and chaining with &&, || and ;."
    let runner: AgentToolRunner

    @Generable
    struct Arguments {
        @Guide(description: "Shell command to execute")
        var command: String
        @Guide(description: "Timeout in seconds (optional, default 30)")
        var timeout: Int?
    }

    func call(arguments a: Arguments) async throws -> String {
        var args: [String: Any] = ["command": a.command]
        if let t = a.timeout { args["timeout"] = t }
        _show(runner.display, name: name, args: ["command": a.command])
        return _result(runner.display, name: name, await runner.run(name: name, args: args))
    }
}

// MARK: list_dir

@available(iOS 26.0, macOS 26.0, *)
struct ListDirTool: Tool, @unchecked Sendable {
    let name = "list_dir"
    let description = "List the files and directories at a path."
    let runner: AgentToolRunner

    @Generable
    struct Arguments {
        @Guide(description: "Directory path to list (optional, default current directory)")
        var path: String?
    }

    func call(arguments a: Arguments) async throws -> String {
        var args: [String: Any] = [:]
        if let p = a.path { args["path"] = p }
        _show(runner.display, name: name, args: ["path": a.path ?? "."])
        return _result(runner.display, name: name, await runner.run(name: name, args: args))
    }
}

// MARK: grep

@available(iOS 26.0, macOS 26.0, *)
struct GrepTool: Tool, @unchecked Sendable {
    let name = "grep"
    let description = "Search file contents for a regular-expression pattern."
    let runner: AgentToolRunner

    @Generable
    struct Arguments {
        @Guide(description: "Regular expression to search for")
        var pattern: String
        @Guide(description: "File or directory to search (optional, default current directory)")
        var path: String?
        @Guide(description: "Search subdirectories recursively (optional, default true)")
        var recursive: Bool?
        @Guide(description: "Case-insensitive search (optional, default false)")
        var caseInsensitive: Bool?
    }

    func call(arguments a: Arguments) async throws -> String {
        var args: [String: Any] = ["pattern": a.pattern]
        if let p = a.path { args["path"] = p }
        if let r = a.recursive { args["recursive"] = r }
        if let c = a.caseInsensitive { args["case_insensitive"] = c }
        _show(runner.display, name: name, args: ["pattern": a.pattern, "path": a.path ?? "."])
        return _result(runner.display, name: name, await runner.run(name: name, args: args))
    }
}

// MARK: glob

@available(iOS 26.0, macOS 26.0, *)
struct GlobTool: Tool, @unchecked Sendable {
    let name = "glob"
    let description = "Find files matching a glob pattern (e.g. **/*.swift)."
    let runner: AgentToolRunner

    @Generable
    struct Arguments {
        @Guide(description: "Glob pattern, e.g. **/*.swift")
        var pattern: String
        @Guide(description: "Base directory to search (optional, default current directory)")
        var path: String?
    }

    func call(arguments a: Arguments) async throws -> String {
        var args: [String: Any] = ["pattern": a.pattern]
        if let p = a.path { args["path"] = p }
        _show(runner.display, name: name, args: ["pattern": a.pattern])
        return _result(runner.display, name: name, await runner.run(name: name, args: args))
    }
}

// MARK: web_search

@available(iOS 26.0, macOS 26.0, *)
struct WebSearchTool: Tool, @unchecked Sendable {
    let name = "web_search"
    let description = "Search the web (DuckDuckGo) and return the top results."
    let runner: AgentToolRunner

    @Generable
    struct Arguments {
        @Guide(description: "Search query")
        var query: String
    }

    func call(arguments a: Arguments) async throws -> String {
        _show(runner.display, name: name, args: ["query": a.query])
        return _result(runner.display, name: name, await runner.run(name: name, args: ["query": a.query]))
    }
}

// MARK: read_url

@available(iOS 26.0, macOS 26.0, *)
struct ReadURLTool: Tool, @unchecked Sendable {
    let name = "read_url"
    let description = "Fetch a URL and return its readable text content."
    let runner: AgentToolRunner

    @Generable
    struct Arguments {
        @Guide(description: "URL to fetch")
        var url: String
    }

    func call(arguments a: Arguments) async throws -> String {
        _show(runner.display, name: name, args: ["url": a.url])
        return _result(runner.display, name: name, await runner.run(name: name, args: ["url": a.url]))
    }
}

// MARK: - Tool set factory

@available(iOS 26.0, macOS 26.0, *)
func makeAgentTools(runner: AgentToolRunner) -> [any Tool] {
    [
        ReadFileTool(runner: runner),
        WriteFileTool(runner: runner),
        EditFileTool(runner: runner),
        RunShellTool(runner: runner),
        ListDirTool(runner: runner),
        GrepTool(runner: runner),
        GlobTool(runner: runner),
        WebSearchTool(runner: runner),
        ReadURLTool(runner: runner),
    ]
}

#endif // canImport(FoundationModels)
