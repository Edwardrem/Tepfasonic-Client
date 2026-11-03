import Foundation

/// OSC 133 prompt hooks for bash and zsh, sent as one line after connecting
/// when the remote login shell supports them. They tell the terminal where
/// the prompt, the typed command and the output begin, and the exit status.
public enum ShellIntegration {
    /// bash: PROMPT_COMMAND for D/A, a DEBUG trap armed once per prompt for C, PS1 suffix for B.
    static let bash = #"__tepfa_precmd() { local s=$?; printf '\033]133;D;%s\007\033]7;file://%s%s\007\033]133;A\007' "$s" "${HOSTNAME:-$(hostname)}" "$PWD"; }; __tepfa_arm() { __tepfa_armed=1; }; __tepfa_preexec() { [ "$__tepfa_armed" = 1 ] || return 0; [ -n "$COMP_LINE" ] && return 0; __tepfa_armed=0; printf '\033]133;C\007'; }; __tepfa_armed=0; PROMPT_COMMAND="__tepfa_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND};__tepfa_arm"; PS1="${PS1}\[$(printf '\033]133;B\007')\]"; trap '__tepfa_preexec' DEBUG"#

    /// zsh: precmd/preexec hooks and a PS1 suffix for B.
    static let zsh = #"__tepfa_precmd() { local s=$?; printf '\033]133;D;%s\007\033]7;file://%s%s\007\033]133;A\007' "$s" "${HOST:-$(hostname)}" "$PWD"; }; __tepfa_preexec() { printf '\033]133;C\007'; }; autoload -Uz add-zsh-hook; add-zsh-hook precmd __tepfa_precmd; add-zsh-hook preexec __tepfa_preexec; PS1="${PS1}%{$(printf '\033]133;B\007')%}""#

    /// Shells the one-liner can configure, matched against the login shell's basename.
    public static let supportedShells: Set<String> = ["bash", "zsh"]

    public static func supports(loginShell: String) -> Bool {
        supportedShells.contains((loginShell.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent)
    }

    /// The line typed into the shell, without the trailing Enter. The leading
    /// space keeps it out of history where HISTCONTROL/HIST_IGNORE_SPACE is
    /// set. `eraseRows` moves the cursor back up over the echoed line and
    /// erases it so the prompt is redrawn where it was; 0 leaves the echo.
    public static func installLine(eraseRows: Int) -> String {
        var line = " if [ -n \"$ZSH_VERSION\" ]; then \(zsh); elif [ -n \"$BASH_VERSION\" ]; then \(bash); fi"
        if eraseRows > 0 {
            line += "; printf '\\033[\(eraseRows)A\\033[J'"
        }
        return line
    }

    /// Builds the install line for a prompt whose cursor sits at `cursorColumn`
    /// on a `columns`-wide terminal, sized so the shell can erase its own echo.
    /// The echo wraps every `columns` characters; the shell's output starts
    /// on the row after the last echoed one.
    public static func installLine(cursorColumn: Int, columns: Int) -> String {
        guard columns > 0 else { return installLine(eraseRows: 0) }
        var rows = 1
        var line = installLine(eraseRows: rows)
        for _ in 0..<3 {
            var total = cursorColumn + line.utf8.count
            if total % columns == 0 {
                // readline wraps an exactly full line itself; avoid the ambiguity.
                line += " "
                total += 1
            }
            let needed = total / columns + 1
            if needed == rows { return line }
            rows = needed
            line = installLine(eraseRows: rows)
        }
        return line
    }
}
