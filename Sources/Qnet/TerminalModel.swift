import Foundation
import AppKit
@preconcurrency import SwiftTerm

/// Lock-protected byte buffer fed from SwiftTerm's background pty
/// reader. Lives outside `TerminalModel`'s @MainActor isolation so the
/// reader can append synchronously and the very last bytes printed
/// before app quit can't be stranded behind an unprocessed
/// `Task { @MainActor }` hop.
final class PendingByteBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    func append(_ slice: ArraySlice<UInt8>) {
        lock.lock()
        bytes.append(contentsOf: slice)
        lock.unlock()
    }

    func drain() -> [UInt8] {
        lock.lock()
        let out = bytes
        bytes.removeAll(keepingCapacity: true)
        lock.unlock()
        return out
    }

    func clear() {
        lock.lock()
        bytes.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

/// Character-width meter for the raw pty byte stream.
///
/// `TerminalModel.minTerminalWidth` — which widens the terminal NSView and
/// engages the horizontal overlay scroller — was fed only by the two
/// Swift-generated reports that call `reportLongestLineChars`. No solver run
/// ever measured itself, so a Run Comparison row (label + five columns of
/// "value (+12.3%)", 95–110 characters) hard-wrapped mid-number in a shell
/// narrower than that, with no scroller offered to recover it.
///
/// Measuring the *stream* rather than SwiftTerm's reflowed buffer is what
/// makes the measurement safe: the stream carries the line the solver
/// actually printed, independent of how many columns the view happens to
/// have, so widening the view cannot lengthen the lines we measure and
/// there is no sizeChanged → layoutTerminal → wider → sizeChanged loop.
///
/// Lives outside `TerminalModel`'s `@MainActor` isolation because the only
/// caller that runs often enough to be useful is SwiftTerm's pty reader
/// thread (`dataReceived`); the main-actor drain of `pendingBytes` happens
/// on a 10 s backstop, far too late to keep a table from wrapping. The scan
/// therefore touches no main-actor state: it returns a new peak and lets the
/// caller hop, which happens only when the peak actually grows (a handful of
/// times per run, never per byte).
final class TerminalLineWidthMeter: @unchecked Sendable {
    /// Ceiling on a stream-measured line, in characters.
    ///
    /// SwiftTerm allocates every scrollback line at the current column count
    /// (5,000 lines here), so an unbounded peak — one runaway `printf` with
    /// no newline, or a corrupted binary dumped to the terminal — would turn
    /// into a hundred megabytes of cells and a scroller with no bottom. 240
    /// is twice the widest table Qnet prints and comfortably wider than any
    /// solver banner, so nothing legitimate is clipped by it.
    static let maxMeasuredColumns = 240

    /// Where the scanner is inside an escape sequence. CSI (`ESC [ … final`)
    /// and the string sequences (OSC / DCS / PM / APC, terminated by BEL or
    /// ST) have different terminators, and conflating them is what makes a
    /// naive scanner over-count: macOS's shell integration emits
    /// `ESC ] 7 ; file:///long/path BEL` before *every* prompt, and a
    /// CSI-shaped scan stops at the "f" of "file" and then counts the path.
    private enum State {
        case text
        case escape
        case csi
        case string       // OSC / DCS / PM / APC payload
        case stringEscape // saw ESC inside a string payload: ST if "\" follows
    }

    private let lock = NSLock()
    private var state: State = .text
    private var column = 0
    /// Furthest column this line has painted, which is not the same as where
    /// the cursor now is: BS moves the cursor left without erasing anything,
    /// so `"abcd"` + two BS is still a four-character line. Recording
    /// `column` at the line break under-measured every renderer that erases
    /// by backing up — and under-measuring is what leaves a wide table
    /// wrapped with no scroller offered.
    private var lineHighWater = 0
    private var peak = 0
    /// Highest value already handed to `TerminalModel.reportLongestLineChars`.
    /// Kept here so two chunks scanned back to back cannot report the same
    /// peak twice, and so `reset()` stays in step with the model's own
    /// monotonic peak.
    private var reportedPeak = 0
    /// True between `ESC[?1049h` / `?47h` / `?1047h` and the matching reset.
    /// Full-screen programs (vim, less, htop) paint absolute cursor positions
    /// rather than lines; measuring them would report nonsense, and they need
    /// no horizontal scroller because they draw to fit the view. Read back
    /// by `commandBlocker` too, alongside SwiftTerm's own
    /// `isCurrentBufferAlternate`: this latch is set on the reader the
    /// instant the bytes land, before SwiftTerm has parsed them.
    private var altScreen = false
    /// Numeric parameters of the CSI sequence being scanned. Reserved once at
    /// init and cleared with `keepingCapacity`, so the reader path allocates
    /// nothing after the first sequence.
    private var params = ContiguousArray<Int>()
    private var paramValue = 0
    private var paramHasDigits = false
    private var csiPrivate = false
    /// `CFAbsoluteTimeGetCurrent()` of the most recent chunk, as the cheapest
    /// "is the shell producing output right now" signal available.
    private var lastOutputAt: CFAbsoluteTime = 0

    init() {
        params.reserveCapacity(8)
    }

    /// Scans one chunk from the pty and returns the new peak line width when
    /// it grew past everything already reported, else nil. Call it from
    /// whichever thread SwiftTerm delivers bytes on; it allocates nothing.
    func scan(_ slice: ArraySlice<UInt8>) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        lastOutputAt = CFAbsoluteTimeGetCurrent()

        for byte in slice {
            switch state {
            case .text:      consumeText(byte)
            case .escape:    consumeEscape(byte)
            case .csi:       consumeCSI(byte)
            case .string:    consumeString(byte)
            case .stringEscape:
                // ESC \ is ST and ends the payload; anything else was an
                // embedded ESC we simply keep skipping.
                state = (byte == 0x5C) ? .text : .string
            }
        }

        guard peak > reportedPeak else { return nil }
        reportedPeak = peak
        return peak
    }

    /// True while a full-screen program owns the screen.
    var isAlternateScreen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return altScreen
    }

    /// Seconds since the last byte arrived from the child shell. Huge before
    /// the first byte, so a shell that has printed nothing at all never reads
    /// as "busy".
    var secondsSinceLastOutput: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard lastOutputAt > 0 else { return .greatestFiniteMagnitude }
        return CFAbsoluteTimeGetCurrent() - lastOutputAt
    }

    /// Forgets the measured peak. Called from `clearTerminal()` and
    /// `restart()`, which reset the model's peak and `minTerminalWidth` for
    /// the same reason: the wide content is gone, so the scroller must retract.
    /// The alt-screen flag is deliberately preserved by `clearScrollback` —
    /// clearing the screen does not quit the program that owns it.
    func clearScrollback() {
        lock.lock()
        defer { lock.unlock() }
        peak = 0
        reportedPeak = 0
        column = 0
        lineHighWater = 0
    }

    /// Full reset for a brand-new shell process: the alt-screen latch goes
    /// too, because the program that set it died with the old pty.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        state = .text
        column = 0
        lineHighWater = 0
        peak = 0
        reportedPeak = 0
        altScreen = false
        params.removeAll(keepingCapacity: true)
        paramValue = 0
        paramHasDigits = false
        csiPrivate = false
        lastOutputAt = 0
    }

    // MARK: Scanner

    private func endLine() {
        if !altScreen, lineHighWater > peak {
            peak = min(lineHighWater, Self.maxMeasuredColumns)
        }
        column = 0
        lineHighWater = 0
    }

    /// Call after every cursor move that could have painted, so the line's
    /// width follows the furthest glyph rather than the last cursor position.
    private func noteColumn() {
        if column > lineHighWater { lineHighWater = column }
    }

    private func consumeText(_ byte: UInt8) {
        switch byte {
        case 0x1B: state = .escape
        case 0x0A, 0x0B, 0x0C: endLine()          // LF / VT / FF
        case 0x0D: endLine()                      // CR — progress bars redraw
        // BS moves the cursor; it paints nothing and erases nothing, so the
        // line keeps the width it already had. `lineHighWater` is what
        // remembers that.
        case 0x08: column = max(0, column - 1)    // BS
        case 0x09:                                // HT, SwiftTerm's tab stop
            column = (column / 8 + 1) * 8
            noteColumn()
        case 0x00...0x1F, 0x7F: break             // other C0 paint nothing
        default:
            // UTF-8 continuation bytes belong to a character already counted,
            // so one column per lead byte.
            //
            // KNOWN LIMITATION, deliberately not closed: a double-width
            // glyph — CJK, fullwidth forms, most emoji — occupies two cells
            // in SwiftTerm and is counted here as one, so `日本語です。`
            // measures 6 where the terminal renders 12. The meter therefore
            // under-counts such a line and never over-counts it, and the only
            // consequence of under-counting is that `desiredMinWidth` stays
            // below the true width and the horizontal scroller is not
            // offered. No text is truncated or lost: SwiftTerm wraps, exactly
            // as it did before this meter existed.
            //
            // What this meter exists for is the solver comparison table,
            // which is ASCII by construction (`QnetGUIApp`'s awk formatters
            // emit only digits, ASCII punctuation and box-drawing that is
            // itself narrow). Closing the gap properly means an
            // East-Asian-Width table; the cheap 90 % version is decoding the
            // scalar here and adding 2 for the wide blocks (U+1100–115F,
            // U+2E80–A4CF, U+AC00–D7A3, U+F900–FAFF, U+FE30–FE6F,
            // U+FF00–FF60, U+FFE0–FFE6, U+1F300 and up). Both cost a
            // multi-byte accumulator in a per-byte path that today allocates
            // nothing and runs on SwiftTerm's pty reader — a real price for a
            // scroller nothing in Qnet's own output needs.
            if byte & 0xC0 != 0x80 {
                column += 1
                noteColumn()
            }
        }
    }

    private func consumeEscape(_ byte: UInt8) {
        switch byte {
        case 0x5B: // [
            state = .csi
            params.removeAll(keepingCapacity: true)
            paramValue = 0
            paramHasDigits = false
            csiPrivate = false
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F: // ] OSC, P DCS, X SOS, ^ PM, _ APC
            state = .string
        default:
            // Two-character escape (ESC 7, ESC =, ESC M …): consumed whole.
            state = .text
        }
    }

    private func consumeCSI(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39: // digit
            paramValue = paramValue * 10 + Int(byte - 0x30)
            paramHasDigits = true
            return
        case 0x3B: // ;
            pushParam()
            return
        case 0x3C...0x3F: // < = > ? — private-parameter marker
            if byte == 0x3F { csiPrivate = true }
            return
        case 0x20...0x2F: // intermediate bytes
            return
        case 0x40...0x7E: // final byte
            pushParam()
            applyCSI(final: byte)
            state = .text
        default:
            // A C0 byte inside a sequence aborts it in a real terminal.
            state = .text
            consumeText(byte)
        }
    }

    private func pushParam() {
        if paramHasDigits, params.count < 8 { params.append(paramValue) }
        paramValue = 0
        paramHasDigits = false
    }

    private func applyCSI(final: UInt8) {
        if csiPrivate, final == 0x68 || final == 0x6C { // h = set, l = reset
            let set = (final == 0x68)
            for mode in params where mode == 47 || mode == 1047 || mode == 1049 {
                altScreen = set
            }
            return
        }
        // EL — erase in line. The counterpart to the high-water mark: now
        // that the width follows the furthest glyph rather than the cursor,
        // something has to notice when those glyphs are taken away again.
        // `ESC[K` / `ESC[0K` clears from the cursor rightward, so what is
        // left is exactly the columns before it; `ESC[2K` clears the row
        // outright. `ESC[1K` clears leftward and leaves the right-hand cells
        // in place, so the line is no narrower than it was.
        if final == 0x4B {
            switch params.first ?? 0 {
            case 0: lineHighWater = min(lineHighWater, column)
            case 2: lineHighWater = 0
            default: break
            }
            return
        }
        // Any cursor motion ends the run of text we were measuring: the
        // characters printed before it really were on that line, and the
        // ones after it are not a continuation of it. Without this a
        // full-screen repaint that never emits a newline accumulates every
        // row of the screen into one enormous "line".
        //   A B  cursor up / down        E F  next / previous line
        //   C D  cursor forward / back   G d  column / row absolute
        //   H f  cursor position         `    HPA
        switch final {
        case 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x60, 0x64, 0x66:
            endLine()
        default:
            break
        }
    }

    private func consumeString(_ byte: UInt8) {
        switch byte {
        case 0x07: state = .text   // BEL terminates OSC
        case 0x1B: state = .stringEscape
        default: break
        }
    }
}

