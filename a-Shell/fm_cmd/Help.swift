import Foundation

// MARK: - Help strings

enum Help {

    // MARK: Top-level

    static func printRoot(to file: UnsafeMutablePointer<FILE> = stdout) {
        let t = ANSI.isTerminal(file)
        let h = t ? ANSI.teal + ANSI.bold : ""
        let b = t ? ANSI.bold : ""
        let g = t ? ANSI.gray : ""
        let r = t ? ANSI.reset : ""

        fputs("""
        \(g)Apple Foundation Models CLI\(r)

        \(h)USAGE\(r)
          fm <command> [options]

        \(h)COMMANDS\(r)
          \(b)respond\(r)      Generate a response
          \(b)chat\(r)         Interactive chat session
          \(b)agent\(r)        AI coding agent with tools
          \(b)token-count\(r)  Count tokens
          \(b)available\(r)    Check model availability

        \(h)MODELS\(r)
          \(b)system\(r)  On-device \(g)(default)\(r)
          \(b)pcc\(r)     Private Cloud Compute

        \(h)EXAMPLES\(r)
          fm respond 'What is Swift?'
          fm agent 'fix the bug in cnt.sh'
          fm chat

        \(t ? ANSI.italic + g : "")Run 'fm <command> --help' for details.\(r)

        """, file)
    }

    // MARK: respond

    static func printRespond(to file: UnsafeMutablePointer<FILE> = stdout) {
        let t = ANSI.isTerminal(file)
        let h = t ? ANSI.teal + ANSI.bold : ""
        let b = t ? ANSI.bold : ""
        let g = t ? ANSI.gray : ""
        let r = t ? ANSI.reset : ""

        fputs("""
          \(h)fm respond\(r)
          \(g)Generate a response to a prompt.\(r)

          \(h)USAGE\(r)
            \(g)%\(r) fm respond 'What is Swift?'
            \(g)%\(r) fm respond --model pcc 'What is Swift?'
            \(g)%\(r) fm respond --image photo.jpg --text 'What is in this image?'
            \(g)%\(r) echo 'What is Swift?' | fm respond

          \(h)ARGUMENTS\(r)
            \(b)<prompt>                \(r)Prompt for the model to respond to

          \(h)OPTIONS\(r)
            \(b)-m, --model <model>     \(r)Model to use (system, pcc)
            \(b)-i, --instructions <t>  \(r)Instructions for the model to follow
            \(b)--schema <file>         \(r)Path to a JSON schema file
            \(b)--text <text>           \(r)Text segment to include in the prompt
            \(b)--image <path>          \(r)Image file path to include in the prompt
            \(b)--[no-]stream           \(r)Stream the output as it's generated (default: on)
            \(b)-g, --greedy            \(r)Use greedy sampling
            \(b)-v, --verbose           \(r)Print verbose output
            \(b)-h, --help              \(r)Show help information

          \(h)MODELS\(r)
            \(b)system        \(r)On-device Apple Foundation Model \(g)(default)\(r)
            \(b)pcc           \(r)Apple Foundation Model on Private Cloud Compute

        """, file)
    }

    // MARK: chat

    static func printChat(to file: UnsafeMutablePointer<FILE> = stdout) {
        let t = ANSI.isTerminal(file)
        let h = t ? ANSI.teal + ANSI.bold : ""
        let b = t ? ANSI.bold : ""
        let g = t ? ANSI.gray : ""
        let r = t ? ANSI.reset : ""
        let i = t ? ANSI.italic + g : ""

        fputs("""
          \(h)fm chat\(r)
          \(g)Start an interactive chat session.\(r)

          \(h)USAGE\(r)
            \(g)%\(r) fm chat
            \(g)%\(r) fm chat --model pcc
            \(g)%\(r) fm chat --instructions 'You are a helpful coding assistant'

          \(h)OPTIONS\(r)
            \(b)-m, --model <model>     \(r)Model to use (system, pcc)
            \(b)-i, --instructions <t>  \(r)Instructions for the model
            \(b)-h, --help              \(r)Show help information

          \(i)Type /exit or /quit to end the session.\(r)

        """, file)
    }

    // MARK: token-count

