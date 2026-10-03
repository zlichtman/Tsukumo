import Foundation

// Shell integration for Tsukumo's terminal: small scripts that make zsh, bash, and fish report
// their folder (OSC 7) and mark prompts and commands (OSC 133), injected without touching the
// person's dotfiles, and a scanner that reads those reports from the terminal's output.

// MARK: Reading the output

/// What the shell (or a program) reported through an operating system command.
enum TerminalShellEvent: Equatable {
    /// OSC 7: the shell's current folder.
    case directory(String)
    /// OSC 133 A: a prompt is about to be drawn.
    case promptStart
    /// OSC 133 B: the prompt ended; what follows is typed input.
    case inputStart
    /// OSC 133 C: a command started, with its text when the shell sent it.
    case commandStart(String?)
    /// OSC 133 D: the command finished, with its exit status when known.
    case commandEnd(Int32?)
    /// OSC 0 or 2: a program set the title.
    case title(String)
}

/// Finds OSC 7, 133, 0, and 2 sequences in terminal output. It keeps its state between chunks, so
/// a sequence split across two reads is still found; it only reads the bytes (SwiftTerm draws them).
/// Sequences end with BEL or ST (ESC \); an unterminated one is dropped after 4 KB.
struct TerminalOSCScanner {
    private enum State { case ground, escape, osc, oscEscape }
    private var state = State.ground
    private var payload: [UInt8] = []
    static let maximumPayload = 4096

    mutating func scan<S: Sequence>(_ bytes: S) -> [TerminalShellEvent] where S.Element == UInt8 {
        var events: [TerminalShellEvent] = []
        for byte in bytes {
            switch state {
            case .ground:
                // 8-bit C1 controls (0x9D) aren't read: in UTF-8 output those bytes belong to characters.
                if byte == 0x1B { state = .escape }
            case .escape:
                if byte == 0x5D { state = .osc; payload.removeAll(keepingCapacity: true) } else { state = byte == 0x1B ? .escape : .ground }
            case .osc:
                if byte == 0x07 { finish(&events) }
                else if byte == 0x1B { state = .oscEscape }
                else if payload.count < Self.maximumPayload { payload.append(byte) }
                else { state = .ground; payload.removeAll(keepingCapacity: true) }
            case .oscEscape:
                if byte == 0x5C { finish(&events) }
                else {
                    // ESC then anything but "\" abandons the sequence; "]" opens a new one.
                    payload.removeAll(keepingCapacity: true)
                    state = byte == 0x5D ? .osc : byte == 0x1B ? .escape : .ground
                }
            }
        }
        return events
    }
    /// Only chunks with an ESC in them (or a sequence already open) need a byte-by-byte scan; the
    /// check is a `memchr`, so plain output (`cat`, `yes`) costs almost nothing.
    mutating func scanFast(_ bytes: ArraySlice<UInt8>) -> [TerminalShellEvent] {
        if state == .ground {
            let hasEscape = bytes.withUnsafeBufferPointer { buffer in
                buffer.baseAddress.map { memchr($0, 0x1B, buffer.count) != nil } ?? false
            }
            if !hasEscape { return [] }
        }
        return scan(bytes)
    }
    private mutating func finish(_ events: inout [TerminalShellEvent]) {
        state = .ground
        defer { payload.removeAll(keepingCapacity: true) }
        if let event = Self.parse(String(decoding: payload, as: UTF8.self)) { events.append(event) }
    }

    /// Parses one OSC payload (the part between `ESC ]` and the terminator).
    static func parse(_ payload: String) -> TerminalShellEvent? {
        let parts = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let code = parts.first else { return nil }
        let rest = parts.count > 1 ? String(parts[1]) : ""
        switch code {
        case "7": return directory(fromOSC7: rest).map { .directory($0) }
        case "0", "2": return .title(rest)
        case "133":
            let fields = rest.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            switch fields.first ?? "" {
            case "A": return .promptStart
            case "B": return .inputStart
            case "C":
                let line = fields.dropFirst().first { $0.hasPrefix("cmdline_url=") }.map { String($0.dropFirst("cmdline_url=".count)) }
                return .commandStart(line.flatMap { $0.removingPercentEncoding ?? $0 })
            case "D":
                let status = fields.count > 1 ? Int32(fields[1]) : nil
                return .commandEnd(status)
            default: return nil
            }
        default: return nil
        }
    }
    /// `file://host/path` (percent-encoded) → `/path`. Other hosts are still read as local paths:
    /// a shell reports its own host name, which may not match what Foundation calls this Mac.
    static func directory(fromOSC7 value: String) -> String? {
        if value.hasPrefix("/") { return value.removingPercentEncoding ?? value }
        guard value.lowercased().hasPrefix("file://") else { return nil }
        let afterScheme = value.dropFirst("file://".count)
        guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
        let path = String(afterScheme[slash...])
        return path.removingPercentEncoding ?? path
    }
}

