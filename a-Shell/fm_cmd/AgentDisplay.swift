import Foundation

// MARK: - Thread-safe display with spinner for fm agent

final class AgentDisplay {
    let out: UnsafeMutablePointer<FILE>
    let err: UnsafeMutablePointer<FILE>
    let isTTY: Bool

    private let q = DispatchQueue(label: "fm.agent.display")
    private var spinTimer: DispatchSourceTimer?
    private var spinMsg  = ""
    private var spinIdx  = 0
    private var spinStart = Date()

    private static let spinFrames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]

    // Colours
    var cyan:   String { isTTY ? "\u{1B}[36m"    : "" }
    var yellow: String { isTTY ? "\u{1B}[33m"    : "" }
    var green:  String { isTTY ? "\u{1B}[32m"    : "" }
    var red:    String { isTTY ? "\u{1B}[31m"    : "" }
    var dim:    String { isTTY ? "\u{1B}[2m"     : "" }
    var bold:   String { isTTY ? "\u{1B}[1m"     : "" }
    var italic: String { isTTY ? "\u{1B}[3m"     : "" }
    var reset:  String { isTTY ? "\u{1B}[0m"     : "" }

    init(out: UnsafeMutablePointer<FILE>, err: UnsafeMutablePointer<FILE>) {
        self.out = out
        self.err = err
        // a-Shell / ios_system route stdout through a pipe, so isatty() is false
        // even in the interactive terminal. The terminal still understands ANSI
        // and carriage returns, so also treat a set TERM (other than "dumb") as
        // animation/colour-capable.
        if isatty(fileno(out)) != 0 {
            self.isTTY = true
        } else if let term = getenv("TERM").map({ String(cString: $0) }) {
            self.isTTY = !term.isEmpty && term != "dumb"
        } else {
            self.isTTY = false
        }
    }

    // MARK: - Spinner

    func spin(_ message: String) {
        q.async { [weak self] in
            guard let self else { return }
            self._clearSpin()
            self.spinMsg   = message
            self.spinStart = Date()
            self.spinIdx   = 0
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now(), repeating: .milliseconds(120))
            t.setEventHandler { [weak self] in self?._drawSpin() }
            self.spinTimer = t
            t.resume()
        }
    }

    func stopSpin() {
        q.sync { self._clearSpin() }
    }

    private func _clearSpin() {
        guard spinTimer != nil else { return }
        spinTimer?.cancel()
        spinTimer = nil
        if isTTY { fputs("\r\u{1B}[K", out); fflush(out) }
    }

    private func _drawSpin() {
        let elapsed = Date().timeIntervalSince(spinStart)
        let frame   = Self.spinFrames[spinIdx % Self.spinFrames.count]
        spinIdx += 1
        if isTTY {
            fputs("\r\u{1B}[K\u{1B}[2m \(frame) \(spinMsg) (\(String(format: "%.1f", elapsed))s)\u{1B}[0m", out)
        } else {
            fputs("\(spinMsg)…\n", out)
        }
        fflush(out)
    }

    // MARK: - Output primitives (all serialised through q)

    /// Stream raw text incrementally (used while the model response streams in).
    func stream(_ text: String) {
        q.sync {
            self._clearSpin()
            fputs(text, self.out)
            fflush(self.out)
        }
    }

    /// Print a line (adds newline)
    func println(_ text: String = "") {
        q.sync {
            self._clearSpin()
            fputs(text + "\n", self.out)
            fflush(self.out)
        }
    }

    /// Print a compact header line (no full-width rule).
    func header(_ text: String, color: String? = nil) {
        q.sync {
            self._clearSpin()
            let c = color ?? self.dim
            fputs("\(c)\(text)\(self.reset)\n", self.out)
            fflush(self.out)
        }
    }

    /// Show a labelled block: a short colored title line, then the content
    /// indented with a dim left guide. No fixed-width borders (they wrap and
    /// break on narrow terminals).
    func panel(title: String, content: String, color: String? = nil) {
        q.sync {
            self._clearSpin()
            let c = color ?? self.yellow
            let r = self.reset
            fputs("\(c)\(title)\(r)\n", self.out)
            for line in content.components(separatedBy: "\n") {
                fputs("\(self.dim)│\(r) \(line)\n", self.out)
            }
            fflush(self.out)
        }
    }

    /// Render and print text with basic markdown formatting
    func renderMarkdown(_ text: String) {
        q.sync {
            self._clearSpin()
            fputs(self._renderMd(text), self.out)
            fflush(self.out)
        }
    }

    // MARK: - Markdown renderer

    private func _renderMd(_ text: String) -> String {
        guard isTTY else { return text.hasSuffix("\n") ? text : text + "\n" }
        var out = ""
        var inCode = false
        var codeLang = ""
        let boldRE   = try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
        let inlineRE = try? NSRegularExpression(pattern: "`([^`]+)`")

        func applyInline(_ line: String) -> String {
            var s = line
            if let re = boldRE {
                s = re.stringByReplacingMatches(in: s,
                    range: NSRange(s.startIndex..., in: s),
                    withTemplate: "\u{1B}[1m$1\u{1B}[0m")
            }
            if let re = inlineRE {
                s = re.stringByReplacingMatches(in: s,
                    range: NSRange(s.startIndex..., in: s),
                    withTemplate: "\u{1B}[2m`$1`\u{1B}[0m")
            }
            return s
        }

        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("```") {
                if inCode {
                    out += "\u{1B}[2m└─\u{1B}[0m\n"
                    inCode   = false
                    codeLang = ""
                } else {
                    codeLang = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode   = true
                    out += "\u{1B}[2m┌─ \(codeLang.isEmpty ? "code" : codeLang)\u{1B}[0m\n"
                }
            } else if inCode {
                out += "\u{1B}[2m│\u{1B}[0m \(raw)\n"
            } else if raw.hasPrefix("### ") {
                out += "\u{1B}[1m" + applyInline(String(raw.dropFirst(4))) + "\u{1B}[0m\n"
            } else if raw.hasPrefix("## ") {
                out += "\u{1B}[1m" + applyInline(String(raw.dropFirst(3))) + "\u{1B}[0m\n"
            } else if raw.hasPrefix("# ") {
                out += "\u{1B}[1m" + applyInline(String(raw.dropFirst(2))) + "\u{1B}[0m\n"
            } else {
                out += applyInline(raw) + "\n"
            }
        }
        return out
    }
}