/// Outcome of the most recent scripted solver run, shown in the status
/// bar's trailing segment.
struct TerminalRunSummary: Equatable {
    let id: UUID
    let label: String
    let ownerID: UUID
    let ownerTitle: String
    let exitCode: Int32
    let elapsed: TimeInterval
    let finishedAt: Date

    /// True when Stop was pressed for THIS run before it ended, recorded by
    /// `finishRun` from the model's `cancelRequestedAt`. It is the primary
    /// signal, because the exit status of a stopped run is a race: the
    /// cancellation path escalates SIGINT -> SIGTERM -> SIGKILL and the
    /// wrapper reports whichever signal won (130, 143, 129 after a lost
    /// controlling terminal, 137 after the kill), so a whitelist of codes
    /// made the user-visible outcome depend on that race.
    let userStopped: Bool

    var succeeded: Bool { exitCode == 0 }

    /// True when the run ended because the user stopped it.
    ///
    /// `userStopped` covers every signal the escalation can end on. The
    /// exit-code arm stays for a run the user interrupted in the shell
    /// itself with ^C (or SIGTERM from outside the app), where Stop was
    /// never pressed and bash reports 128 + the signal.
    ///
    /// A run that exited 0 is never "cancelled": Stop pressed in the same
    /// instant a solver finished must not discard a completed result.
    var cancelled: Bool {
        guard exitCode != 0 else { return false }
        return userStopped
            || exitCode == Self.cancelledExitCode
            || exitCode == 143
    }

    /// Exit status of a run that was interrupted (bash's 128 + SIGINT).
    static let cancelledExitCode: Int32 = 130

    var text: String {
        let time = Self.duration(elapsed)
        if succeeded { return "\(label) finished in \(time)" }
        if cancelled { return "\(label) cancelled after \(time)" }
        return "\(label) failed (exit \(exitCode)) after \(time)"
    }

    /// One duration format for the summary: tenths under 10 s, whole
    /// seconds under a minute, `m:ss` beyond — so "finished in 3.2 s",
    /// "cancelled after 42 s" and "failed after 1:12" all read the same way.
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1f s", seconds) }
        if seconds < 60 { return String(format: "%.0f s", seconds) }
        return clock(seconds)
    }

    /// `m:ss` for a live elapsed clock (`0:07`, `12:41`). Monospaced
    /// digits at the call site keep it from jittering.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Why a scripted command cannot be typed into the interactive shell.
///
/// Solver launches share the shell with the user, so "is a run already
/// active" (`TerminalModel.beginRun`) and "is the shell free" are two
/// different questions. This is the second one, and its `message` is written
/// to be actionable in the status log rather than merely descriptive.
enum ShellCommandBlocker {
    /// The Shell pane has never been shown this launch, so there is no
    /// terminal to type into. Two ways in, and both are ordinary: the pane
    /// simply starts hidden, or another pane was restored maximized
    /// (`panes.soloed`), which keeps `ContentView.shows(.shell)` false and so
    /// keeps `TerminalPaneView` unmounted. Once shown, the view is cached for
    /// the life of the shell process, so hiding the pane *again* does not
    /// come back here — this is strictly the never-opened case.
    case shellUnavailable
    /// The child shell has exited; the pane offers a Restart button.
    case shellNotRunning
    /// A full-screen program (vim, less, htop) owns the screen or the mouse.
    case fullScreenProgram
    /// Something is printing, or a command is reading standard input.
    case busy

    var message: String {
        switch self {
        case .shellUnavailable:
            return "The Shell has not been opened yet — show it with Window ▸ Focus Shell, then run again."
        case .shellNotRunning:
            return "The Shell is not running — use Restart Shell in the Shell pane header first."
        case .fullScreenProgram:
            return "The Shell is busy — quit the full-screen program running there first."
        case .busy:
            return "The Shell is busy — finish or interrupt what is running there first."
        }
    }
}