/// A shell's state as Tsukumo sees it from the marks: whether it's at a prompt, what's running, and
/// how long the last command took. Pure, so the timing and the notice rule can be tested.
struct TerminalCommandTracker: Equatable {
    struct Finished: Equatable {
        var command: String?
        var status: Int32?
        var duration: TimeInterval
    }
    private(set) var hasIntegration = false
    private(set) var running: String?
    private(set) var isRunning = false
    private(set) var startedAt: Date?
    private(set) var atPrompt = false
    /// Prompts seen so far; a command typed for the person waits for the first.
    private(set) var prompts = 0

    /// Applies one event; returns the finished command when this event ended one.
    mutating func apply(_ event: TerminalShellEvent, now: Date = Date()) -> Finished? {
        switch event {
        case .promptStart:
            hasIntegration = true; atPrompt = true; prompts += 1
            // A prompt without a D (a shell that doesn't report exit status) still ends the command.
            if isRunning { return end(status: nil, now: now) }
        case .inputStart: hasIntegration = true; atPrompt = true
        case .commandStart(let text):
            hasIntegration = true; atPrompt = false; isRunning = true; startedAt = now
            running = text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        case .commandEnd(let status):
            hasIntegration = true
            if isRunning { return end(status: status, now: now) }
        case .directory, .title: break
        }
        return nil
    }
    private mutating func end(status: Int32?, now: Date) -> Finished {
        let finished = Finished(command: running, status: status, duration: startedAt.map { now.timeIntervalSince($0) } ?? 0)
        isRunning = false; running = nil; startedAt = nil
        return finished
    }
    /// A finished command is worth a notification when it took at least `threshold` seconds and
    /// Tsukumo wasn't in front (so the person wasn't watching it).
    static func shouldNotify(_ finished: Finished, threshold: TimeInterval, appActive: Bool) -> Bool {
        !appActive && finished.duration >= threshold
    }
}

// MARK: Injecting the integration

/// How a pane's shell is started: the program, its arguments, and the environment Tsukumo adds.
struct TerminalLaunch: Equatable {
    var executable: String
    var arguments: [String]
    /// argv[0]; a leading "-" makes it a login shell.
    var execName: String
    var environment: [String: String]
    /// The integration injected, if any (zsh, bash, or fish).
    var integration: String?
}

/// Writes the integration scripts to Tsukumo's own folder and builds each shell's launch so they load
/// after the person's own startup files. The person's dotfiles are never edited:
/// - zsh: `ZDOTDIR` points at Tsukumo's folder, whose `.zshenv` puts the person's `ZDOTDIR` back,
///   sources their `.zshenv`, and installs hooks that run after their `.zshrc` (on the first prompt).
/// - bash: `--rcfile` names Tsukumo's script, which loads what a login shell would
///   (`/etc/profile`, then the first of `~/.bash_profile`, `~/.bash_login`, `~/.profile`), then the hooks.
/// - fish: `XDG_DATA_DIRS` gains Tsukumo's folder, so fish finds `fish/vendor_conf.d/tsukumo.fish`.
/// Other shells start as login shells with no integration.
enum TerminalShellIntegration {
    static let version = "1"

