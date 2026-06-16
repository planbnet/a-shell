import Foundation
#if canImport(ios_system)
import ios_system
#endif

// MARK: - Tool runner for fm agent

struct AgentToolRunner {
    let display: AgentDisplay
    let shellConfirm: Bool
    let input: UnsafeMutablePointer<FILE>
    let cwd: String

    init(display: AgentDisplay, shellConfirm: Bool, input: UnsafeMutablePointer<FILE>) {
        self.display      = display
        self.shellConfirm = shellConfirm
        self.input        = input
        self.cwd          = FileManager.default.currentDirectoryPath
    }

    // MARK: - Dispatch

    func run(name: String, args: [String: Any]) async -> String {
        switch name {
        case "read_file":
            return readFile(args)
        case "write_file":
            return writeFile(args)
        case "edit_file":
            return editFile(args)
        case "run_shell":
            return await runShell(args)
        case "list_dir":
            return listDir(args)
        case "grep":
            return grepTool(args)
        case "glob":
            return globTool(args)
        case "web_search":
            return await webSearch(args)
        case "read_url":
            return await readURL(args)
        default:
            return "Error: unknown tool '\(name)'"
        }
    }

    // MARK: - read_file

    private func readFile(_ args: [String: Any]) -> String {
        guard let path = args["path"] as? String else { return "Error: 'path' required" }
        let full = resolve(path)
        guard let content = try? String(contentsOfFile: full, encoding: .utf8) else {
            return "Error: cannot read '\(path)': file not found or not UTF-8"
        }
        let lines = content.components(separatedBy: "\n")
        let total = lines.count

        let start = (args["start_line"] as? Int).map { max(1, $0) } ?? 1
        let end   = (args["end_line"]   as? Int).map { min(total, $0) } ?? total

        let selected = lines[(start-1)..<end]
        var result = ""
        for (i, line) in selected.enumerated() {
            result += "\(start + i)\t\(line)\n"
        }
        if total > end {
            result += "\n[\(total - end) more lines not shown. Use start_line/end_line to paginate.]"
        }
        return result.isEmpty ? "(empty file)" : result
    }

    // MARK: - write_file

