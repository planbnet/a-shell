import Foundation

// MARK: - Stream resolution
//
// When built as part of ios_system, thread_stdout/thread_stderr/thread_stdin are
// per-command thread-local FILE* set by ios_system before calling the entry point.
// In the standalone CLI build they are absent; we fall back to Darwin streams.

#if canImport(ios_system)
import ios_system
public var fm_stdout: UnsafeMutablePointer<FILE> { thread_stdout ?? Darwin.stdout }
public var fm_stderr: UnsafeMutablePointer<FILE> { thread_stderr ?? Darwin.stderr }
public var fm_stdin:  UnsafeMutablePointer<FILE> { thread_stdin  ?? Darwin.stdin  }
#else
public var fm_stdout: UnsafeMutablePointer<FILE> { Darwin.stdout }
public var fm_stderr: UnsafeMutablePointer<FILE> { Darwin.stderr }
public var fm_stdin:  UnsafeMutablePointer<FILE> { Darwin.stdin  }
#endif

// MARK: - ANSI helpers

public enum ANSI {
    public static let reset  = "\u{1B}[0m"
    public static let bold   = "\u{1B}[1m"
    public static let italic = "\u{1B}[3m"
    public static let teal   = "\u{1B}[38;2;55;195;160m"
    public static let gray   = "\u{1B}[38;2;153;153;153m"
    public static let red    = "\u{1B}[38;2;255;107;128m"

    public static func isTerminal(_ file: UnsafeMutablePointer<FILE>) -> Bool {
        isatty(fileno(file)) != 0
    }
}