    /// The folder the scripts are written to: Tsukumo's Application Support folder.
    /// Tests use a temporary folder instead.
    static var defaultFolder: URL {
        if KemoSabeMacApp.isTestHost { return FileManager.default.temporaryDirectory.appendingPathComponent("TsukumoTests-ShellIntegration", isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tsukumo/ShellIntegration", isDirectory: true)
    }

    /// Writes the scripts if they're missing or from another version. Returns false if they couldn't be written.
    @discardableResult static func install(in folder: URL = defaultFolder) -> Bool {
        let files: [(String, String)] = [("zsh/.zshenv", zshEnv), ("zsh/tsukumo.zsh", zshHooks), ("bash/tsukumo.bash", bashRC), ("fish/vendor_conf.d/tsukumo.fish", fishHooks), ("VERSION", version)]
        do {
            for (path, contents) in files {
                let url = folder.appendingPathComponent(path)
                if (try? String(contentsOf: url, encoding: .utf8)) == contents { continue }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url, options: .atomic)
            }
            return true
        } catch { return false }
    }

    /// The launch for `shell`, with the integration when `enabled` and the shell is one Tsukumo knows.
    /// `inherited` is the app's own environment (for a `ZDOTDIR` or `XDG_DATA_DIRS` the person set).
    static func launch(shell: String, enabled: Bool, folder: URL = defaultFolder, inherited: [String: String]) -> TerminalLaunch {
        let name = (shell as NSString).lastPathComponent
        var launch = TerminalLaunch(executable: shell, arguments: [], execName: "-" + name, environment: [:], integration: nil)
        guard enabled else { return launch }
        launch.environment["TSUKUMO_SHELL_INTEGRATION_DIR"] = folder.path
        switch name {
        case "zsh":
            // A login shell as usual; zsh reads Tsukumo's .zshenv first, which hands back to the person's.
            if let original = inherited["ZDOTDIR"] { launch.environment["TSUKUMO_ZSH_ZDOTDIR"] = original }
            launch.environment["ZDOTDIR"] = folder.appendingPathComponent("zsh").path
            launch.integration = "zsh"
        case "bash":
            // --rcfile only applies to an interactive non-login shell, so the script does the login part itself.
            launch.execName = name
            launch.arguments = ["--rcfile", folder.appendingPathComponent("bash/tsukumo.bash").path, "-i"]
            launch.environment["TSUKUMO_BASH_LOGIN"] = "1"
            launch.integration = "bash"
        case "fish":
            let existing = inherited["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/share:/usr/share"
            launch.environment["XDG_DATA_DIRS"] = folder.path + ":" + existing
            launch.integration = "fish"
        default:
            launch.environment.removeValue(forKey: "TSUKUMO_SHELL_INTEGRATION_DIR")
        }
        return launch
    }

    // The scripts. Each emits OSC 133 A before the prompt (and B after it where the prompt can carry
    // it), C with the command line when a command starts, D with its exit status when it ends, and
    // OSC 7 with the folder. Nothing is printed on a shell without a terminal, and they load once.

    static let zshEnv = #"""
    # Tsukumo shell integration for zsh. Tsukumo pointed ZDOTDIR here; put yours back, load your
    # own .zshenv, and then (for interactive shells) the hooks. Your startup files are not changed.
    if [[ -n "${TSUKUMO_ZSH_ZDOTDIR+X}" ]]; then
        builtin export ZDOTDIR="$TSUKUMO_ZSH_ZDOTDIR"
        builtin unset TSUKUMO_ZSH_ZDOTDIR
    else
        builtin unset ZDOTDIR
    fi
    {
        builtin typeset _tsukumo_zshenv="${ZDOTDIR-$HOME}/.zshenv"
        [[ ! -r "$_tsukumo_zshenv" ]] || builtin source -- "$_tsukumo_zshenv"
    } always {
        builtin unset _tsukumo_zshenv
        if [[ -o interactive && -n "$TSUKUMO_SHELL_INTEGRATION_DIR" && -r "$TSUKUMO_SHELL_INTEGRATION_DIR/zsh/tsukumo.zsh" ]]; then
            builtin source -- "$TSUKUMO_SHELL_INTEGRATION_DIR/zsh/tsukumo.zsh"
        fi
    }
    """#

    static let zshHooks = #"""
    # Tsukumo shell integration hooks for zsh (OSC 7 and OSC 133).
    [[ -n "$_TSUKUMO_ZSH_LOADED" ]] && return
    typeset -g _TSUKUMO_ZSH_LOADED=1 _tsukumo_running=0
    builtin unset TSUKUMO_SHELL_INTEGRATION_DIR
    _tsukumo_urlencode() {
        builtin emulate -L zsh; builtin setopt extendedglob
        local LC_ALL=C input="$1" out="" c i
        for (( i = 1; i <= ${#input}; i++ )); do
            c="${input[i]}"
            case "$c" in
                [a-zA-Z0-9/._~-]) out+="$c" ;;
                *) builtin printf -v c '%%%02X' "'$c"; out+="$c" ;;
            esac
        done
        REPLY="$out"
    }
    _tsukumo_precmd() {
        local ret=$?
        if (( _tsukumo_running )); then
            builtin printf '\e]133;D;%s\a' "$ret"
            _tsukumo_running=0
        fi
        _tsukumo_urlencode "$PWD"
        builtin printf '\e]7;file://%s%s\a' "${HOST}" "$REPLY"
        builtin printf '\e]133;A\a'
        # Mark the end of the prompt, once, even when a theme rebuilds PS1 each time.
        [[ "$PS1" == *$'\e]133;B\a'* ]] || PS1="$PS1"$'%{\e]133;B\a%}'
        return $ret
    }
    _tsukumo_preexec() {
        _tsukumo_running=1
        _tsukumo_urlencode "$1"
        builtin printf '\e]133;C;cmdline_url=%s\a' "$REPLY"
    }
    # Installed on the first prompt, after your .zshrc, so a theme's hooks run first.
    _tsukumo_deferred_init() {
        builtin autoload -Uz add-zsh-hook
        add-zsh-hook -d precmd _tsukumo_deferred_init
        add-zsh-hook precmd _tsukumo_precmd
        add-zsh-hook preexec _tsukumo_preexec
        _tsukumo_precmd
    }
    builtin autoload -Uz add-zsh-hook
    add-zsh-hook precmd _tsukumo_deferred_init
    """#

    static let bashRC = #"""
    # Tsukumo shell integration for bash. Tsukumo started bash with --rcfile pointing here. Load what a
    # login shell would load, then add the hooks. Your startup files are not changed.
    if [ -n "$TSUKUMO_BASH_LOGIN" ]; then
        builtin unset TSUKUMO_BASH_LOGIN
        [ -r /etc/profile ] && builtin source /etc/profile
        if [ -r "$HOME/.bash_profile" ]; then builtin source "$HOME/.bash_profile"
        elif [ -r "$HOME/.bash_login" ]; then builtin source "$HOME/.bash_login"
        elif [ -r "$HOME/.profile" ]; then builtin source "$HOME/.profile"
        fi
    elif [ -r "$HOME/.bashrc" ]; then
        builtin source "$HOME/.bashrc"
    fi
    builtin unset TSUKUMO_SHELL_INTEGRATION_DIR
    if [ -z "$_TSUKUMO_BASH_LOADED" ] && [[ $- == *i* ]]; then
        _TSUKUMO_BASH_LOADED=1
        _tsukumo_status=0
        _tsukumo_urlencode() {
            local LC_ALL=C input="$1" out="" c i
            for (( i = 0; i < ${#input}; i++ )); do
                c="${input:i:1}"
                case "$c" in
                    [a-zA-Z0-9/._~-]) out+="$c" ;;
                    *) builtin printf -v c '%%%02X' "'$c"; out+="$c" ;;
                esac
            done
            REPLY="$out"
        }
        _tsukumo_save_status() { _tsukumo_status=$?; }
        _tsukumo_prompt() {
            local ret=$_tsukumo_status
            builtin printf '\e]133;D;%s\a' "$ret"
            _tsukumo_urlencode "$PWD"
            builtin printf '\e]7;file://%s%s\a' "${HOSTNAME}" "$REPLY"
            [[ "$PS1" == *'133;A'* ]] || PS1='\[\e]133;A\a\]'"$PS1"'\[\e]133;B\a\]'
            return $ret
        }
        _tsukumo_command() { _tsukumo_urlencode "$(HISTTIMEFORMAT= builtin history 1 | command sed 's/^ *[0-9]* *//')"; builtin printf '\e]133;C;cmdline_url=%s\a' "$REPLY"; }
        # The status is read first and the prompt marks are added last, after your PROMPT_COMMAND.
        PROMPT_COMMAND="_tsukumo_save_status${PROMPT_COMMAND:+; $PROMPT_COMMAND}; _tsukumo_prompt"
        # PS0 (bash 4.4 and later) runs as a command starts. The bash that comes with macOS is 3.2,
        # which gets folder tracking and prompt marks but not command marks.
        if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
            PS0='$(_tsukumo_command)'"$PS0"
        fi
    fi
    """#

    static let fishHooks = #"""
    # Tsukumo shell integration for fish (OSC 7 and OSC 133). Loaded through XDG_DATA_DIRS.
    status is-interactive; or exit 0
    set -q _tsukumo_fish_loaded; and exit 0
    set -g _tsukumo_fish_loaded 1
    set -e TSUKUMO_SHELL_INTEGRATION_DIR
    function __tsukumo_prompt --on-event fish_prompt
        printf '\e]7;file://%s%s\a' (hostname) (string escape --style=url -- $PWD)
        printf '\e]133;A\a'
    end
    function __tsukumo_preexec --on-event fish_preexec
        printf '\e]133;C;cmdline_url=%s\a' (string escape --style=url -- "$argv")
    end
    function __tsukumo_postexec --on-event fish_postexec
        printf '\e]133;D;%s\a' $status
    end
    """#
}