    private func writeFile(_ args: [String: Any]) -> String {
        guard let path    = args["path"]    as? String else { return "Error: 'path' required" }
        guard let content = args["content"] as? String else { return "Error: 'content' required" }
        let full = resolve(path)
        let dir  = (full as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try content.write(toFile: full, atomically: true, encoding: .utf8)
            let lines = content.components(separatedBy: "\n").count
            return "OK: wrote \(content.count) chars (\(lines) lines) to '\(path)'"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - edit_file

    private func editFile(_ args: [String: Any]) -> String {
        guard let path    = args["path"]        as? String else { return "Error: 'path' required" }
        guard let oldText = args["old_content"] as? String else { return "Error: 'old_content' required" }
        guard let newText = args["new_content"] as? String else { return "Error: 'new_content' required" }
        let full = resolve(path)
        guard var content = try? String(contentsOfFile: full, encoding: .utf8) else {
            return "Error: cannot read '\(path)'"
        }
        guard content.contains(oldText) else {
            return "Error: old_content not found in '\(path)'. The text must match exactly (whitespace, newlines)."
        }
        let count = content.components(separatedBy: oldText).count - 1
        if count > 1 {
            return "Error: old_content found \(count) times; provide more context to make it unique."
        }
        content = content.replacingOccurrences(of: oldText, with: newText)
        do {
            try content.write(toFile: full, atomically: true, encoding: .utf8)
            return "OK: replaced \(oldText.count) chars with \(newText.count) chars in '\(path)'"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - run_shell

    private func runShell(_ args: [String: Any]) async -> String {
        guard let command = args["command"] as? String else { return "Error: 'command' required" }
        let timeout = args["timeout"] as? Int ?? 30

#if !canImport(ios_system) && !os(macOS)
        return "Error: run_shell is not available on this platform."
#else
        if shellConfirm {
            // Prompt user to confirm, reading the answer from stdin.
            let inputFile = self.input
            let confirmed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global().async {
                    self.display.println("\n\(self.display.yellow)Run shell command?\(self.display.reset) \(self.display.dim)\(command)\(self.display.reset)")
                    Foundation.fputs("\(self.display.dim)[y/N]: \(self.display.reset)", self.display.out)
                    fflush(self.display.out)
                    var buf = [CChar](repeating: 0, count: 256)
                    var ans = ""
                    if fgets(&buf, 256, inputFile) != nil {
                        ans = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    cont.resume(returning: ans.lowercased() == "y")
                }
            }
            if !confirmed {
                return "Cancelled by user."
            }
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global().async {
                let result = Self._execShell(command: command, timeout: timeout)
                cont.resume(returning: result)
            }
        }
#endif
    }

    private static func _truncateOutput(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .newlines)
        let limit = 20_000
        if trimmed.count > limit {
            return String(trimmed.prefix(limit)) + "\n… [truncated to \(limit) chars]"
        }
        return trimmed.isEmpty ? "(no output)" : trimmed
    }

#if canImport(ios_system)
    // On a-Shell, run the command exactly the way a-Shell runs a typed command
    // line (its executeCommandAndWait): ios_fork + ios_system + ios_waitpid. This
    // reuses ios_system's own parser, so pipes (|), chaining (&&, ||, ;),
    // redirections, quoting, etc. all behave identically to interactive input.
    //
    // To capture the output we temporarily point this thread's stdout/stderr at a
    // temp file (the forked command inherits them), then read it back.
    private static func _execShell(command: String, timeout: Int) -> String {
        let tmpPath = NSTemporaryDirectory() + "fm-shell-\(UUID().uuidString).out"
        guard let fp = fopen(tmpPath, "w+") else {
            return "Error: could not create a temporary file to capture output"
        }

        let savedOut = thread_stdout
        let savedErr = thread_stderr
        thread_stdout = fp
        thread_stderr = fp

        let pid = ios_fork()
        _ = ios_system(command)
        fflush(fp)
        ios_waitpid(pid)
        ios_releaseThreadId(pid)

        thread_stdout = savedOut
        thread_stderr = savedErr
        fclose(fp)

        let data = (try? Data(contentsOf: URL(fileURLWithPath: tmpPath))) ?? Data()
        try? FileManager.default.removeItem(atPath: tmpPath)
        return _truncateOutput(String(decoding: data, as: UTF8.self))
    }
#elseif os(macOS)
    private static func _execShell(command: String, timeout: Int) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe

        do {
            try proc.run()
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc.isRunning {
            proc.terminate()
            return "Error: command timed out after \(timeout)s"
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        let combined = out + (err.isEmpty ? "" : "\n[stderr]\n" + err)
        return _truncateOutput(combined)
    }
#endif

    // MARK: - list_dir

    private func listDir(_ args: [String: Any]) -> String {
        let path = (args["path"] as? String) ?? "."
        let full = resolve(path)
        let fm   = FileManager.default

        guard let entries = try? fm.contentsOfDirectory(atPath: full) else {
            return "Error: cannot list '\(path)'"
        }

        var lines: [String] = []
        for entry in entries.sorted() {
            if entry.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            let ep = (full as NSString).appendingPathComponent(entry)
            fm.fileExists(atPath: ep, isDirectory: &isDir)
            let suffix = isDir.boolValue ? "/" : ""
            lines.append(entry + suffix)
        }

        if lines.isEmpty { return "(empty directory)" }
        // Include hidden files count
        let hidden = entries.filter { $0.hasPrefix(".") }.count
        let footer = hidden > 0 ? "\n[\(hidden) hidden items not shown]" : ""
        return lines.joined(separator: "\n") + footer
    }

    // MARK: - grep

    private func grepTool(_ args: [String: Any]) -> String {
        guard let pattern = args["pattern"] as? String else { return "Error: 'pattern' required" }
        let path   = (args["path"] as? String) ?? "."
        let recur  = (args["recursive"] as? Bool) ?? true
        let noCase = (args["case_insensitive"] as? Bool) ?? false
        let full   = resolve(path)

        var flags: NSRegularExpression.Options = []
        if noCase { flags.insert(.caseInsensitive) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: flags) else {
            return "Error: invalid regex '\(pattern)'"
        }

        var matches: [String] = []
        let fm = FileManager.default

        func searchFile(_ filePath: String) {
            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
            let relPath = filePath.hasPrefix(cwd + "/")
                ? String(filePath.dropFirst(cwd.count + 1))
                : filePath
            let lines = content.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if re.firstMatch(in: line, range: range) != nil {
                    matches.append("\(relPath):\(i+1):\(line)")
                    if matches.count >= 500 { return }
                }
            }
        }

        var isDir: ObjCBool = false
        fm.fileExists(atPath: full, isDirectory: &isDir)

        if isDir.boolValue && recur {
            guard let enumerator = fm.enumerator(atPath: full) else {
                return "Error: cannot enumerate '\(path)'"
            }
            for case let entry as String in enumerator {
                if shouldIgnore(entry) { enumerator.skipDescendants(); continue }
                let fp = (full as NSString).appendingPathComponent(entry)
                var d: ObjCBool = false
                fm.fileExists(atPath: fp, isDirectory: &d)
                if !d.boolValue { searchFile(fp) }
                if matches.count >= 500 { break }
            }
        } else if isDir.boolValue {
            if let entries = try? fm.contentsOfDirectory(atPath: full) {
                for entry in entries {
                    let fp = (full as NSString).appendingPathComponent(entry)
                    var d: ObjCBool = false
                    fm.fileExists(atPath: fp, isDirectory: &d)
                    if !d.boolValue { searchFile(fp) }
                }
            }
        } else {
            searchFile(full)
        }

        if matches.isEmpty { return "No matches found." }
        var result = matches.prefix(200).joined(separator: "\n")
        if matches.count > 200 {
            result += "\n… [\(matches.count - 200) more matches not shown]"
        }
        return result
    }

    // MARK: - glob

    private func globTool(_ args: [String: Any]) -> String {
        guard let pattern = args["pattern"] as? String else { return "Error: 'pattern' required" }
        let base  = (args["path"]  as? String) ?? "."
        let limit = (args["limit"] as? Int)    ?? 200
        let full  = resolve(base)

        // Convert glob pattern to basic regex for matching
        // e.g. **/*.swift → match anything ending in .swift
        var matches: [String] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(atPath: full) else {
            return "Error: cannot enumerate '\(base)'"
        }

        let globRE = globToRegex(pattern)

        for case let entry as String in enumerator {
            if shouldIgnore(entry) { enumerator.skipDescendants(); continue }
            if globRE.matches(entry) {
                matches.append(entry)
            }
            if matches.count >= limit { break }
        }

        if matches.isEmpty { return "No matches found." }
        return matches.sorted().joined(separator: "\n")
    }

    private func globToRegex(_ pattern: String) -> NSRegularExpression {
        var p = NSRegularExpression.escapedPattern(for: pattern)
        p = p.replacingOccurrences(of: "\\*\\*", with: "DOUBLESTAR")
        p = p.replacingOccurrences(of: "\\*", with: "[^/]*")
        p = p.replacingOccurrences(of: "DOUBLESTAR", with: ".*")
        p = p.replacingOccurrences(of: "\\?", with: "[^/]")
        let full = "^" + p + "$"
        return (try? NSRegularExpression(pattern: full)) ?? (try! NSRegularExpression(pattern: "^$"))
    }

    // MARK: - web_search

    private func webSearch(_ args: [String: Any]) async -> String {
        guard let query = args["query"] as? String else { return "Error: 'query' required" }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlStr  = "https://html.duckduckgo.com/html/?q=\(encoded)"
        guard let url = URL(string: urlStr) else { return "Error: bad URL" }

        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (compatible; fm-agent/1.0)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        guard
            let (data, _) = try? await URLSession.shared.data(for: req),
            let html = String(data: data, encoding: .utf8)
        else { return "Error: web search request failed" }

        return parseSearchResults(html)
    }

    private func parseSearchResults(_ html: String) -> String {
        // Extract result titles and snippets from DuckDuckGo HTML
        var results: [String] = []

        // Find result blocks: <a class="result__a" href="...">Title</a>
        let titleRE   = try? NSRegularExpression(pattern: #"<a[^>]+class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let snippetRE = try? NSRegularExpression(pattern: #"<a[^>]+class="result__snippet"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])

        let titles   = extractAll(html, re: titleRE)
        let snippets = extractAll(html, re: snippetRE)

        for i in 0..<min(titles.count, 8) {
            let title   = stripHTML(titles[i].1)
            let url     = titles[i].0
            let snippet = i < snippets.count ? stripHTML(snippets[i].0) : ""
            results.append("**\(title)**\n\(url)\n\(snippet)")
        }

        if results.isEmpty {
            return "No results found (or search blocked). Try a different query."
        }
        return results.joined(separator: "\n\n")
    }

    private func extractAll(_ html: String, re: NSRegularExpression?) -> [(String, String)] {
        guard let re = re else { return [] }
        var out: [(String, String)] = []
        let range = NSRange(html.startIndex..., in: html)
        for match in re.matches(in: html, range: range) {
            let g1 = match.numberOfRanges > 1
                ? String(html[Range(match.range(at: 1), in: html)!]) : ""
            let g2 = match.numberOfRanges > 2
                ? String(html[Range(match.range(at: 2), in: html)!]) : ""
            out.append((g1, g2))
        }
        return out
    }

    // MARK: - read_url

    private func readURL(_ args: [String: Any]) async -> String {
        guard let urlStr = args["url"] as? String,
              let url    = URL(string: urlStr)
        else { return "Error: 'url' required and must be valid" }

        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (compatible; fm-agent/1.0)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20

        guard
            let (data, response) = try? await URLSession.shared.data(for: req)
        else { return "Error: request failed" }

        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? ""

        if contentType.contains("text/html") || contentType.isEmpty {
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? "(binary content)"
            let text = htmlToText(html)
            let limit = 30_000
            if text.count > limit {
                return String(text.prefix(limit)) + "\n… [truncated]"
            }
            return text
        } else {
            let text = String(data: data, encoding: .utf8) ?? "(binary)"
            let limit = 30_000
            return text.count > limit ? String(text.prefix(limit)) + "\n… [truncated]" : text
        }
    }

    private func htmlToText(_ html: String) -> String {
        // Remove script/style blocks
        var text = html
        for tag in ["script", "style", "head", "nav", "footer", "aside"] {
            if let re = try? NSRegularExpression(pattern: "<\(tag)[^>]*>.*?</\(tag)>",
                                                 options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                   withTemplate: " ")
            }
        }
        // Headings → prefix with ###
        for (tag, prefix) in [("h1","# "),("h2","## "),("h3","### ")] {
            if let re = try? NSRegularExpression(pattern: "<\(tag)[^>]*>(.*?)</\(tag)>",
                                                 options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                   withTemplate: "\n\(prefix)$1\n")
            }
        }
        // Links → text (url)
        if let re = try? NSRegularExpression(pattern: #"<a[^>]+href="([^"]*)"[^>]*>(.*?)</a>"#,
                                             options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                               withTemplate: "$2 ($1)")
        }
        // Paragraphs/divs → newlines
        for tag in ["p", "div", "li", "br", "tr"] {
            text = text.replacingOccurrences(of: "<\(tag)", with: "\n<", options: .caseInsensitive)
        }
        // Strip remaining tags
        text = stripHTML(text)
        // Decode HTML entities
        text = decodeEntities(text)
        // Collapse whitespace
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    private func stripHTML(_ html: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else { return html }
        return re.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html),
                                           withTemplate: "")
    }

    private func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;",  with: "&")
         .replacingOccurrences(of: "&lt;",   with: "<")
         .replacingOccurrences(of: "&gt;",   with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;",  with: "'")
         .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    // MARK: - Helpers

    private func resolve(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~/") {
            return NSHomeDirectory() + "/" + String(path.dropFirst(2))
        }
        return (cwd as NSString).appendingPathComponent(path)
    }

    private func shouldIgnore(_ path: String) -> Bool {
        let components = path.components(separatedBy: "/")
        let ignores = [".git", "node_modules", ".build", "__pycache__", ".DS_Store",
                       ".venv", "venv", "env", ".tox", "dist", "build", ".cache"]
        return components.contains(where: { ignores.contains($0) || $0.hasSuffix(".pyc") })
    }
}

// MARK: - NSRegularExpression helper

private extension NSRegularExpression {
    func matches(_ string: String) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return firstMatch(in: string, range: range) != nil
    }
}
