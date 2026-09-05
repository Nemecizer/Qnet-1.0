import SwiftUI
import AppKit
@preconcurrency import SwiftTerm

/// LocalProcessTerminalView subclass that forwards SwiftTerm's `scrolled`
/// callback (fired when the user wheels/pages through the scrollback
/// buffer) to a closure, so we can keep the external vertical NSScroller
/// in sync with the terminal's own scroll state. Also intercepts the
/// raw byte stream from the child shell (`dataReceived`) so the bytes
/// can be persisted verbatim and replayed on the next launch, and hands
/// horizontal wheel deltas to the host so wide output can be panned
/// with a trackpad.
final class ScrollForwardingTerminalView: LocalProcessTerminalView {
    @MainActor var onScrollPositionChanged: ((Double) -> Void)?
    /// Invoked synchronously for every chunk of bytes the child shell
    /// emits, before SwiftTerm parses them. Wired to
    /// `TerminalModel.appendCapturedBytes` so the model accumulates
    /// the exact byte stream (escape sequences and all) for
    /// replay-on-next-launch. Runs on whatever thread SwiftTerm
    /// happens to deliver bytes from; the closure must hop to the
    /// main actor itself if it touches main-actor state.
    var onBytesReceived: ((ArraySlice<UInt8>) -> Void)?
    /// Fired by SwiftTerm whenever the selection turns on or off, and while
    /// a drag extends it. Edit ▸ Copy's enablement follows this: SwiftTerm's
    /// view is an NSView, not an NSText, so the responder-chain test the
    /// other clipboard commands use cannot see a shell selection.
    @MainActor var onSelectionChanged: (() -> Void)?
    /// Builds the right-click menu for the terminal. Supplied by
    /// `TerminalHostView`, which is the object that holds the model.
    @MainActor var contextMenuProvider: (() -> NSMenu?)?

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        Task { @MainActor in onScrollPositionChanged?(position) }
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onBytesReceived?(slice)
        super.dataReceived(slice: slice)
    }

    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        onSelectionChanged?()
    }

    /// Right-click over the terminal. Copy / Paste / Select All / Find /
    /// Clear are the five things anyone tries first in Terminal.app, and
    /// until now every one of them lived only in the pane header or behind a
    /// menu path the user had to learn.
    override func menu(for event: NSEvent) -> NSMenu? {
        // A program that turned mouse reporting on (htop, vim, a pager with
        // -R) wants the raw button-3 event, not a context menu of ours. It
        // gets nothing rather than the wrong thing.
        if getTerminal().mouseMode != .off { return nil }
        return contextMenuProvider?()
    }
}

// MARK: - Host view

/// AppKit container that owns the SwiftTerm view, the overlay
/// scrollers and the theme. `TerminalModel.hostView` caches one of
/// these for the lifetime of the shell process so SwiftUI can freely
/// drop and re-create the `SwiftTermView` representable (pane collapse,
/// AI-pane toggle) and simply re-parent it — the shell PID and the
/// scrollback are untouched.
@MainActor
final class TerminalHostView: NSView, @preconcurrency LocalProcessTerminalViewDelegate {
    private weak var model: TerminalModel?
    private(set) var terminalView: ScrollForwardingTerminalView!
    private let clipView = NSView(frame: .zero)
    private let vScroller: NSScroller
    private let hScroller: NSScroller

    var desiredMinWidth: CGFloat = 0
    private(set) var hOffset: CGFloat = 0
    private(set) var classicTheme = false
    private var hideScrollersWork: DispatchWorkItem?
    private var scrollerHovered = false
    private var clipObservation: NSObjectProtocol?
    /// Local monitor that turns predominantly-horizontal wheel/trackpad
    /// deltas over the terminal into horizontal panning (SwiftTerm's own
    /// `scrollWheel` is not overridable and only scrolls vertically).
    nonisolated(unsafe) private var wheelMonitor: Any?
    /// SwiftTerm's find bar, once `adoptFindBar()` has re-anchored it onto
    /// the pane's visible rectangle. Weak because SwiftTerm owns it and it
    /// stays a subview of the terminal view; these are the three constraints
    /// we substituted for the vendored ones, kept so `layoutTerminal()` can
    /// slide the bar back over the visible area after a pan or a resize.
    private weak var findBar: NSView?
    private var findBarTrailing: NSLayoutConstraint?
    private var findBarLeading: NSLayoutConstraint?