@MainActor
final class TerminalModel: ObservableObject {
    @Published var sessionDirectoryDisplay: String = ""
    @Published var isShellRunning = false
    @Published var terminalViewID = UUID()
    /// Pixel width the terminal NSView should be at minimum. Grows when the
    /// app prints content with long lines (e.g. multi-sentence warnings) so
    /// the enclosing horizontal ScrollView activates its scrollbar; resets to
    /// 0 on restart/clear so an idle shell fills the window exactly.
    /// Derived from `longestLineChars`, `fontSize`, and `fontName`; rebuilt
    /// on every change so shrinking the font or picking a narrower font may
    /// retract the scrollbar.
    @Published private(set) var minTerminalWidth: CGFloat = 0
    /// The longest single line (in characters) recorded since the last clear
    /// or restart. Used to rebuild `minTerminalWidth` whenever the font size
    /// or family changes.
    private var longestLineChars: Int = 0
    /// Point size used for the terminal font. Initialized from UserDefaults
    /// and persisted back on every change so size selection survives relaunch.
    @Published var fontSize: CGFloat
    /// Font family name (e.g. "Menlo", "Monaco"). Empty string means "system
    /// monospaced default". Persisted the same way as `fontSize`.
    @Published var fontName: String

    // ── Run state (status bar) ──

    /// Human-readable label of the scripted run currently executing in
    /// the shell ("Spectral", "Run Comparison"), or nil when idle. Set by
    /// `beginRun(label:)` from QnetGUIApp's `runScript` / `silentScript`.
    @Published private(set) var activeRun: String?
    /// Stable identity and document ownership for the active shell job.
    /// The UUID scopes every coordination file; owner metadata keeps Stop
    /// messages and solver diagnostics attached to the tab that launched
    /// the run even if the user switches tabs while it is executing.
    @Published private(set) var activeRunID: UUID?
    @Published private(set) var activeRunOwnerID: UUID?
    @Published private(set) var activeRunOwnerTitle: String?
    /// Result of the last completed scripted run.
    @Published private(set) var lastRunSummary: TerminalRunSummary?
    /// Plain-text capture of the last scripted run's standard output. The
    /// UUID on `lastRunSummary` identifies the matching Results record. This
    /// is intentionally separate from the interactive terminal scrollback:
    /// it contains only one wrapper invocation and can therefore be parsed
    /// into structured measurements without scraping unrelated shell text.
    @Published private(set) var lastRunOutput: String?
    /// Fraction of the active run that is done (0…1), when the solver
    /// reports a total through its `-P <file>` progress file. Nil while a
    /// run is opaque, so the status bar falls back to the indeterminate
    /// spinner rather than lying with a bar that never moves.
    @Published private(set) var runProgress: Double?
    /// Seconds the active run has been going, ticked by `runPollTask`.
    @Published private(set) var runElapsed: TimeInterval = 0
    /// True once the running script has reported its pid. A TOOLTIP HINT
    /// only: Stop is enabled on `activeRun != nil` alone, and
    /// `cancelActiveRun` waits for the pid itself when it has not been
    /// written yet, so ⌘. is never dead during the first poll interval.
    @Published private(set) var canCancelRun = false
    private var runStartedAt: Date?
    private var runPollTask: Task<Void, Never>?
    /// Originating-tab sink captured when the run begins. This is the only
    /// destination for run lifecycle messages; callers' fallback reporters
    /// are retained for source compatibility with existing Stop buttons.
    private var activeRunReporter: (@MainActor (String, StatusSeverity) -> Void)?
    /// The same sink, but NOT cleared by `finishRun`. The shell outlives every
    /// individual run and is shared by every tab, so a problem reported
    /// between runs — a command refused with no run registered — still has to
    /// land in a log the user can read. The tab that most recently used the
    /// shell is the best available guess at which one that is; the alternative
    /// is a beep with no words, which is what this exists to prevent.
    private var lastStatusReporter: (@MainActor (String, StatusSeverity) -> Void)?
    /// Per-run diagnostics inbox written by `runWithStderrOnFailure`.
    private var runStatusPath: String?
    /// Append-only inbox cursor and any record fragment after the most recent
    /// sentinel. Keeping both in memory avoids truncating a file while the
    /// shell still has it open for a multi-write diagnostic record.
    private var runStatusConsumedBytes: Int = 0
    private var runStatusRemainder = ""
    /// Per-run completion path, retained so all coordination artifacts can
    /// be cleaned up from the same ownership record.
    private var runDonePath: String?
    /// A tee capture of stdout for this run. The wrapper writes the completion
    /// file only after tee has closed, so the parser never observes a partial
    /// final table.
    private var runOutputPath: String?
    /// Path the active script writes its pid to (see `beginRun`).
    private var runPIDPath: String?
    /// When Stop was pressed. The poller escalates to SIGTERM once after
    /// `Self.cancelEscalateAfter` and gives up on the wrapper after
    /// `Self.cancelDeadline`, so a solver that traps SIGINT cannot leave
    /// the status bar ticking for the rest of the session.
    private var cancelRequestedAt: Date?
    private var cancelEscalated = false
    private var cancelKilled = false
    private var cancelRetryTask: Task<Void, Never>?
    /// Process group of the running job, captured from the wrapper's pid
    /// *while the wrapper is still alive*.
    ///
    /// This is the difference between Stop stopping the solver and Stop
    /// only stopping the status bar. The wrapper launches the solver as a
    /// background job (`{ … } &`), so the solver is a grandchild in the
    /// wrapper's process group — and a background job inherits SIG_IGN for
    /// SIGINT, so the SIGINT that kills the wrapper leaves the solver
    /// running with every core pinned. Deriving the group later with
    /// `getpgid(activeRunPID)` is then useless: the wrapper is gone, the
    /// call fails, and SIGTERM/SIGKILL fall back to a dead pid. Recording
    /// the group once means the escalation still lands on the survivors,
    /// which keep the group id they were started in even after the kernel
    /// reparents them to init.
    private var activeRunGroup: pid_t?
    /// Seconds after SIGINT before the run is sent SIGTERM as well.
    static let cancelEscalateAfter: TimeInterval = 1.5
    /// Seconds after SIGINT before an unresponsive, identified wrapper is
    /// sent SIGKILL. The run remains owned until that process is gone, so a
    /// late wrapper cannot overlap a newly accepted run.
    static let cancelDeadline: TimeInterval = 3
    /// Hard bound on holding a cancelled run open while its process group
    /// still has members. SIGKILL has already been sent by this point; a
    /// group that outlives it is stuck in the kernel (uninterruptible I/O)
    /// and nothing the app does will change that, so the run is retired
    /// rather than owning the single-flight slot for the rest of the
    /// session.
    static let cancelAbandonAfter: TimeInterval = 10
    /// Progress files registered for the run that is about to start, in
    /// the order the script will use them. A comparison run registers one
    /// per sub-solver; the poller reads whichever exists right now.
    private var pendingProgressFiles: [String] = []
    private var activeProgressFiles: [String] = []

    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 28

    static let fontSizeKey = "shell.fontSize"
    static let fontNameKey = "shell.fontName"
    /// Legacy key — used to store the SwiftTerm buffer rendered as
    /// plain text. Kept only for one-shot migration (loaded as a
    /// fallback when the new raw-bytes blob is absent) and removed
    /// from defaults the first time we save a fresh raw-bytes blob.
    static let savedTranscriptKey = "shell.savedTranscript"
    /// Persisted Interactive Shell output as the raw byte stream the
    /// child shell emitted during the previous session. Captured by
    /// intercepting `LocalProcessTerminalView.dataReceived` so escape
    /// sequences (color, cursor moves, alt-screen toggles, output of
    /// `ls -la`, vim/less, etc.) all round-trip exactly. Replayed on
    /// the next launch via `tv.feed(byteArray:)`.
    static let savedRawBytesKey = "shell.savedRawBytes"
    /// Hard cap on the number of bytes persisted (and replayed) per
    /// session. 1 MiB comfortably covers a long working day's output
    /// while keeping UserDefaults writes cheap. The in-memory buffer
    /// is allowed to grow to 2× this before being trimmed back to
    /// `maxCapturedBytes`, amortizing the trim cost.
    static let maxCapturedBytes = 1_048_576

