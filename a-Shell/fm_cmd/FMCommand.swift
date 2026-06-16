import Foundation

// MARK: - Public dispatcher
// Called by both the ios_system entry point and the standalone CLI.

@discardableResult
public func fmDispatch(
    arguments: [String],
    input:  UnsafeMutablePointer<FILE>,
    output: UnsafeMutablePointer<FILE>,
    error:  UnsafeMutablePointer<FILE>
) -> Int32 {

    guard arguments.count >= 2 else {
        Help.printRoot(to: output)
        return 0
    }

    let sub  = arguments[1]
    let rest = Array(arguments.dropFirst(2))

    switch sub {
    case "respond":
        return RespondCommand.run(args: rest, input: input, output: output, error: error)
    case "chat":
        return ChatCommand.run(args: rest, input: input, output: output, error: error)
    case "token-count":
        return TokenCountCommand.run(args: rest, input: input, output: output, error: error)
    case "agent":
        return AgentCommand.run(args: rest, input: input, output: output, error: error)
    case "available":
        return AvailableCommand.run(args: rest, output: output, error: error)
    case "--help", "-h", "help":
        Help.printRoot(to: output)
        return 0
    default:
        let t = ANSI.isTerminal(error)
        let red = t ? ANSI.red : ""
        let rst = t ? ANSI.reset : ""
        fputs("\(red)Error: Unknown command '\(sub)'.\nRun 'fm --help' for the list of commands.\n\(rst)", error)
        return 1
    }
}

// MARK: - ios_system entry point
//
// Registered in a-Shell's AppDelegate with:
//   replaceCommand("fm", "fm_main", true)
//
// ios_system calls fm_main(argc, argv) on a command thread.
// thread_stdout / thread_stderr / thread_stdin are already set before this call.

#if canImport(ios_system)
import ios_system

@_cdecl("fm_main")
public func fm_main(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    let args = (0..<Int(argc)).compactMap { i -> String? in
        guard let ptr = argv?[i] else { return nil }
        return String(cString: ptr)
    }
    return fmDispatch(arguments: args, input: fm_stdin, output: fm_stdout, error: fm_stderr)
}
#endif