    static func printTokenCount(to file: UnsafeMutablePointer<FILE> = stdout) {
        let t = ANSI.isTerminal(file)
        let h = t ? ANSI.teal + ANSI.bold : ""
        let b = t ? ANSI.bold : ""
        let g = t ? ANSI.gray : ""
        let r = t ? ANSI.reset : ""
        let i = t ? ANSI.italic + g : ""

        fputs("""
          \(h)fm token-count\(r)
          \(g)Count the tokens in a prompt, instructions, or saved transcript.\(r)

          \(h)USAGE\(r)
            \(g)%\(r) fm token-count 'What is Swift?'
            \(g)%\(r) fm token-count -i 'You are a helpful assistant' 'What is Swift?'
            \(g)%\(r) fm token-count -i 'Answer concisely'
            \(g)%\(r) fm token-count --image photo.jpg --text 'Describe this image'
            \(g)%\(r) echo 'What is Swift?' | fm token-count

          \(h)ARGUMENTS\(r)
            \(b)<prompt>                \(r)Prompt to count tokens for

          \(h)OPTIONS\(r)
            \(b)-i, --instructions <t>  \(r)Instructions to include in the count
            \(b)--text <t>              \(r)Additional text segment to include (repeatable)
            \(b)--image <path>          \(r)Image to include in the prompt (repeatable)
            \(b)-q, --quiet             \(r)Print only the integer count
            \(b)-h, --help              \(r)Show help information

          \(i)Only works with the on-device system model. Output is 'Token count: N' in a terminal and a bare integer when piped; use --quiet to force the bare form.\(r)

        """, file)
    }

    // MARK: available

    static func printAvailable(to file: UnsafeMutablePointer<FILE> = stdout) {
        let t = ANSI.isTerminal(file)
        let h = t ? ANSI.teal + ANSI.bold : ""
        let b = t ? ANSI.bold : ""
        let g = t ? ANSI.gray : ""
        let r = t ? ANSI.reset : ""

        fputs("""
          \(h)fm available\(r)
          \(g)Check model availability.\(r)

          \(h)USAGE\(r)
            \(g)%\(r) fm available
            \(g)%\(r) fm available --model system
            \(g)%\(r) fm available --model pcc

          \(h)OPTIONS\(r)
            \(b)-m, --model <model>     \(r)Model to check (system, pcc); checks all if omitted
            \(b)-h, --help              \(r)Show help information

        """, file)
    }

    // MARK: agent

    static func printAgent(to file: UnsafeMutablePointer<FILE> = stdout) {
        let t = ANSI.isTerminal(file)
        let h = t ? ANSI.teal + ANSI.bold : ""
        let b = t ? ANSI.bold : ""
        let g = t ? ANSI.gray : ""
        let r = t ? ANSI.reset : ""
        let i = t ? ANSI.italic + g : ""

        fputs("""
          \(h)fm agent\(r)
          \(g)Interactive AI coding agent with file, shell, and web tools.\(r)
          \(g)Powered by Apple Foundation Models — no API key required.\(r)

          \(h)USAGE\(r)
            \(g)%\(r) fm agent
            \(g)%\(r) fm agent 'Fix the build error in main.swift'
            \(g)%\(r) fm agent --model pcc --no-confirm

          \(h)OPTIONS\(r)
            \(b)-m, --model <model>     \(r)Model: system or pcc (default: system)
            \(b)--system <file>         \(r)System prompt file (default: AGENTS.md)
            \(b)--no-tools              \(r)Disable all tools (plain chat)
            \(b)--no-confirm, --yolo    \(r)Run shell commands without confirmation
            \(b)--no-stream             \(r)Wait for the full reply instead of streaming
            \(b)-h, --help              \(r)Show help information

          \(h)MODELS\(r)
            \(b)system        \(r)On-device Apple Foundation Model \(g)(default)\(r)
            \(b)pcc           \(r)Private Cloud Compute
            \(i)pcc falls back to system automatically if it is unavailable.\(r)

          \(h)ENVIRONMENT\(r)
            \(b)SHELL_TOOL_CONFIRMATION \(r)Confirm shell commands (1/0, default 1)

          \(h)TOOLS\(r)
            \(b)read_file   \(r)Read file contents (with line range)
            \(b)write_file  \(r)Create or overwrite a file
            \(b)edit_file   \(r)Replace exact text in a file
            \(b)run_shell   \(r)Execute a shell command
            \(b)list_dir    \(r)List directory contents
            \(b)grep        \(r)Search file contents with regex
            \(b)glob        \(r)Find files by pattern
            \(b)web_search  \(r)Search the web (DuckDuckGo)
            \(b)read_url    \(r)Fetch and read a URL

          \(h)REPL COMMANDS\(r)
            \(b)/clear       \(r)Start a fresh conversation
            \(b)/model       \(r)Show the active model
            \(b)/quit        \(r)Exit (also: exit, quit, Ctrl-D)

          \(i)Place an AGENTS.md file in your project root for project-specific instructions.\(r)

        """, file)
    }
}