    /// Commands are assembled before a run UUID is allocated. Solver stderr
    /// wrappers write to this marker; the launcher substitutes the run's
    /// unique inbox path before creating the shell script.
    static let statusInboxPlaceholder = "__QNET_ACTIVE_RUN_STATUS_INBOX__"

    init() {
        let savedSize = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        self.fontSize = savedSize > 0
            ? min(max(CGFloat(savedSize), Self.minFontSize), Self.maxFontSize)
            : 12
        self.fontName = UserDefaults.standard.string(forKey: Self.fontNameKey) ?? ""
    }

    /// Live capture of every byte the child shell has emitted since
    /// the last `restart()` / `clearTerminal()`. Fed by
    /// `appendCapturedBytes` from the terminal view's `dataReceived`
    /// override and snapshotted to UserDefaults in `saveTranscript`.
    private var capturedBytes: [UInt8] = []

    /// Thread-safe staging area for bytes that arrive from SwiftTerm's
    /// pty reader thread. The reader writes here synchronously (no actor
    /// hop) so the latest bytes are visible to `saveTranscript` even
    /// when the app is quitting before any queued main-actor task can
    /// run. `drainPendingBytes()` moves them into `capturedBytes`.
    nonisolated let pendingBytes = PendingByteBuffer()

    /// Measures the width of the lines the shell prints, straight off the
    /// pty. Fed from the same reader callback as `pendingBytes` (see
    /// `TerminalConsoleView.buildTerminal`) and read back on the main actor
    /// through `reportLongestLineChars`, so wide solver tables engage the
    /// horizontal scroller instead of hard-wrapping.
    nonisolated let lineMeter = TerminalLineWidthMeter()

    /// True while SwiftTerm reports an active selection in the shell.
    /// Published because Edit ▸ Copy's enablement follows it: SwiftTerm's
    /// view is an NSView rather than an NSText, so the responder-chain test
    /// the other clipboard items use (`menuContext.textInputHasFocus`)
    /// cannot see a shell selection. Updated from SwiftTerm's
    /// `selectionChanged` delegate callback, never polled.
    @Published private(set) var hasShellSelection = false

    weak var terminalView: LocalProcessTerminalView?

    /// The AppKit container that hosts the terminal, scrollers and find
    /// bar. Cached here so SwiftUI can drop and re-create the
    /// `SwiftTermView` representable (pane collapse, AI toggle, split
    /// restructuring) without tearing down the shell process: the
    /// representable simply re-parents this view. Rebuilt only by
    /// `restart()`, which bumps `terminalViewID`.
    var hostView: NSView?
    /// `terminalViewID` the cached `hostView` was built for.
    var hostViewID: UUID?

    /// Invoked right after `clearTerminal()` empties the buffer. The view
    /// coordinator uses this to re-sync the external scrollers (so a stale
    /// vertical scroller enable-state doesn't persist past the clear).
    var onAfterClear: (() -> Void)?

    /// Destroys the current terminal and creates a fresh one.
    func restart() {
        terminalView?.process?.terminate()
        hostView?.removeFromSuperview()
        hostView = nil
        hostViewID = nil
        terminalView = nil
        terminalViewID = UUID()
        longestLineChars = 0
        minTerminalWidth = 0
        capturedBytes.removeAll(keepingCapacity: true)
        pendingBytes.clear()
        // Full reset, alt-screen latch included: whatever full-screen
        // program owned the old pty died with it.
        lineMeter.reset()
        hasShellSelection = false
        isShellRunning = false
    }

    /// Wipes the terminal entirely: visible rows, off-screen scrollback,
    /// and the recorded longest-line width. Sends Ctrl-L afterward so the
    /// running shell redraws its prompt into the now-empty view.
    func clearTerminal() {
        guard let tv = terminalView else { return }

        // Feed the terminal three standard ANSI sequences — this routes
        // through SwiftTerm's parser so its active `buffer` reference, the
        // display, and yBase/yDisp all stay consistent:
        //   ESC[3J → erase scrollback (xterm extension; SwiftTerm trims
        //            buffer.lines so canScroll becomes false)
        //   ESC[2J → erase the visible viewport
        //   ESC[H  → move cursor to home (1,1)
        tv.feed(text: "\u{1B}[3J\u{1B}[2J\u{1B}[H")

        // Snap the viewport to the top so any residual yDisp offset clears
        // and the vertical scrollbar knob reads "at top" as well as inactive.
        tv.scroll(toPosition: 0)
        tv.needsDisplay = true

        // Ctrl-L → shell reprints its prompt so the user doesn't land on a
        // completely blank screen with no prompt visible.
        let ctrlL: [UInt8] = [0x0C]
        tv.send(source: tv, data: ctrlL[...])

        longestLineChars = 0
        minTerminalWidth = 0
        capturedBytes.removeAll(keepingCapacity: true)
        pendingBytes.clear()
        // The measured peak goes with the content it was measured from, so
        // the horizontal scroller retracts with the wide table that raised
        // it. The alt-screen latch stays: clearing the screen does not quit
        // the program drawing on it.
        lineMeter.clearScrollback()
        hasShellSelection = false

        // Re-sync the external scrollers (vertical goes inactive since the
        // scrollback is empty; horizontal goes inactive since the pane now
        // fits the content).
        onAfterClear?()
    }

    // MARK: - Clipboard / navigation

    /// True while the user has text selected in the shell. Lets the
    /// Copy button say whether it copied the selection or the whole
    /// scrollback.
    var hasSelection: Bool {
        guard let tv = terminalView, let sel = tv.getSelection() else { return false }
        return !sel.isEmpty
    }

    /// One reusable probe. `validateUserInterfaceItem(_:)` answering `copy:`
    /// is the only public route to SwiftTerm's `selection.active`, and it is
    /// the cheap one: `getSelection()` materializes the whole selected text,
    /// which is not something to do on every mouse-drag callback.
    private static let copySelectorProbe = NSMenuItem(
        title: "", action: #selector(NSText.copy(_:)), keyEquivalent: ""
    )

    /// Called from SwiftTerm's `selectionChanged` delegate callback (see
    /// `ScrollForwardingTerminalView`). Publishes only on a real transition,
    /// so dragging out a selection does not re-evaluate the menu bar once
    /// per mouse-moved event.
    func noteSelectionChanged() {
        let active = terminalView?.validateUserInterfaceItem(Self.copySelectorProbe) ?? false
        if hasShellSelection != active { hasShellSelection = active }
    }

    /// Copies the shell selection, or nil when there is none. This is what
    /// ⌘C means in the Shell, and it is deliberately a *different* operation
    /// from `copyEntireScrollback()`: no terminal on the Mac copies its whole
    /// scrollback on an empty-selection ⌘C, and doing so silently replaces
    /// the user's clipboard with five thousand lines they did not ask for.
    @discardableResult
    func copySelection() -> String? {
        guard let tv = terminalView,
              let text = tv.getSelection(), !text.isEmpty else { return nil }
        return put(text)
    }

    /// Copies every line the shell has printed, visible rows and off-screen
    /// scrollback alike. Only ever an *explicit* choice — the pane header
    /// button and the context menu say so in as many words — never the
    /// fallback of a command called "Copy".
    @discardableResult
    func copyEntireScrollback() -> String? {
        guard let tv = terminalView else { return nil }
        let data = tv.getTerminal().getBufferAsData()
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{0}", with: "")
        guard !text.isEmpty else { return nil }
        return put(text)
    }

    /// The selection when there is one, the whole scrollback otherwise.
    ///
    /// Retained for the pane header's Copy button, whose help text already
    /// announces both halves and whose status line then says which one
    /// happened. Do not reach for this from a keyboard command: "copy
    /// everything, silently, because nothing was selected" is a surprise,
    /// not a default. See `copySelection()`.
    @discardableResult
    func copySelectionOrAll() -> String? {
        copySelection() ?? copyEntireScrollback()
    }

    /// One place that writes the pasteboard, so the two copy paths cannot
    /// drift apart in how they clear it.
    private func put(_ text: String) -> String {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return text
    }