    private static let overlayScrollerWidth: CGFloat =
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)

    init(model: TerminalModel, workingDirectory: URL, classicTheme: Bool) {
        self.model = model
        self.classicTheme = classicTheme
        vScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: Self.overlayScrollerWidth, height: 100))
        hScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 100, height: Self.overlayScrollerWidth))
        super.init(frame: .zero)
        wantsLayer = true
        buildTerminal(model: model, workingDirectory: workingDirectory)
        buildChrome()
        applyTheme(classic: classicTheme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
    }

    // MARK: Terminal

    private func buildTerminal(model: TerminalModel, workingDirectory: URL) {
        let tv = ScrollForwardingTerminalView(frame: .zero)
        terminalView = tv
        tv.font = model.resolvedFont()
        tv.getTerminal().setCursorStyle(.blinkBlock)
        // Bump scrollback from SwiftTerm's default of 500 lines to 5000.
        // The persisted shell transcript is read out of this buffer at
        // quit, so a small scrollback throws away older session history
        // that would otherwise be restored on the next launch.
        tv.getTerminal().changeHistorySize(5000)
        tv.processDelegate = self

        // SwiftTerm calls `scrolled(source:position:)` when the user wheels
        // through scrollback or when new output pushes the viewport. Forward
        // so the external vertical scroller tracks it (and flashes).
        tv.onScrollPositionChanged = { [weak self] _ in
            self?.syncVerticalScroller()
            self?.revealScrollers()
        }

        // Capture every byte the child shell emits so we can replay
        // the exact stream (escape sequences and all) on the next
        // launch. SwiftTerm's pty reader can deliver bytes from a
        // background thread; write straight into the lock-protected
        // pending buffer instead of hopping to the main actor. A queued
        // `Task { @MainActor }` would not run when the user quits
        // immediately after a command, dropping the last lines of
        // output. The main-actor `saveTranscript` drains this buffer
        // before snapshotting, so the persisted blob always reflects
        // the latest bytes.
        //
        // The same callback measures the line the shell is printing. It has
        // to happen here, on the reader, and not in the main-actor drain:
        // `saveTranscript` drains `pendingBytes` on a 10 s backstop, and a
        // comparison table that only becomes scrollable ten seconds after it
        // was printed has already been read and mis-read. `scan` allocates
        // nothing and answers non-nil only when the widest line has actually
        // grown — a handful of times per run — so the main-actor hop below
        // is rare, not per-chunk.
        tv.onBytesReceived = { [weak model] slice in
            guard let model else { return }
            model.pendingBytes.append(slice)
            if let widest = model.lineMeter.scan(slice) {
                Task { @MainActor [weak model] in
                    model?.reportLongestLineChars(widest)
                }
            }
        }

        tv.onSelectionChanged = { [weak model] in
            model?.noteSelectionChanged()
        }

        tv.contextMenuProvider = { [weak self] in
            self?.makeContextMenu()
        }

        // When the user clears the terminal, SwiftTerm resets its buffer
        // without firing scrolled(); re-run layoutTerminal() so both
        // scrollers (horizontal knob-size, vertical isEnabled) refresh.
        model.onAfterClear = { [weak self] in
            self?.layoutTerminal()
        }

        replaySavedTranscript(into: tv, model: model)

        // Start the shell
        let shell = Self.userShell()
        let shellIdiom = "-" + (shell as NSString).lastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["CLICOLOR"] = "1"
        env["CLICOLOR_FORCE"] = "1"
        env["LSCOLORS"] = "ExfxcxdxDxegedabagacad"
        // macOS's /etc/zshrc_Apple_Terminal and /etc/bashrc_Apple_Terminal
        // only run when TERM_PROGRAM is Apple_Terminal; they install a
        // precmd hook (update_terminal_cwd) that emits OSC 7 with the
        // shell's cwd on every prompt, which is what keeps the pane
        // header's "Current directory" honest after `cd`. Shell-session
        // persistence (~/.zsh_sessions) is switched off: Qnet keeps its
        // own transcript, and the feature also needs TERM_SESSION_ID.
        env["TERM_PROGRAM"] = "Apple_Terminal"
        env["SHELL_SESSIONS_DISABLE"] = "1"
        env.removeValue(forKey: "TERM_SESSION_ID")
        let envPairs = env.map { "\($0.key)=\($0.value)" }
        tv.startProcess(
            executable: shell,
            environment: envPairs,
            execName: shellIdiom,
            currentDirectory: workingDirectory.path
        )

        model.terminalView = tv
        model.sessionDirectoryDisplay = workingDirectory.path
        model.isShellRunning = true

        // VoiceOver: SwiftTerm's view is a custom NSView with no label.
        tv.setAccessibilityElement(true)
        tv.setAccessibilityRole(.textArea)
        tv.setAccessibilityLabel("Shell")
        tv.setAccessibilityHelp("Interactive shell. Solver runs print their output here.")

        // SwiftTerm installs its own right-edge NSScroller. Hide it — we
        // manage scrolling ourselves from the outside. (Deferred so SwiftTerm
        // has finished adding it as a subview.)
        DispatchQueue.main.async {
            for subview in tv.subviews where subview is NSScroller {
                subview.isHidden = true
            }
        }
    }

    /// Replay the saved transcript into SwiftTerm's buffer so the user
    /// can scroll up inside the shell window to see what was done
    /// before. Two things have to be right for this to survive shell
    /// startup:
    ///
    ///   1. Pre-size the terminal. SwiftUI hasn't laid the view out
    ///      yet, so bounds = .zero → cols clamped to MINIMUM_COLS=2
    ///      inside SwiftTerm's setupOptions. Feeding into a 2-cell-
    ///      wide buffer wraps every line every 2 chars, producing
    ///      an unrecoverable vertical stripe. We force a usable
    ///      size first; SwiftUI's first real layout will call
    ///      terminal.resize() afterwards and SwiftTerm's reflow
    ///      preserves content across that.
    ///
    ///   2. Land the cursor on the bottom row of an empty line
    ///      before the shell starts. zsh's PROMPT_SP feature (on by
    ///      default) emits ESC[J right before its first prompt,
    ///      which erases from the cursor to the end of the *visible*
    ///      viewport. With the cursor on the bottom row of visible,
    ///      that erase wipes only the bottom row (which is empty).
    ///      Anything above the cursor — including our separator and
    ///      the tail of the saved content visible above it — is
    ///      preserved. The trailing two CR/LFs ensure the cursor is
    ///      on a fresh empty bottom row when the shell takes over.
    ///
    /// Preferred path: replay the raw byte stream captured during
    /// the previous session. That round-trips escape sequences,
    /// colors, and the output of interactive commands like
    /// `ls -la` exactly as the user saw them. Falls back to the
    /// legacy text format on first launch after upgrading.
    private func replaySavedTranscript(into tv: ScrollForwardingTerminalView, model: TerminalModel) {
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        let separator = "\u{1B}[2m──── previous session above — new session \(now) ────\u{1B}[0m"

        if let savedBytes = TerminalModel.loadSavedRawBytes() {
            tv.getTerminal().resize(cols: 120, rows: 30)

            let bytes = Array(savedBytes)
            tv.feed(byteArray: bytes[...])

            // The captured stream may have ended mid-state (e.g. the
            // prior session was force-killed inside vim and never sent
            // the matching ESC[?1049l). Reset the modes most likely to
            // confuse a fresh shell so the separator below — and the
            // shell's own first prompt — render in a known-good state.
            //   ESC[?1049l → leave alt-screen if active
            //   ESC[?2004l → leave bracketed-paste mode if active
            //   ESC[?25h   → show cursor in case prior session hid it
            //   ESC[0m     → clear lingering color / attribute set
            let resetCodes = "\u{1B}[?1049l\u{1B}[?2004l\u{1B}[?25h\u{1B}[0m"
            tv.feed(text: resetCodes)
            let trailer = "\r\n\r\n" + separator + "\r\n\r\n"
            tv.feed(text: trailer)

            // Seed the capture buffer with everything we just replayed
            // so the next saveTranscript carries the prior session(s)
            // forward — otherwise a ⌘Q immediately after launch would
            // overwrite the persisted blob with just the new shell's
            // startup output, dropping all earlier history. Trim is
            // handled inside `appendCapturedBytes`.
            model.appendCapturedBytes(bytes[...])
            let trailingBytes = Array((resetCodes + trailer).utf8)
            model.appendCapturedBytes(trailingBytes[...])

            // Measure the replayed stream as well, so a wide table printed
            // in the previous session is still horizontally scrollable in
            // this one instead of silently truncated at the pane's width.
            // The trailer is scanned second because it carries the same
            // ESC[?1049l the terminal was just fed: that leaves the meter's
            // alt-screen latch matching the screen even when the previous
            // session was force-killed inside vim.
            let replayPeak = model.lineMeter.scan(bytes[...])
            let trailerPeak = model.lineMeter.scan(trailingBytes[...])
            if let widest = trailerPeak ?? replayPeak {
                model.reportLongestLineChars(widest)
            }
        } else if let saved = TerminalModel.loadSavedTranscript() {
            tv.getTerminal().resize(cols: 120, rows: 30)
            let crlfText = saved.replacingOccurrences(of: "\n", with: "\r\n")
            let payload = crlfText + "\r\n\r\n" + separator + "\r\n\r\n"
            tv.feed(text: payload)
            // Same seeding rationale as the raw-bytes branch above —
            // ensure the migrated text history survives the first save
            // in the new format.
            let payloadBytes = Array(payload.utf8)
            model.appendCapturedBytes(payloadBytes[...])
        }
    }

    // MARK: Chrome (clip view + overlay scrollers)

    private func buildChrome() {
        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        clipView.addSubview(terminalView)

        for (scroller, isVertical) in [(vScroller, true), (hScroller, false)] {
            scroller.scrollerStyle = .overlay
            scroller.knobProportion = 1.0
            scroller.doubleValue = 0
            scroller.isEnabled = false
            scroller.alphaValue = 0
            scroller.target = self
            scroller.action = isVertical
                ? #selector(vScrollerChanged(_:))
                : #selector(hScrollerChanged(_:))
            scroller.translatesAutoresizingMaskIntoConstraints = false
            scroller.setAccessibilityLabel(isVertical ? "Shell vertical scroll bar" : "Shell horizontal scroll bar")
        }
        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Shell pane")

        addSubview(clipView)
        addSubview(vScroller)
        addSubview(hScroller)

        let w = Self.overlayScrollerWidth
        NSLayoutConstraint.activate([
            clipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipView.topAnchor.constraint(equalTo: topAnchor),
            clipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            clipView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Overlay scrollers float over the content edges.
            vScroller.topAnchor.constraint(equalTo: topAnchor),
            vScroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            vScroller.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -w),
            vScroller.widthAnchor.constraint(equalToConstant: w),

            hScroller.leadingAnchor.constraint(equalTo: leadingAnchor),
            hScroller.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -w),
            hScroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            hScroller.heightAnchor.constraint(equalToConstant: w),
        ])

        // Terminal inside clip view. Width / X-offset are updated in
        // layoutTerminal().
        terminalView.translatesAutoresizingMaskIntoConstraints = true
        terminalView.autoresizingMask = []
        terminalView.frame = clipView.bounds

        clipView.postsFrameChangedNotifications = true
        clipObservation = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.layoutTerminal() }
        }

        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX * 10
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
            let windowNumber = event.windowNumber
            let locationInWindow = event.locationInWindow
            guard abs(dx) > abs(dy), dx != 0 else { return event }
            let handled: Bool = MainActor.assumeIsolated {
                guard let self, let window = self.window,
                      window.windowNumber == windowNumber,
                      self.desiredMinWidth > self.clipView.bounds.width else { return false }
                let local = self.clipView.convert(locationInWindow, from: nil)
                guard self.clipView.bounds.contains(local) else { return false }
                self.panHorizontally(by: -dx)
                return true
            }
            return handled ? nil : event
        }

        // Keep the scrollers visible while the pointer is over them.
        for scroller in [vScroller, hScroller] {
            scroller.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        scrollerHovered = true
        revealScrollers()
    }

    override func mouseExited(with event: NSEvent) {
        scrollerHovered = false
        scheduleScrollerHide()
    }

    /// Overlay scrollers fade in on activity and out ~1 s after the last
    /// scroll, matching NSScrollView's overlay behaviour. Both fades are
    /// DS.Motion durations, so they stop with Reduce Motion like every
    /// SwiftUI animation in the window.
    func revealScrollers() {
        hideScrollersWork?.cancel()
        DS.Motion.animateAppKit(DS.Motion.quickDuration) {
            if vScroller.isEnabled { vScroller.animator().alphaValue = 1 }
            if hScroller.isEnabled { hScroller.animator().alphaValue = 1 }
        }
        scheduleScrollerHide()
    }

    /// Idle time before the scrollers fade, as NSScrollView's overlay style.
    private static let scrollerHideDelay: TimeInterval = 1.0

    private func scheduleScrollerHide() {
        hideScrollersWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.scrollerHovered else { return }
            DS.Motion.animateAppKit(DS.Motion.standardDuration) {
                self.vScroller.animator().alphaValue = 0
                self.hScroller.animator().alphaValue = 0
            }
        }
        hideScrollersWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollerHideDelay, execute: work)
    }

    // MARK: Theme

    /// Applies either the semantic palette (text / textBackground /
    /// accent caret, follows light and dark) or the classic
    /// green-on-black look (`DS.Color.classicShell*`), and with it the
    /// 16-colour ANSI palette tuned for that ground — `ls` (CLICOLOR) and
    /// the solver banners print bright yellow, green and cyan, which
    /// SwiftTerm's default xterm set loses on a light ground. Re-run on
    /// appearance changes because SwiftTerm resolves the dynamic NSColors
    /// at assignment time.
    func applyTheme(classic: Bool) {
        classicTheme = classic
        let tv = terminalView!
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if classic {
                let green = DS.Color.classicShellForeground
                tv.nativeForegroundColor = green
                tv.nativeBackgroundColor = DS.Color.classicShellBackground
                tv.caretColor = green
                tv.selectedTextBackgroundColor = green.withAlphaComponent(DS.Opacity.selectionFillStrong)
                self.layer?.backgroundColor = DS.Color.classicShellBackground.cgColor
            } else {
                tv.nativeForegroundColor = .textColor
                tv.nativeBackgroundColor = .textBackgroundColor
                tv.caretColor = .controlAccentColor
                tv.selectedTextBackgroundColor = .selectedTextBackgroundColor
                self.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            }
        }
        let palette = (classic || isDark) ? DS.Color.shellPaletteDark : DS.Color.shellPaletteLight
        tv.installColors(palette.map(Self.terminalColor))
        tv.needsDisplay = true
    }

    /// An `NSColor` token as SwiftTerm's 16-bit-per-channel colour.
    private static func terminalColor(_ color: NSColor) -> SwiftTerm.Color {
        let c = color.usingColorSpace(.sRGB) ?? color
        func channel(_ v: CGFloat) -> UInt16 { UInt16((max(0, min(1, v)) * 65535).rounded()) }
        return SwiftTerm.Color(red: channel(c.redComponent), green: channel(c.greenComponent), blue: channel(c.blueComponent))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme(classic: classicTheme)
    }

    // MARK: Layout

    /// Resizes the terminal view within its clip view based on
    /// `desiredMinWidth` and the current clip size, then refreshes both
    /// scrollers (horizontal knob size from ratio, vertical knob size
    /// from SwiftTerm's scrollback).
    func layoutTerminal() {
        let visibleWidth = clipView.bounds.width
        let visibleHeight = clipView.bounds.height
        guard visibleWidth > 0, visibleHeight > 0 else { return }

        let targetWidth = max(desiredMinWidth, visibleWidth)

        // Clamp horizontal offset to valid range.
        let maxOffset = max(0, targetWidth - visibleWidth)
        if hOffset > maxOffset { hOffset = maxOffset }

        terminalView.frame = NSRect(x: -hOffset, y: 0, width: targetWidth, height: visibleHeight)

        // Horizontal scroller state.
        let overflow = targetWidth > visibleWidth + 0.5
        hScroller.isEnabled = overflow
        hScroller.knobProportion = overflow ? visibleWidth / targetWidth : 1.0
        hScroller.doubleValue = maxOffset > 0 ? Double(hOffset / maxOffset) : 0
        if !overflow { hScroller.alphaValue = 0 }

        // Vertical scroller state — mirrors SwiftTerm's scrollback.
        syncVerticalScroller()

        // The find bar floats over the terminal, so it has to be told where
        // the terminal just moved to.
        positionFindBar()
    }

    /// Pulls SwiftTerm's current scroll position/thumb size and updates
    /// the external vertical scroller. Safe to call from anywhere on the
    /// main actor (wheel events, page up/down, new output, layout).
    func syncVerticalScroller() {
        vScroller.isEnabled = terminalView.canScroll
        vScroller.knobProportion = terminalView.scrollThumbsize
        vScroller.doubleValue = terminalView.scrollPosition
        if !terminalView.canScroll { vScroller.alphaValue = 0 }
    }

    private func panHorizontally(by delta: CGFloat) {
        let visibleWidth = clipView.bounds.width
        let targetWidth = max(desiredMinWidth, visibleWidth)
        let maxOffset = max(0, targetWidth - visibleWidth)
        guard maxOffset > 0 else { return }
        hOffset = min(maxOffset, max(0, hOffset + delta))
        layoutTerminal()
        revealScrollers()
    }

    // MARK: Find bar

    /// Re-anchors SwiftTerm's find bar to the part of the terminal the user
    /// can actually see, and gives it the pane's own corner radius. Called
    /// by `TerminalModel.showFind()` right after the action that creates the
    /// bar; a no-op on every ⌘F after the first.
    ///
    /// SwiftTerm pins the bar 8 pt inside the *terminal view's* trailing
    /// edge, and the terminal view is not the pane. The moment a wide table
    /// pushes `desiredMinWidth` past the visible width, the terminal view
    /// runs off to the right and `clipView` masks everything past the pane
    /// edge — so the bar's close button and its three option toggles are the
    /// first things cut off, its rounded right-hand end goes with them, and
    /// what is left reads as something spilling out of the pane rather than
    /// as the pane's own chrome. Panning horizontally does the same thing,
    /// transiently, even on narrow output.
    ///
    /// Only the pins SwiftTerm installed **on the terminal view** are
    /// replaced; the bar's own maximum width and its internal stack are left
    /// exactly as the vendored copy set them, because `Vendor/SwiftTerm` is
    /// not ours to fork. The substitutes are expressed against the terminal
    /// view's leading edge with constants that `layoutTerminal()` keeps
    /// equal to the visible rectangle — that rectangle slides under the bar
    /// as the user pans, so a static inset would not hold.
    ///
    /// Re-parenting the bar onto this view would be tidier, and is
    /// deliberately not done: `removeFromSuperview()` resigns first
    /// responder, and SwiftTerm has already put the keyboard into the search
    /// field by the time we are called. Moving it would open the find bar
    /// with the caret nowhere.
    func adoptFindBar() {
        if findBar == nil, let bar = Self.findBarView(in: terminalView) {
            // Drop SwiftTerm's top/leading/trailing pins. They live on the
            // terminal view because that is the ancestor the two views
            // share; the bar's `width <= 520` is installed on the bar itself
            // and deliberately survives, so the bar still stops growing in a
            // wide pane.
            for constraint in terminalView.constraints
            where (constraint.firstItem as? NSView) === bar
                || (constraint.secondItem as? NSView) === bar {
                constraint.isActive = false
            }

            // The vendored bar demands 200 pt of search field at *required*
            // priority. Narrow the Shell to a sidebar and that cannot be
            // honoured alongside the two insets below; AppKit then resolves
            // the impossible layout by dropping whichever constraint it
            // likes — most often the trailing inset, which is precisely the
            // clipped-looking bar this method exists to prevent. Demote it
            // instead: the field already carries low horizontal compression
            // resistance, so it shrinks and the buttons stay reachable.
            if let field = Self.searchField(in: bar) {
                for constraint in field.constraints
                where constraint.firstAttribute == .width
                    && constraint.relation == .greaterThanOrEqual
                    && constraint.secondItem == nil {
                    constraint.isActive = false
                    let relaxed = field.widthAnchor
                        .constraint(greaterThanOrEqualToConstant: constraint.constant)
                    relaxed.priority = .defaultHigh
                    relaxed.isActive = true
                }
            }

            // Constants are filled in by `positionFindBar()` below; the
            // leading pin is an inequality so the bar keeps its natural
            // width until the pane is too narrow to hold it.
            let trailing = bar.trailingAnchor.constraint(equalTo: terminalView.leadingAnchor)
            let leading = bar.leadingAnchor.constraint(
                greaterThanOrEqualTo: terminalView.leadingAnchor)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: terminalView.topAnchor,
                                         constant: DS.Spacing.s),
                trailing,
                leading,
            ])
            findBar = bar
            findBarTrailing = trailing
            findBarLeading = leading

            // It is pane chrome now, so it wears the pane radius token
            // rather than the vendored literal that happens to match it.
            bar.layer?.cornerRadius = DS.Radius.panel
        }
        positionFindBar()
    }

    /// Keeps the find bar `DS.Spacing.s` inside the visible rectangle as the
    /// terminal view is widened by long output and slid sideways by the
    /// horizontal scroller.
    private func positionFindBar() {
        guard let trailing = findBarTrailing, let leading = findBarLeading else { return }
        let visibleWidth = clipView.bounds.width
        guard visibleWidth > 0 else { return }
        // The terminal view's frame origin is `-hOffset`, so in its own
        // coordinates the pane shows [hOffset, hOffset + visibleWidth).
        //
        // Written only when it actually changed. `layoutTerminal()` is one of
        // the things a layout pass can call (SwiftTerm's `sizeChanged` lands
        // there), and re-assigning a constraint constant invalidates the
        // engine whether or not the value moved — an unconditional write
        // would be a self-sustaining layout loop on every resize.
        let newTrailing = hOffset + visibleWidth - DS.Spacing.s
        let newLeading = hOffset + DS.Spacing.s
        if trailing.constant != newTrailing { trailing.constant = newTrailing }
        if leading.constant != newLeading { leading.constant = newLeading }
    }

    /// SwiftTerm's find bar type is `internal` to that module, so it is
    /// located by shape rather than by name: the terminal's one visual-effect
    /// subview, and the only subview of any kind holding a search field. The
    /// progress-bar overlay and the hidden scroller are neither.
    private static func findBarView(in parent: NSView) -> NSView? {
        parent.subviews.first { $0 is NSVisualEffectView && searchField(in: $0) != nil }
    }

    private static func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }

    // MARK: Scroller actions

    @objc private func vScrollerChanged(_ sender: NSScroller) {
        let tv = terminalView!
        switch sender.hitPart {
        case .decrementPage: tv.pageUp()
        case .incrementPage: tv.pageDown()
        case .knob, .knobSlot: tv.scroll(toPosition: sender.doubleValue)
        case .decrementLine: tv.scrollUp(lines: 1)
        case .incrementLine: tv.scrollDown(lines: 1)
        default: break
        }
        // Refresh scroller state after the terminal updates its buffer.
        sender.doubleValue = tv.scrollPosition
        sender.knobProportion = tv.scrollThumbsize
        revealScrollers()
    }

    @objc private func hScrollerChanged(_ sender: NSScroller) {
        let visibleWidth = clipView.bounds.width
        let targetWidth = max(desiredMinWidth, visibleWidth)
        let maxOffset = max(0, targetWidth - visibleWidth)
        guard maxOffset > 0 else { return }

        let pageStep = visibleWidth * 0.9
        let lineStep: CGFloat = 40
        switch sender.hitPart {
        case .decrementPage: hOffset = max(0, hOffset - pageStep)
        case .incrementPage: hOffset = min(maxOffset, hOffset + pageStep)
        case .decrementLine: hOffset = max(0, hOffset - lineStep)
        case .incrementLine: hOffset = min(maxOffset, hOffset + lineStep)
        case .knob, .knobSlot: hOffset = maxOffset * CGFloat(sender.doubleValue)
        default: return
        }
        layoutTerminal()
        revealScrollers()
    }

    // MARK: Context menu

    /// The terminal's right-click menu.
    ///
    /// Titles are the ones the same actions already carry elsewhere — the
    /// pane header's "Scroll to Bottom" and "Copy", Window ▸ Shell's "Clear
    /// Shell" and "Find in Shell…" — because a command that answers to two
    /// names reads as two commands. Key equivalents match the real bindings
    /// so the menu teaches them.
    ///
    /// Built fresh per click rather than cached: enablement depends on the
    /// selection, the clipboard and the scrollback, all of which move.
    fileprivate func makeContextMenu() -> NSMenu? {
        guard let model, let tv = terminalView else { return nil }
        // Refresh from SwiftTerm rather than trusting the published mirror:
        // the menu is the one place where a stale "Copy is enabled" would be
        // visible as a dead item under the pointer.
        model.noteSelectionChanged()

        let menu = NSMenu()
        // Every item's enablement is computed right here; letting AppKit
        // auto-validate would send `copy:` and friends up the responder
        // chain and grey them out on their own terms.
        menu.autoenablesItems = false
        menu.setAccessibilityLabel("Shell")

        addItem(to: menu, title: "Copy", action: #selector(contextCopy),
                key: "c", enabled: model.hasShellSelection)
        addItem(to: menu, title: "Paste", action: #selector(contextPaste),
                key: "v", enabled: NSPasteboard.general.canReadObject(forClasses: [NSString.self]))
        addItem(to: menu, title: "Select All", action: #selector(contextSelectAll),
                key: "a", enabled: true)

        menu.addItem(.separator())

        addItem(to: menu, title: "Find in Shell…", action: #selector(contextFind),
                key: "f", enabled: true)
        addItem(to: menu, title: "Scroll to Bottom", action: #selector(contextScrollToBottom),
                key: "", enabled: tv.canScroll)

        menu.addItem(.separator())

        addItem(to: menu, title: "Clear Shell", action: #selector(contextClear),
                key: "k", enabled: true)
        return menu
    }

    private func addItem(
        to menu: NSMenu,
        title: String,
        action: Selector,
        key: String,
        enabled: Bool
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : [.command]
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func contextCopy() {
        // Selection-only, matching the item's own enablement above: the menu
        // offers Copy exactly when there is a selection, so it must never
        // fall back to copying the whole scrollback behind the user.
        model?.copySelection()
    }

    @objc private func contextPaste() {
        terminalView?.paste(self)
    }

    @objc private func contextSelectAll() {
        terminalView?.selectAll(self)
        model?.noteSelectionChanged()
    }

    @objc private func contextFind() {
        model?.showFind()
    }

    @objc private func contextScrollToBottom() {
        model?.scrollToBottom()
    }

    @objc private func contextClear() {
        model?.clearTerminal()
    }

    // MARK: Helpers

    /// Returns the current user's login shell (falls back to /bin/zsh).
    static func userShell() -> String {
        let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufsize != -1 else { return "/bin/zsh" }
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufsize)
        defer { buffer.deallocate() }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        if getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) != 0 { return "/bin/zsh" }
        return String(cString: pwd.pw_shell)
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // SwiftTerm recalculates its cols/rows when we resize its frame.
        // Re-sync the scrollers.
        layoutTerminal()
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    /// OSC 7 carries a `file://host/path` URL (what update_terminal_cwd
    /// emits); older tools send a bare path. Either way the header gets
    /// a plain, percent-decoded filesystem path.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, !directory.isEmpty else { return }
        let path: String
        if directory.hasPrefix("file:"), let url = URL(string: directory), url.isFileURL {
            path = url.path
        } else if let decoded = directory.removingPercentEncoding {
            path = decoded
        } else {
            path = directory
        }
        guard !path.isEmpty, model?.sessionDirectoryDisplay != path else { return }
        model?.sessionDirectoryDisplay = path
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        model?.isShellRunning = false
    }
}

