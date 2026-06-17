import Foundation

// MARK: - Argument parser helpers

struct ArgParser {
    var args: [String]
    var pos: Int = 0

    init(_ args: [String]) { self.args = args }

    mutating func next() -> String? {
        guard pos < args.count else { return nil }
        defer { pos += 1 }
        return args[pos]
    }

    mutating func peek() -> String? {
        guard pos < args.count else { return nil }
        return args[pos]
    }

    var remaining: [String] { Array(args[pos...]) }
    var isDone: Bool { pos >= args.count }
}

// MARK: - respond

struct RespondOptions {
    var prompt: String? = nil
    var model: String = "system"
    var instructions: String? = nil
    var schemaPath: String? = nil
    var texts: [String] = []
    var images: [String] = []
    var stream: Bool = true
    var greedy: Bool = false
    var verbose: Bool = false
}

enum RespondCommand {
    static func run(args: [String], input: UnsafeMutablePointer<FILE>, output: UnsafeMutablePointer<FILE>, error: UnsafeMutablePointer<FILE>) -> Int32 {
        var parser = ArgParser(args)
        var opts = RespondOptions()
        var positional: [String] = []

        while let arg = parser.next() {
            switch arg {
            case "--help", "-h":
                Help.printRespond(to: output)
                return 0
            case "-m", "--model":
                guard let val = parser.next() else {
                    fputs("Error: '--model' requires a value (system, pcc).\n", error)
                    return 64
                }
                guard val == "system" || val == "pcc" else {
                    fputs("Error: Unknown model '\(val)'. Valid models: system, pcc.\n", error)
                    return 64
                }
                opts.model = val
            case "-i", "--instructions":
                guard let val = parser.next() else {
                    fputs("Error: '--instructions' requires a value.\n", error)
                    return 64
                }
                opts.instructions = val
            case "--schema":
                guard let val = parser.next() else {
                    fputs("Error: '--schema' requires a file path.\n", error)
                    return 64
                }
                opts.schemaPath = val
            case "--text":
                guard let val = parser.next() else {
                    fputs("Error: '--text' requires a value.\n", error)
                    return 64
                }
                opts.texts.append(val)
            case "--image":
                guard let val = parser.next() else {
                    fputs("Error: '--image' requires a file path.\n", error)
                    return 64
                }
                opts.images.append(val)
            case "--stream":
                opts.stream = true
            case "--no-stream":
                opts.stream = false
            case "-g", "--greedy":
                opts.greedy = true
            case "-v", "--verbose":
                opts.verbose = true
            default:
                if arg.hasPrefix("-") {
                    fputs("Error: Unknown option '\(arg)'\nUsage: fm respond 'What is Swift?'\n       fm respond --image photo.jpg --text 'What is in this image?'\n       fm respond --model pcc 'What is Swift?'\n       echo 'What is Swift?' | fm respond\n  See 'fm respond --help' for more information.\n", error)
                    return 64
                }
                positional.append(arg)
            }
        }

        // Resolve prompt from positional args or stdin
        if !positional.isEmpty {
            opts.prompt = positional.joined(separator: " ")
        } else if isatty(fileno(input)) == 0 {
            // stdin is a pipe
            var lines: [String] = []
            var buf = [CChar](repeating: 0, count: 4096)
            while fgets(&buf, Int32(buf.count), input) != nil {
                lines.append(String(cString: buf))
            }
            let text = lines.joined().trimmingCharacters(in: .newlines)
            if !text.isEmpty { opts.prompt = text }
        }

        if (opts.prompt == nil || opts.prompt!.isEmpty) {
            if opts.texts.isEmpty && opts.images.isEmpty {
                fputs("Error: A prompt is required.\nUsage: fm respond 'What is Swift?'\n  See 'fm respond --help' for more information.\n", error)
                return 64
            }
            opts.prompt = ""
        }

        return executeRespond(opts: opts, output: output, error: error)
    }

    private static func executeRespond(opts: RespondOptions, output: UnsafeMutablePointer<FILE>, error: UnsafeMutablePointer<FILE>) -> Int32 {
        return FoundationModelsExecution.respond(opts: opts, output: output, error: error)
    }
}

// MARK: - chat

struct ChatOptions {
    var model: String = "system"
    var instructions: String? = nil
}