    /// Shows SwiftTerm's in-view find bar (searches the scrollback and
    /// scrolls to / highlights each hit).
    func showFind() {
        guard let tv = terminalView else { return }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        tv.window?.makeFirstResponder(tv)
        tv.performTextFinderAction(item)
        // SwiftTerm builds the bar lazily inside that call and pins it to the
        // terminal view, which extends past the pane whenever wide output has
        // made the terminal scrollable — the bar's close button and options
        // are then masked away. Re-anchor it to what the pane actually shows.
        // Idempotent, so every later ⌘F costs one nil check.
        (hostView as? TerminalHostView)?.adoptFindBar()
    }

    /// ⌘G / ⇧⌘G in the shell: step SwiftTerm's scrollback search forward
    /// (`delta >= 0`) or back. Same `performTextFinderAction` route as
    /// `showFind()`, because SwiftTerm implements the standard text-finder
    /// actions and nothing else.
    ///
    /// Deliberately does NOT take first responder the way `showFind()` does:
    /// ⌘G is usually pressed while the find bar's own search field has the
    /// keyboard, and stealing focus back to the terminal would close the
    /// field the user is still typing in.
    func findNext(_ delta: Int) {
        guard let tv = terminalView else { return }
        let item = NSMenuItem()
        item.tag = (delta < 0 ? NSTextFinder.Action.previousMatch
                              : NSTextFinder.Action.nextMatch).rawValue
        tv.performTextFinderAction(item)
    }

    /// Whether Find Next / Find Previous have a term to walk. SwiftTerm
    /// searches for whatever is on the system find pasteboard — its find bar
    /// writes there on every keystroke — so an empty pasteboard means ⌘G
    /// would do nothing. Used for the menu items' tooltip rather than their
    /// enablement: SwiftTerm's find bar is private, so there is no event to
    /// re-evaluate the menu on while the user is typing into it, and a
    /// stale tooltip is a much smaller failure than a dead ⌘G.
    var hasFindTerm: Bool {
        let term = NSPasteboard(name: .find).string(forType: .string)
        return !(term ?? "").isEmpty
    }

    func scrollToBottom() {
        guard let tv = terminalView else { return }
        tv.scroll(toPosition: 1.0)
    }