// MARK: - SwiftUI bridge

/// Thin representable that parents the model's cached `TerminalHostView`.
/// Creating/destroying this view never restarts the shell; only
/// `TerminalModel.restart()` builds a new host.
struct SwiftTermView: NSViewRepresentable {
    let workingDirectory: URL
    let classicTheme: Bool
    @EnvironmentObject private var model: TerminalModel

    func makeNSView(context: Context) -> NSView {
        let wrapper = NSView(frame: .zero)
        wrapper.wantsLayer = true
        attachHost(to: wrapper)
        return wrapper
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attachHost(to: nsView)
        guard let host = model.hostView as? TerminalHostView else { return }
        host.desiredMinWidth = model.minTerminalWidth
        host.applyThemeIfNeeded(classic: classicTheme)
        // Sync font — changing `tv.font` causes SwiftTerm to re-render its
        // existing buffer at the new size / family, which also fires
        // `sizeChanged` so the scrollers refresh.
        let desired = model.resolvedFont()
        let tv = host.terminalView!
        let sameSize = abs(tv.font.pointSize - desired.pointSize) < 0.1
        let sameFamily = tv.font.familyName == desired.familyName
        if !sameSize || !sameFamily {
            tv.font = desired
        }
        host.layoutTerminal()
    }

    private func attachHost(to wrapper: NSView) {
        let host: NSView
        if let cached = model.hostView, model.hostViewID == model.terminalViewID {
            host = cached
        } else {
            model.hostView?.removeFromSuperview()
            let fresh = TerminalHostView(
                model: model,
                workingDirectory: workingDirectory,
                classicTheme: classicTheme
            )
            model.hostView = fresh
            model.hostViewID = model.terminalViewID
            host = fresh
        }
        guard host.superview !== wrapper else { return }
        host.removeFromSuperview()
        host.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            host.topAnchor.constraint(equalTo: wrapper.topAnchor),
            host.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
    }
}

extension TerminalHostView {
    /// Re-applies the palette only when the toggle actually changed.
    func applyThemeIfNeeded(classic: Bool) {
        if classic != classicTheme {
            applyTheme(classic: classic)
        }
    }
}