enum ChatCommand {
    static func run(args: [String], input: UnsafeMutablePointer<FILE>, output: UnsafeMutablePointer<FILE>, error: UnsafeMutablePointer<FILE>) -> Int32 {
        var parser = ArgParser(args)
        var opts = ChatOptions()

        while let arg = parser.next() {
            switch arg {
            case "--help", "-h":
                Help.printChat(to: output)
                return 0
            case "-m", "--model":
                guard let val = parser.next() else {
                    fputs("Error: '--model' requires a value.\n", error)
                    return 64
                }
                guard val == "system" || val == "pcc" else {
                    fputs("Error: Unknown model '\(val)'. Valid models: system, pcc.\n", error)
                    return 64
                }
                opts.model = val
            case "-i", "--instructions":
                guard let val = parser.next() else {
                    fputs("Error: '--instructions' requires a value.\n", error)
                    return 64
                }
                opts.instructions = val
            default:
                if arg.hasPrefix("-") {
                    fputs("Error: Unknown option '\(arg)'\n  See 'fm chat --help' for more information.\n", error)
                    return 64
                }
            }
        }

        return FoundationModelsExecution.chat(opts: opts, input: input, output: output, error: error)
    }
}

// MARK: - token-count

struct TokenCountOptions {
    var prompt: String? = nil
    var instructions: String? = nil
    var texts: [String] = []
    var images: [String] = []
    var quiet: Bool = false
}

enum TokenCountCommand {
    static func run(args: [String], input: UnsafeMutablePointer<FILE>, output: UnsafeMutablePointer<FILE>, error: UnsafeMutablePointer<FILE>) -> Int32 {
        var parser = ArgParser(args)
        var opts = TokenCountOptions()
        var positional: [String] = []

        while let arg = parser.next() {
            switch arg {
            case "--help", "-h":
                Help.printTokenCount(to: output)
                return 0
            case "-i", "--instructions":
                guard let val = parser.next() else {
                    fputs("Error: '--instructions' requires a value.\n", error)
                    return 64
                }
                opts.instructions = val
            case "--text":
                guard let val = parser.next() else {
                    fputs("Error: '--text' requires a value.\n", error)
                    return 64
                }
                opts.texts.append(val)
            case "--image":
                guard let val = parser.next() else {
                    fputs("Error: '--image' requires a file path.\n", error)
                    return 64
                }
                opts.images.append(val)
            case "-q", "--quiet":
                opts.quiet = true
            default:
                if arg.hasPrefix("-") {
                    fputs("Error: Unknown option '\(arg)'\n  See 'fm token-count --help' for more information.\n", error)
                    return 64
                }
                positional.append(arg)
            }
        }

        if !positional.isEmpty {
            opts.prompt = positional.joined(separator: " ")
        } else if isatty(fileno(input)) == 0 {
            var lines: [String] = []
            var buf = [CChar](repeating: 0, count: 4096)
            while fgets(&buf, Int32(buf.count), input) != nil {
                lines.append(String(cString: buf))
            }
            let text = lines.joined().trimmingCharacters(in: .newlines)
            if !text.isEmpty { opts.prompt = text }
        }

        return FoundationModelsExecution.tokenCount(opts: opts, input: input, output: output, error: error)
    }
}

// MARK: - available

struct AvailableOptions {
    var model: String? = nil
}

enum AvailableCommand {
    static func run(args: [String], output: UnsafeMutablePointer<FILE>, error: UnsafeMutablePointer<FILE>) -> Int32 {
        var parser = ArgParser(args)
        var opts = AvailableOptions()

        while let arg = parser.next() {
            switch arg {
            case "--help", "-h":
                Help.printAvailable(to: output)
                return 0
            case "-m", "--model":
                guard let val = parser.next() else {
                    fputs("Error: '--model' requires a value.\n", error)
                    return 64
                }
                guard val == "system" || val == "pcc" else {
                    fputs("Error: Unknown model '\(val)'. Valid models: system, pcc.\n", error)
                    return 64
                }
                opts.model = val
            default:
                if arg.hasPrefix("-") {
                    fputs("Error: Unknown option '\(arg)'\n  See 'fm available --help' for more information.\n", error)
                    return 64
                }
            }
        }

        return FoundationModelsExecution.available(model: opts.model, output: output, error: error)
    }
}


// MARK: - Path resolution

func resolvePath(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    if path == "~" || path.hasPrefix("~/") {
        // NSHomeDirectory() works on both macOS and iOS (homeDirectoryForCurrentUser is macOS-only)
        let home = NSHomeDirectory()
        return home + "/" + String(path.dropFirst(2))
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(path)
        .standardizedFileURL
        .path
}