    /// Gives the terminal keyboard focus.
    func focusTerminal() {
        guard let tv = terminalView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    // MARK: - Run state

    static func displayLabel(forRunLabel label: String) -> String {
        switch label {
        case "inf_cmp", "cmp":  return "Run Comparison"
        case "inf_sim", "sim":  return "Monte Carlo"
        case "inf_sm", "sm":    return "Spectral"
        case "qna":             return "QNA"
        case "rqna":            return "Robust QNA"
        case "sbd":             return "SBD"
        case "mlmc":            return "SRBM MLMC"
        case "lp", "flp":       return "Linear Program"
        case "fm":              return "Finite Element"
        case "mc":              return "Multi-class SRBM"
        case "testset":         return "Test Set"
        case "spc":             return "Spectral Convergence"
        case "primitives":      return "Network Primitives"
        case "analyze":         return "Analyze Network"
        default:                return label.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Identity and paths owned by one shell run. Every path includes `id`,
    /// so a late write from an earlier wrapper can never complete, cancel,
    /// or add diagnostics to a newer run.
    struct RunHandle {
        let id: UUID
        let donePath: String
        let pidPath: String
        let statusPath: String
        let outputPath: String
    }

    /// Registers a `-P <file>` progress file that the next `beginRun` will
    /// poll. Called by the run builders as they compose the command, so
    /// the status bar's bar and the terminal's ASCII bar read the same
    /// bytes. A comparison run registers one file per sub-solver.
    func registerProgressFile(_ path: String) {
        pendingProgressFiles.append(path)
        // A run that is composed and then abandoned (a missing binary, a
        // cancelled panel) leaves its path behind; the file never exists,
        // so the poller skips it, but keep the list bounded anyway.
        if pendingProgressFiles.count > 8 {
            pendingProgressFiles.removeFirst(pendingProgressFiles.count - 8)
        }
    }

    /// Marks a scripted run as active and returns the identity and paths the
    /// generated script must use. Qnet deliberately runs one solver job at a
    /// time because all jobs share the same interactive shell. A second
    /// launch is explicitly refused instead of replacing the active run's
    /// poller and coordination files.
    ///
    /// The reporter is captured from the originating editor. It remains the
    /// destination for diagnostics and Stop messages after a tab switch.
    func beginRun(
        label: String,
        ownerID: UUID,
        ownerTitle: String,
        report: @escaping @MainActor (String, StatusSeverity) -> Void
    ) -> RunHandle? {
        let display = Self.displayLabel(forRunLabel: label)
        if let activeRun {
            pendingProgressFiles = []
            report(
                "\(display) was not started because \(activeRun) is already running for “\(activeRunOwnerTitle ?? "another tab")”. Stop or wait for that run first.",
                .warning
            )
            return nil
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let id = UUID()
        let token = id.uuidString.lowercased()
        let dir = FileManager.default.temporaryDirectory
        let donePath = dir.appendingPathComponent("BNET_run_done_\(pid)_\(token).txt").path
        let pidPath = dir.appendingPathComponent("BNET_run_pid_\(pid)_\(token).txt").path
        let statusPath = dir.appendingPathComponent("BNET_run_status_\(pid)_\(token).log").path
        let outputPath = dir.appendingPathComponent("BNET_run_output_\(pid)_\(token).log").path

        runPollTask?.cancel()
        cancelRetryTask?.cancel()
        cancelRetryTask = nil
        activeRunID = id
        activeRun = display
        activeRunOwnerID = ownerID
        activeRunOwnerTitle = ownerTitle
        activeRunReporter = report
        lastStatusReporter = report
        runStartedAt = Date()
        runElapsed = 0
        runProgress = nil
        canCancelRun = false
        cancelRequestedAt = nil
        cancelEscalated = false
        cancelKilled = false
        activeRunGroup = nil
        runDonePath = donePath
        runOutputPath = outputPath
        runPIDPath = pidPath
        runStatusPath = statusPath
        runStatusConsumedBytes = 0
        runStatusRemainder = ""
        activeProgressFiles = pendingProgressFiles
        pendingProgressFiles = []

        runPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.activeRunID == id else { return }
                self.drainActiveStatusInbox(runID: id)
                if let contents = try? String(contentsOfFile: donePath, encoding: .utf8) {
                    let code = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
                    // The completion file means the WRAPPER has exited, and
                    // after Stop the wrapper is the first thing to die. If
                    // the job's process group still has members, the work
                    // the user asked to stop is still running: keep the run
                    // owned so `tickRun` can escalate to SIGTERM/SIGKILL.
                    if self.cancelSurvivorsOutstanding() {
                        self.tickRun(runID: id)
                        continue
                    }
                    self.finishRun(runID: id, label: display, exitCode: code)
                    return
                }
                if !self.isShellRunning {
                    self.finishRun(runID: id, label: display, exitCode: -1)
                    return
                }
                self.tickRun(runID: id)
            }
        }
        return RunHandle(
            id: id,
            donePath: donePath,
            pidPath: pidPath,
            statusPath: statusPath,
            outputPath: outputPath
        )
    }

    /// Retires a run whose wrapper could not be written. Without this path
    /// the status indicator would wait forever for a completion file that no
    /// process could create.
    func failRunToLaunch(_ handle: RunHandle, message: String) {
        guard activeRunID == handle.id, let label = activeRun else { return }
        activeRunReporter?(message, .error)
        finishRun(runID: handle.id, label: label, exitCode: -1)
    }

    /// One poll tick of a live run: elapsed clock, determinate progress,
    /// whether the script has reported a pid, and — after Stop — the
    /// escalation and the deadline that guarantee the run finishes.
    private func tickRun(runID: UUID) {
        guard activeRunID == runID else { return }
        if let started = runStartedAt {
            runElapsed = Date().timeIntervalSince(started)
        }
        if !canCancelRun, cancelRequestedAt == nil, activeRunPID != nil {
            canCancelRun = true
        }
        // Record the job's process group as soon as the wrapper reports its
        // pid, i.e. long before Stop can be pressed. Once the wrapper dies
        // the group can no longer be derived, and the escalation below is
        // the only thing that reaches the solver.
        captureActiveRunGroup()
        if let requested = cancelRequestedAt, let label = activeRun {
            let waited = Date().timeIntervalSince(requested)
            if !cancelEscalated, waited >= Self.cancelEscalateAfter {
                cancelEscalated = true
                signalActiveRun(SIGTERM)
            }
            if waited >= Self.cancelDeadline, let pid = activeRunPID {
                // "Still running" is the GROUP, not just the wrapper. The
                // wrapper dies on the first SIGINT; the solver it launched
                // as a background job ignores SIGINT and survives in the
                // same group, reparented to init. Judging by the wrapper
                // alone retires the run — and cancels the escalation — with
                // the solver still pinning every core.
                if Self.processExists(pid) || activeRunGroupIsAlive() {
                    if !cancelKilled {
                        cancelKilled = true
                        signalActiveRun(SIGKILL)
                    }
                    // SIGKILL is the last thing there is to send. If the
                    // group outlives it, stop owning the run rather than
                    // blocking every future launch.
                    if waited >= Self.cancelAbandonAfter {
                        finishRun(
                            runID: runID,
                            label: label,
                            exitCode: TerminalRunSummary.cancelledExitCode
                        )
                        return
                    }
                } else {
                    // SIGKILL cannot run the wrapper's EXIT trap. Retire the
                    // job only after the recorded process is demonstrably
                    // gone; until then single-flight ownership stays intact.
                    finishRun(
                        runID: runID,
                        label: label,
                        exitCode: TerminalRunSummary.cancelledExitCode
                    )
                    return
                }
            }
        }
        let fraction = Self.progressFraction(in: activeProgressFiles)
        if runProgress != fraction { runProgress = fraction }
    }

    /// Routes all stderr records to the editor captured by `beginRun`, not
    /// the editor that happens to be active when this polling tick fires.
    private func drainActiveStatusInbox(runID: UUID, includePartialRecord: Bool = false) {
        guard activeRunID == runID,
              let path = runStatusPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count >= runStatusConsumedBytes else {
            return
        }

        let unread = data.dropFirst(runStatusConsumedBytes)
        guard let newText = String(data: unread, encoding: .utf8) else {
            // The read may have landed in the middle of a multi-byte scalar;
            // leave the cursor unchanged and retry once more bytes arrive.
            return
        }
        runStatusConsumedBytes = data.count
        let contents = runStatusRemainder + newText

        let records = contents.components(separatedBy: "<<<END>>>")
        let completed = records.dropLast()
        for record in completed {
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            for line in trimmed.split(separator: "\n", omittingEmptySubsequences: true) {
                let text = String(line)
                activeRunReporter?(text, StatusEntry.solverLineSeverity(text))
            }
        }
        let trailing = records.last ?? ""
        if includePartialRecord {
            let trimmed = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                for line in trimmed.split(separator: "\n", omittingEmptySubsequences: true) {
                    let text = String(line)
                    activeRunReporter?(text, StatusEntry.solverLineSeverity(text))
                }
            }
            runStatusRemainder = ""
        } else {
            // A brace-group appends the record with several writes. Preserve
            // any bytes after the last sentinel in memory so polling cannot
            // consume a record while the shell is still producing it.
            runStatusRemainder = trailing
        }
    }

    /// Reads the first progress file that currently exists. The C solvers
    /// write `<total>\n` and then one `.` per completed unit (see the
    /// `-P` contract in CLAUDE.md), so the fraction is
    /// (bytes − header) / total. Returns nil when no file has a usable
    /// header yet — the caller then keeps the indeterminate spinner.
    private static func progressFraction(in paths: [String]) -> Double? {
        let fm = FileManager.default
        for path in paths {
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            guard let head = try? handle.read(upToCount: 24), !head.isEmpty,
                  let text = String(data: head, encoding: .utf8),
                  let newline = text.firstIndex(of: "\n") else { continue }
            let headerText = String(text[text.startIndex..<newline])
            guard let total = Int(headerText), total > 0 else { continue }
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
            guard let size else { continue }
            let done = max(0, size - (headerText.utf8.count + 1))
            return min(1, Double(done) / Double(total))
        }
        return nil
    }

    /// The pid of the running script, as reported by the generated bash
    /// wrapper. Nil before the wrapper has written it (or when the run
    /// was started some other way).
    private var activeRunPID: pid_t? {
        guard let runPIDPath,
              let text = try? String(contentsOfFile: runPIDPath, encoding: .utf8),
              let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 1 else { return nil }
        return value
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Records the running job's process group the first time the wrapper's
    /// pid is readable, and returns it thereafter.
    ///
    /// Refuses two groups outright, because signalling either of them takes
    /// something down that is not the run: our own group (that is the app),
    /// and the interactive shell's group (that is every future run, plus
    /// the user's scrollback). An interactive bash puts each foreground job
    /// in a group of its own, so the wrapper's group is neither.
    @discardableResult
    private func captureActiveRunGroup() -> pid_t? {
        if let activeRunGroup { return activeRunGroup }
        guard let pid = activeRunPID else { return nil }
        let group = getpgid(pid)
        guard group > 1, group != getpgrp() else { return nil }
        if let shell = terminalView?.process?.shellPid, shell > 1 {
            guard group != shell, group != getpgid(shell) else { return nil }
        }
        activeRunGroup = group
        return group
    }

    /// True while ANY process still exists in the run's recorded group —
    /// the solver and the wrapper's helper subshells included, whether or
    /// not the wrapper itself is still alive.
    private func activeRunGroupIsAlive() -> Bool {
        guard let group = activeRunGroup else { return false }
        if kill(-group, 0) == 0 { return true }
        return errno == EPERM
    }

    /// True while Stop has been pressed and work it was meant to stop is
    /// demonstrably still running, even though the wrapper the app tracks
    /// has already exited.
    ///
    /// The completion file is written by the wrapper's EXIT trap, and the
    /// wrapper dies on the very first SIGINT — so believing the completion
    /// file is exactly how a cancelled run used to be reported finished
    /// while the solver kept ~18 cores pinned with no way to stop it from
    /// the GUI. While this is true the run stays owned and `tickRun` keeps
    /// escalating.
    private func cancelSurvivorsOutstanding() -> Bool {
        guard let requested = cancelRequestedAt else { return false }
        guard Date().timeIntervalSince(requested) < Self.cancelAbandonAfter else { return false }
        return activeRunGroupIsAlive()
    }

    /// Interrupts the running script the way ⌃C in the shell would:
    /// SIGINT to the script's process group (an interactive bash puts a
    /// foreground job in its own group, so the shell itself survives),
    /// falling back to the script's own pid.
    ///
    /// Stop is enabled the moment a run starts, so the pid file may not
    /// exist yet: the wrapper writes it on its first line, but the shell
    /// needs a few hundred milliseconds to get there. Rather than doing
    /// nothing (the old behaviour left ⌘. dead for the first poll
    /// interval), the pid is re-read every 100 ms for up to a second and
    /// the signal is sent as soon as it appears. `report` receives the
    /// status-log line for whatever happened — "<label> cancelled." or,
    /// after a second with no pid, a warning — so the pane and the menu
    /// bar log the same words. Returns the label of the run being
    /// stopped, or nil when nothing was running.
    @discardableResult
    func cancelActiveRun(
        report: @escaping @MainActor (String, StatusSeverity) -> Void
    ) -> String? {
        guard let label = activeRun, let runID = activeRunID else { return nil }
        // Prefer the originating editor captured at launch. The supplied
        // reporter is only a fallback for legacy/non-document callers.
        let destination = activeRunReporter ?? report
        if signalActiveRun(SIGINT) {
            noteCancelRequested()
            destination("\(label) cancelled.", .warning)
            return label
        }
        cancelRetryTask?.cancel()
        cancelRetryTask = Task { @MainActor [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled, self.activeRunID == runID else { return }
                if self.signalActiveRun(SIGINT) {
                    self.noteCancelRequested()
                    destination("\(label) cancelled.", .warning)
                    return
                }
            }
            guard let self, self.activeRunID == runID else { return }
            // No pid after a second: the wrapper has not started (the
            // shell is busy with something typed by hand, or exited). Say
            // so rather than leaving the click unanswered, and let the
            // deadline retire the indicator.
            self.noteCancelRequested()
            destination("Nothing to interrupt yet — \(label) has not started in the Shell.", .warning)
        }
        return label
    }

    /// Sends `signal` to the running script's process group (or pid).
    /// Returns false when the wrapper has not reported a pid yet.
    ///
    /// The group comes from `captureActiveRunGroup()`, which recorded it
    /// while the wrapper was alive, so SIGTERM and SIGKILL still reach the
    /// solver after the SIGINT has killed the wrapper out from under them.
    @discardableResult
    private func signalActiveRun(_ signal: Int32) -> Bool {
        guard let pid = activeRunPID else { return false }
        if let group = captureActiveRunGroup() {
            kill(-group, signal)
        } else {
            // No usable group (the wrapper died before we could read one,
            // or it shares a group we refuse to signal): the tracked pid
            // is all there is.
            kill(pid, signal)
        }
        return true
    }

    private func noteCancelRequested() {
        if cancelRequestedAt == nil { cancelRequestedAt = Date() }
        canCancelRun = false
    }

    private func finishRun(runID: UUID, label: String, exitCode: Int32) {
        guard activeRunID == runID,
              let ownerID = activeRunOwnerID,
              let ownerTitle = activeRunOwnerTitle else { return }
        // A diagnostic record may have landed between the poller's first
        // drain and its completion-file read. Consume it before releasing
        // the run's owner reporter and deleting the inbox.
        drainActiveStatusInbox(runID: runID, includePartialRecord: true)
        let elapsed = runStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if let runOutputPath {
            lastRunOutput = try? String(contentsOfFile: runOutputPath, encoding: .utf8)
        } else {
            lastRunOutput = nil
        }
        lastRunSummary = TerminalRunSummary(
            id: runID,
            label: label,
            ownerID: ownerID,
            ownerTitle: ownerTitle,
            exitCode: exitCode,
            elapsed: elapsed,
            finishedAt: Date(),
            userStopped: cancelRequestedAt != nil
        )
        runPollTask?.cancel()
        runPollTask = nil
        activeRunID = nil
        activeRun = nil
        activeRunOwnerID = nil
        activeRunOwnerTitle = nil
        runStartedAt = nil
        runProgress = nil
        runElapsed = 0
        canCancelRun = false
        cancelRequestedAt = nil
        cancelEscalated = false
        cancelKilled = false
        activeRunGroup = nil
        cancelRetryTask?.cancel()
        cancelRetryTask = nil
        if let runDonePath { try? FileManager.default.removeItem(atPath: runDonePath) }
        runDonePath = nil
        if let runOutputPath { try? FileManager.default.removeItem(atPath: runOutputPath) }
        runOutputPath = nil
        if let runPIDPath { try? FileManager.default.removeItem(atPath: runPIDPath) }
        runPIDPath = nil
        if let runStatusPath { try? FileManager.default.removeItem(atPath: runStatusPath) }
        runStatusPath = nil
        runStatusConsumedBytes = 0
        runStatusRemainder = ""
        // The wrapper removes its progress file on a normal exit; a run
        // that was interrupted mid-bar leaves it behind. Nothing reads it
        // once the run is over, so remove whatever is still there.
        for path in activeProgressFiles {
            try? FileManager.default.removeItem(atPath: path)
        }
        activeProgressFiles = []
        activeRunReporter = nil
    }

    // MARK: - Raw byte capture

    /// Append a slice of raw bytes from the child shell to the in-memory
    /// capture buffer. Called from `ScrollForwardingTerminalView.dataReceived`
    /// before SwiftTerm parses the bytes for display, so we record exactly
    /// what the shell emitted (escape sequences, color codes, the bytes
    /// produced by interactive commands like `ls -la`, vim, less, etc.).
    /// Trims back to `maxCapturedBytes` once the buffer hits 2× that, so
    /// memory stays bounded across long sessions.
    func appendCapturedBytes(_ slice: ArraySlice<UInt8>) {
        capturedBytes.append(contentsOf: slice)
        let cap = Self.maxCapturedBytes
        if capturedBytes.count > cap * 2 {
            capturedBytes.removeFirst(capturedBytes.count - cap)
        }
    }

    /// Move any bytes the pty reader has staged in `pendingBytes` into
    /// the main-actor `capturedBytes` array. Always called from the
    /// main actor before snapshotting so the persisted blob includes
    /// bytes that arrived after the most recent layout/render tick.
    private func drainPendingBytes() {
        let drained = pendingBytes.drain()
        if !drained.isEmpty {
            appendCapturedBytes(drained[...])
        }
    }

    /// Seconds of pty silence required before the shell counts as idle.
    /// Short enough that clicking Run right after a command finishes is not
    /// refused, long enough to catch a solver, a build, or `yes` mid-flight.
    static let idleOutputWindow: TimeInterval = 0.15

    /// Control sequence sent ahead of every scripted command: ⌃E (end of
    /// line) then ⌃U (discard the line). Both readline (emacs *and* vi
    /// insert keymaps) and zle bind ⌃U to "kill the line", so a command the
    /// user half-typed and never ran is discarded instead of being
    /// concatenated into `echo helbash /tmp/BNET_run_….sh`. At an empty
    /// prompt the pair is a no-op.
    private static let killLine: [UInt8] = [0x05, 0x15]

    /// Types a command into the shell and presses Enter — or refuses to,
    /// and retires the run that was counting on it. Returns whether the
    /// command was typed.
    ///
    /// Every solver launch in Qnet is literally typed into the user's
    /// interactive shell, so whatever the shell is doing becomes part of the
    /// launch. Two things go wrong, and they need different answers:
    ///
    ///   • A half-typed line at the prompt would be concatenated —
    ///     `echo hel` + `bash /tmp/BNET_run_….sh`. The ⌃E ⌃U prefix
    ///     discards it, which fixes that case outright rather than refusing
    ///     a run the user meant.
    ///   • A program that owns the shell (vim, less, `cat`, a `read` in a
    ///     script) would receive the command as *input*: text inserted into
    ///     a file, or a mangled line the wrapper's own
    ///     `printf '\033[A\033[2K'` then erases a line of the user's output
    ///     with. Nothing recovers from that, so it is refused.
    ///
    /// The refusal cannot be silent. `beginRun` has already registered the
    /// run and started a poller waiting for a completion file that no
    /// process will now write, so the status bar would tick "Running…" for
    /// the rest of the session. Retiring the run here also publishes the
    /// `lastRunSummary` that closes the run's Results record.
    @discardableResult
    func sendCommand(_ command: String) -> Bool {
        // The blocker is asked FIRST, before `terminalView` is unwrapped.
        // `commandBlocker`'s own first answer is `.shellUnavailable`, which
        // is exactly the nil-view case: the Shell pane has never been shown
        // this launch (it starts hidden, and a maximized sibling pane keeps
        // it that way), so there is no terminal to type into. Unwrapping
        // first would return false with no report at all, and the user would
        // see nothing until the run poller retired the run half a second
        // later as "failed (exit -1)" with no cause. `refuseCommand` needs
        // no terminal — only `activeRunID` / `activeRun`, both set by
        // `beginRun` before we are called.
        if let blocker = commandBlocker {
            refuseCommand(blocker)
            return false
        }
        guard let tv = terminalView else { return false }
        var bytes = Self.killLine
        bytes.append(contentsOf: Array((command + "\n").utf8))
        tv.send(source: tv, data: bytes[...])
        return true
    }

    /// Reports a refused launch to the tab that asked for it and retires the
    /// run. Beeps like the "a run is already active" refusal in `beginRun`,
    /// so the two read as one behaviour.
    ///
    /// The no-run path is the one that has to work without any of the run
    /// bookkeeping: a caller that sends a command outside `beginRun` has no
    /// status bar to correct and no Results record to close, but it must
    /// still not get a bare beep and no words. `lastStatusReporter` is the
    /// sink of the most recent run — the shell is shared by every tab, so
    /// the tab that last used it is the best available guess at the one the
    /// user is looking at — and it survives `finishRun` for precisely this.
    private func refuseCommand(_ blocker: ShellCommandBlocker) {
        NSSound.beep()
        guard let runID = activeRunID, let label = activeRun else {
            lastStatusReporter?("The command was not sent to the Shell. \(blocker.message)", .error)
            return
        }
        activeRunReporter?("\(label) was not started. \(blocker.message)", .error)
        finishRun(runID: runID, label: label, exitCode: -1)
    }

    /// Why the shell cannot be typed into right now, or nil when it is at a
    /// prompt and idle.
    ///
    /// Deliberately biased toward launching: every signal here has to be
    /// positive evidence that something else owns the shell, because a false
    /// positive blocks a legitimate run and the user has no way to argue
    /// with it. `beginRun` already prevents a second Qnet run; this answers
    /// the other question, which is what the *user* has running.
    var commandBlocker: ShellCommandBlocker? {
        guard let tv = terminalView else { return .shellUnavailable }
        guard isShellRunning else { return .shellNotRunning }

        // (a) Alt-screen or mouse reporting: vim, less, htop, a TUI. Typing
        // a command into one of those inserts text into a file or scrambles
        // its display; there is no salvaging it afterwards.
        // SwiftTerm's own flag is the display truth; the meter's latch is
        // read as well because it is set from the pty reader the moment the
        // bytes arrive, which is ahead of SwiftTerm having parsed them.
        let terminal = tv.getTerminal()
        if terminal.isCurrentBufferAlternate || lineMeter.isAlternateScreen {
            return .fullScreenProgram
        }
        if terminal.mouseMode != .off { return .fullScreenProgram }

        // (b) Bytes still arriving. Something is printing, so the shell is
        // not at a prompt (or the user is mid-keystroke).
        if lineMeter.secondsSinceLastOutput < Self.idleOutputWindow { return .busy }

        // (c) No prompt on the cursor row. A shell prompt always leaves at
        // least one visible glyph to the left of the cursor; a program
        // reading stdin (`cat`, a bare `python`, a script's `read`) leaves
        // the cursor in column 0 of a blank row. Only trustworthy while the
        // viewport is at the bottom, because `getCharData(col:row:)` indexes
        // the visible rows and the cursor row is off screen when the user
        // has scrolled up — in which case we say nothing and let the run go.
        if !tv.canScroll || tv.scrollPosition > 0.999 {
            let row = terminal.buffer.y
            let cursorColumn = terminal.buffer.x
            var sawGlyph = false
            for column in 0..<max(0, cursorColumn) {
                guard let cell = terminal.getCharData(col: column, row: row) else { continue }
                let character = cell.getCharacter()
                if character != " " && character != "\0" {
                    sawGlyph = true
                    break
                }
            }
            if !sawGlyph { return .busy }
        }

        return nil
    }

    // MARK: - Font controls

    /// Bumps the terminal font size up by one point (clamped at maxFontSize),
    /// persists it, and rebuilds `minTerminalWidth` so the horizontal
    /// scrollbar re-engages if the content no longer fits at the new size.
    func increaseFontSize() {
        setFontSize(min(fontSize + 1, Self.maxFontSize))
    }

    /// Bumps the terminal font size down by one point (clamped at
    /// minFontSize), persists it, and rebuilds `minTerminalWidth` so the
    /// scrollbar retracts if the content now fits.
    func decreaseFontSize() {
        setFontSize(max(fontSize - 1, Self.minFontSize))
    }

    /// Sets the terminal font size directly (used by SettingsView / external
    /// sync) with clamping, persistence, and scroller refresh.
    func setFontSize(_ newSize: CGFloat) {
        let clamped = min(max(newSize, Self.minFontSize), Self.maxFontSize)
        guard abs(clamped - fontSize) > 0.001 else { return }
        fontSize = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.fontSizeKey)
        recomputeMinTerminalWidth()
    }

    /// Sets the font family name. Empty string → system monospaced default.
    /// Persists and rebuilds `minTerminalWidth` so existing text gets
    /// re-rendered at the new advance width.
    func setFontName(_ name: String) {
        guard name != fontName else { return }
        fontName = name
        UserDefaults.standard.set(name, forKey: Self.fontNameKey)
        recomputeMinTerminalWidth()
    }

    // MARK: - Line length tracking

    /// Records that content with the given longest-line character count is
    /// about to be printed. Tracks a monotonic peak (reset on clear/restart)
    /// and recomputes `minTerminalWidth` from that peak and the current font.
    func reportLongestLineChars(_ chars: Int) {
        if chars > longestLineChars {
            longestLineChars = chars
            recomputeMinTerminalWidth()
        }
    }

    /// Converts the longest known line (in characters) to a pixel width
    /// using the actual advance of the currently-selected font (samples the
    /// width of "M" so we account for proportional fonts too). Adds a 40 pt
    /// margin for SwiftTerm's internal padding and the external scroller.
    func recomputeMinTerminalWidth() {
        guard longestLineChars > 0 else {
            minTerminalWidth = 0
            return
        }
        let font = resolvedFont()
        let sampleWidth = NSString(string: "MMMMMMMMMM")
            .size(withAttributes: [.font: font]).width / 10
        let charWidth = sampleWidth > 0 ? sampleWidth : fontSize * 0.62
        minTerminalWidth = CGFloat(longestLineChars) * charWidth + 40
    }

    // MARK: - Transcript persistence

    /// Snapshot the captured byte stream to UserDefaults. Called at
    /// quit time and from the periodic save backstop so the next launch
    /// can replay the same scrollback. No-op when nothing has been
    /// captured yet. Trims to the most recent `maxCapturedBytes` so the
    /// UserDefaults blob stays bounded.
    ///
    /// Unlike the previous text-based approach (which read SwiftTerm's
    /// rendered buffer via `getBufferAsData`), this writes the exact
    /// bytes the shell process emitted. That preserves color codes,
    /// cursor moves, and the output of interactive commands that the
    /// rendered-buffer reader would have stripped or truncated.
    func saveTranscript() {
        // Pull in anything the pty reader has staged on the background
        // thread first. Without this, bytes that arrived between the
        // last main-actor tick and `applicationShouldTerminate` would
        // be left behind — exactly the "last few lines missing on
        // relaunch" symptom the user was seeing.
        drainPendingBytes()

        guard !capturedBytes.isEmpty else {
            // Nothing was captured this session — leave the existing
            // saved blob alone so a fresh launch immediately followed
            // by ⌘Q doesn't wipe the previous session's transcript.
            return
        }
        let cap = Self.maxCapturedBytes
        let bytes: [UInt8] = capturedBytes.count > cap
            ? Array(capturedBytes.suffix(cap))
            : capturedBytes
        let data = Data(bytes)
        UserDefaults.standard.set(data, forKey: Self.savedRawBytesKey)
        // Drop the legacy text key on first successful raw save —
        // future launches read the raw blob, so the legacy entry is
        // dead weight.
        UserDefaults.standard.removeObject(forKey: Self.savedTranscriptKey)
        // Force the buffered defaults write to disk before the process
        // exits. Without this, a quit-time save can be lost if the
        // runloop tears down before the periodic UserDefaults flush.
        UserDefaults.standard.synchronize()
    }

    /// Returns the previously-saved raw byte transcript, or nil if
    /// none exists. Preferred over `loadSavedTranscript` — used by the
    /// terminal view to feed the previous session via
    /// `tv.feed(byteArray:)`.
    static func loadSavedRawBytes() -> Data? {
        guard let data = UserDefaults.standard.data(forKey: savedRawBytesKey),
              !data.isEmpty else { return nil }
        return data
    }

    /// Legacy text-format loader — used as a one-shot migration path
    /// when the raw-bytes blob is absent but the user has a saved
    /// transcript from a build that pre-dates raw capture. Returns nil
    /// after the first save under the new format clears the old key.
    static func loadSavedTranscript() -> String? {
        let s = UserDefaults.standard.string(forKey: savedTranscriptKey)
        return (s?.isEmpty == false) ? s : nil
    }

    static func clearSavedTranscript() {
        UserDefaults.standard.removeObject(forKey: savedRawBytesKey)
        UserDefaults.standard.removeObject(forKey: savedTranscriptKey)
    }

    /// Builds the NSFont corresponding to the current `fontName` / `fontSize`.
    /// Falls back to the system monospaced font if the family lookup fails
    /// (e.g. user picked a font and then uninstalled it).
    func resolvedFont() -> NSFont {
        if !fontName.isEmpty {
            let descriptor = NSFontDescriptor(fontAttributes: [.family: fontName])
            if let font = NSFont(descriptor: descriptor, size: fontSize) {
                return font
            }
            if let font = NSFont(name: fontName, size: fontSize) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
}
