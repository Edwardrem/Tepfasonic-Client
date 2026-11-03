import Foundation
import TepfaCore

/// Decides whether a command the agent proposes may run on a host.
///
/// Three layers: destructive patterns always need the user (and are refused
/// outright on read-only hosts); the read-only list names commands that only
/// inspect the host; the host's allowlist patterns let chosen commands run
/// unattended in `.allowlist` mode.
public enum CommandGuard {
    public enum Verdict: Equatable, Sendable {
        /// Runs without asking. The string says why (read-only list, allowlist pattern).
        case allow(String)
        /// Show the approval sheet. The string is the reason shown to the user.
        case ask(String)
        /// Refused without asking.
        case deny(String)
    }

    // MARK: Destructive patterns

    private struct Pattern {
        let regex: NSRegularExpression
        let label: String

        init(_ pattern: String, _ label: String, caseInsensitive: Bool = false) {
            regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
            self.label = label
        }
    }

    private static let destructive: [Pattern] = [
        Pattern(#"(^|[\s;&|(])rm\s+(-\S*\s+)*-\S*[rRf]"#, "rm with -r or -f"),
        Pattern(#"(^|[\s;&|(])rm\s+(-\S*\s+)*(/|~|\*|/\*|\.\s*$)"#, "rm of / ~ or *"),
        Pattern(#"(^|[\s;&|(])dd\s"#, "dd"),
        Pattern(#"(^|[\s;&|(])(mkfs(\.\w+)?|mke2fs|mkswap|wipefs|fdisk|sfdisk|sgdisk|parted|shred)(\s|$)"#, "disk formatting or wiping"),
        Pattern(#">\s*/dev/(sd|nvme|hd|vd|xvd|disk|mapper/)\S*"#, "writing to a raw disk device"),
        Pattern(#"\b(drop|truncate)\s+(table|database|schema|index|view|user|role|tablespace)\b"#, "SQL DROP / TRUNCATE", caseInsensitive: true),
        Pattern(#"\bdelete\s+from\s+\S+\s*;?\s*$"#, "SQL DELETE without WHERE", caseInsensitive: true),
        Pattern(#"(^|[\s;&|(])(shutdown|reboot|halt|poweroff)(\s|$)"#, "shutdown or reboot"),
        Pattern(#"(^|[\s;&|(])(init|telinit)\s+[06](\s|$)"#, "shutdown or reboot"),
        Pattern(#"(^|[\s;&|(])systemctl\s+(reboot|poweroff|halt|kexec|suspend|hibernate)(\s|$)"#, "shutdown or reboot"),
        Pattern(#"\|\s*(sudo\s+(-\S+\s+)*)?(/bin/|/usr/bin/|/usr/local/bin/)?(ba|z|da|k|a|c|tc|fi)?sh(\s|$)"#, "pipes into a shell"),
        Pattern(#"(^|[\s;&|(])(ba|z|da|k|)sh\s+<\("#, "runs a process substitution in a shell"),
        Pattern(#"(^|[\s;&|(])(source|\.)\s+<\("#, "sources a process substitution"),
        Pattern(#"(^|[\s;&|(])eval\s"#, "eval"),
        Pattern(#"(^|[\s;&|(])chmod\s+(-\S+\s+)*[0-7]*777(\s|$)"#, "chmod 777"),
        Pattern(#"(^|[\s;&|(])chmod\s+(-\S+\s+)*-R\s+.*\s/\s*$"#, "recursive chmod of /"),
        Pattern(#"(^|[\s;&|(])chown\s+(-\S+\s+)*-R\s+.*\s/\s*$"#, "recursive chown of /"),
        Pattern(#"(^|[\s;&|(])kill\s+(-\S+\s+)*-1(\s|$)"#, "kill -1 (every process)"),
        Pattern(#"(^|[\s;&|(])(killall|pkill)\s+(-\S+\s+)*(sshd|init|systemd)(\s|$)"#, "killing sshd or init"),
        Pattern(#"(^|[\s;&|(])(iptables|ip6tables)\s+(-\S+\s+)*(-F|--flush|-X|-P\s+INPUT\s+DROP)"#, "flushing firewall rules"),
        Pattern(#"(^|[\s;&|(])(nft\s+flush|ufw\s+(disable|reset))(\s|$)"#, "disabling the firewall"),
        Pattern(#":\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#, "fork bomb"),
        Pattern(#"(^|[\s;&|(])(userdel|groupdel|passwd|chpasswd|usermod\s+(-\S+\s+)*-L)(\s|$)"#, "changing accounts or passwords"),
        Pattern(#"(^|[\s;&|(])git\s+(push\s+.*(--force|-f\b)|reset\s+--hard|clean\s+-\S*f|branch\s+-D|checkout\s+--\s+\.)"#, "destructive git operation"),
        Pattern(#"(^|[\s;&|(])docker\s+(system\s+prune|container\s+prune|image\s+prune|volume\s+(prune|rm)|rm\s+-f|rmi)(\s|$)"#, "removing docker resources"),
        Pattern(#"(^|[\s;&|(])kubectl\s+(-\S+\s+)*delete(\s|$)"#, "kubectl delete"),
        Pattern(#"(^|[\s;&|(])crontab\s+(-\S+\s+)*-r(\s|$)"#, "removing the crontab"),
        Pattern(#"(^|[\s;&|(])(apt|apt-get|yum|dnf|zypper|pacman)\s+(-\S+\s+)*(remove|purge|autoremove|-R\S*)(\s|$)"#, "removing packages"),
        Pattern(#"(^|[\s;&|(])truncate\s+(-\S+\s+)*-s\s*0(\s|$)"#, "truncating a file"),
        Pattern(#"(^|[;&|(]\s*|\s)>\s*(?!/dev/null)(?!&)[^\s|;&]+"#, "truncates a file with >"),
        Pattern(#"(^|[\s;&|(])mv\s+.*\s/dev/null(\s|$)"#, "moving to /dev/null"),
        Pattern(#"(^|[\s;&|(])(history\s+-c|unset\s+HISTFILE)(\s|$)"#, "clearing shell history"),
    ]

    /// The destructive pattern a command matches, if any. `>` redirections to
    /// /dev/null and `2>&1` do not count.
    public static func destructiveMatch(_ command: String) -> String? {
        let text = normalizedForScan(command)
        let range = NSRange(text.startIndex..., in: text)
        for pattern in destructive where pattern.regex.firstMatch(in: text, options: [], range: range) != nil {
            return pattern.label
        }
        return nil
    }

    private static func normalizedForScan(_ command: String) -> String {
        var text = command
        for harmless in ["2>&1", "&>/dev/null", "&> /dev/null", "2>/dev/null", "2> /dev/null", ">/dev/null", "> /dev/null", ">>/dev/null", ">> /dev/null"] {
            text = text.replacingOccurrences(of: harmless, with: " ")
        }
        return text
    }

    // MARK: Read-only list

    /// Commands that only inspect the host, with optional argument rules.
    private static let readOnlyCommands: [String: (@Sendable ([String]) -> Bool)?] = {
        var table: [String: (@Sendable ([String]) -> Bool)?] = [:]
        for name in ["ls", "cat", "head", "tail", "grep", "egrep", "fgrep", "rg", "ag", "zcat", "zgrep", "wc", "sort", "uniq", "cut", "tr", "column", "tac", "nl",
                     "df", "du", "free", "uptime", "whoami", "id", "hostname", "uname", "ps", "pgrep", "pstree", "netstat", "ss", "ifconfig", "lsblk", "blkid", "lsof", "dmesg",
                     "date", "cal", "env", "printenv", "which", "whereis", "type", "file", "stat", "md5sum", "sha1sum", "sha256sum", "cksum", "nproc", "lscpu", "lsmem", "lspci", "lsusb",
                     "lsb_release", "who", "w", "last", "lastlog", "true", "false", "pwd", "echo", "printf", "basename", "dirname", "readlink", "realpath", "tree",
                     "vmstat", "iostat", "mpstat", "sar", "dig", "nslookup", "host", "getent", "ulimit", "locale", "timedatectl", "hostnamectl", "loginctl",
                     "diff", "cmp", "comm", "strings", "hexdump", "xxd", "od", "jq", "yq", "test", "[", "seq", "expr", "bc", "sleep", "arp", "route", "numfmt", "fold", "paste", "join", "rev", "expand",
                     "nginx", "apachectl", "httpd", "sshd", "showmount", "ldd", "ldconfig", "getcap", "getfacl", "namei", "findmnt", "swapon", "losetup", "journalctl", "systemctl", "docker", "kubectl", "git",
                     "ip", "apt", "apt-cache", "dpkg", "dpkg-query", "rpm", "yum", "dnf", "brew", "pip", "pip3", "npm", "crontab", "find", "sed", "awk", "gawk", "mawk", "top", "ping", "traceroute", "mtr", "mount", "stat", "python3", "python", "node", "curl", "wget"] {
            table[name] = nil as (@Sendable ([String]) -> Bool)?
        }
        table["find"] = { args in !args.contains { ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"].contains($0) } }
        table["sed"] = { args in !args.contains { $0.hasPrefix("-i") || $0 == "--in-place" || $0.hasPrefix("--in-place=") } && !args.joined(separator: " ").contains(" w ") && !args.contains { $0.hasPrefix("w/") } }
        let awkRule: @Sendable ([String]) -> Bool = { args in !args.joined(separator: " ").contains("system(") && !args.contains { $0.hasPrefix("-i") } }
        table["awk"] = awkRule; table["gawk"] = awkRule; table["mawk"] = awkRule
        table["systemctl"] = { args in
            let verb = firstVerb(args)
            return ["status", "show", "list-units", "list-unit-files", "is-active", "is-enabled", "is-failed", "is-system-running", "cat", "list-timers", "list-dependencies", "list-sockets", "list-jobs", "get-default", "show-environment", "help"].contains(verb)
        }
        table["journalctl"] = { args in !args.contains { $0.hasPrefix("--vacuum") || $0 == "--rotate" || $0 == "--flush" || $0 == "--sync" || $0 == "--relinquish-var" } }
        table["docker"] = { args in
            let verb = firstVerb(args)
            switch verb {
            case "ps", "logs", "images", "inspect", "version", "info", "top", "port", "diff", "history", "stats", "events", "search": return !(verb == "stats" && !args.contains("--no-stream"))
            case "container", "image", "network", "volume", "compose", "system", "node", "service", "stack", "context":
                let sub = args.dropFirst(args.firstIndex(of: verb)! + 1).first { !$0.hasPrefix("-") } ?? ""
                return ["ls", "list", "inspect", "logs", "ps", "df", "top", "port", "images", "version", "events", "config", "show"].contains(sub)
            default: return false
            }
        }
        table["kubectl"] = { args in ["get", "describe", "logs", "version", "top", "cluster-info", "explain", "api-resources", "api-versions", "config", "diff", "auth"].contains(firstVerb(args)) && !(firstVerb(args) == "config" && args.contains { ["set", "use-context", "delete-context", "unset", "set-context", "set-cluster", "set-credentials"].contains($0) }) }
        table["git"] = { args in
            let verb = firstVerb(args)
            switch verb {
            case "status", "log", "diff", "show", "rev-parse", "ls-files", "ls-remote", "blame", "describe", "shortlog", "reflog", "cat-file", "grep", "config", "remote", "branch", "tag", "stash", "worktree":
                if verb == "branch" { return !args.contains { ["-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move", "--copy", "--set-upstream-to", "-u"].contains($0) } && args.filter { !$0.hasPrefix("-") }.count <= 1 }
                if verb == "tag" { return args.filter { !$0.hasPrefix("-") }.count <= 1 && !args.contains { ["-d", "--delete", "-a", "-s", "-f"].contains($0) } }
                if verb == "stash" { return args.contains("list") || args.contains("show") }
                if verb == "remote" { return args.filter { !$0.hasPrefix("-") }.count <= 1 }
                if verb == "config" { return args.contains("--get") || args.contains("--list") || args.contains("-l") || args.contains("--get-all") || args.contains("--get-regexp") }
                if verb == "worktree" { return args.contains("list") }
                return true
            default: return false
            }
        }
        table["ip"] = { args in
            let words = args.filter { !$0.hasPrefix("-") }
            return !words.contains { ["add", "del", "delete", "set", "change", "replace", "flush", "append", "link"].contains($0) && $0 != "link" } && !(words.contains("link") && words.contains { ["set", "add", "del", "delete"].contains($0) })
        }
        table["apt"] = { args in ["list", "policy", "show", "search", "depends", "rdepends", "changelog", "moo"].contains(firstVerb(args)) }
        table["apt-cache"] = { _ in true }
        table["dpkg"] = { args in args.contains { ["-l", "-L", "-s", "-S", "--list", "--status", "--listfiles", "--search", "--print-architecture", "--get-selections"].contains($0) } && !args.contains { ["-i", "-r", "-P", "--install", "--remove", "--purge", "--configure", "--set-selections"].contains($0) } }
        table["rpm"] = { args in args.contains { $0.hasPrefix("-q") || $0 == "--query" } && !args.contains { ["-i", "-U", "-e", "--install", "--upgrade", "--erase"].contains($0) } }
        let pkgQuery: @Sendable ([String]) -> Bool = { args in ["list", "info", "search", "provides", "repolist", "history", "check-update", "deplist"].contains(firstVerb(args)) }
        table["yum"] = pkgQuery; table["dnf"] = pkgQuery
        table["brew"] = { args in ["list", "info", "deps", "outdated", "doctor", "config", "search", "services"].contains(firstVerb(args)) && !(firstVerb(args) == "services" && args.contains { ["start", "stop", "restart", "run", "kill", "cleanup"].contains($0) }) }
        let pipQuery: @Sendable ([String]) -> Bool = { args in ["list", "show", "freeze", "check", "--version", "-V"].contains(firstVerb(args)) }
        table["pip"] = pipQuery; table["pip3"] = pipQuery
        table["npm"] = { args in ["ls", "list", "view", "outdated", "--version", "-v", "config"].contains(firstVerb(args)) && !(firstVerb(args) == "config" && args.contains { ["set", "delete", "edit"].contains($0) }) }
        table["crontab"] = { args in args == ["-l"] || (args.count == 3 && args[0] == "-u" && args[2] == "-l") || (args.count == 2 && args[0] == "-l") }
        table["top"] = { args in args.contains { $0.hasPrefix("-b") } || args.contains { $0.hasPrefix("-n") } || args.contains("-l") }
        table["ping"] = { args in args.contains { $0.hasPrefix("-c") } }
        table["mtr"] = { args in args.contains { $0 == "-r" || $0 == "--report" } }
        table["mount"] = { args in args.isEmpty || args == ["-l"] }
        table["nginx"] = { args in args.contains("-t") || args.contains("-T") || args.contains("-v") || args.contains("-V") }
        table["apachectl"] = { args in args.contains { ["configtest", "-t", "-S", "-M", "-v", "-V", "status", "fullstatus"].contains($0) } }
        table["httpd"] = { args in args.contains { ["-t", "-S", "-M", "-v", "-V"].contains($0) } }
        table["sshd"] = { args in args.contains("-T") || args.contains("-t") }
        table["swapon"] = { args in args.contains("--show") || args == ["-s"] }
        table["losetup"] = { args in args.contains("-a") || args.contains("--list") || args.contains("-l") }
        table["ldconfig"] = { args in args.contains("-p") }
        table["timedatectl"] = { args in firstVerb(args).isEmpty || ["status", "show", "list-timezones", "timesync-status"].contains(firstVerb(args)) }
        table["hostnamectl"] = { args in firstVerb(args).isEmpty || ["status", "show"].contains(firstVerb(args)) }
        table["loginctl"] = { args in firstVerb(args).isEmpty || ["list-sessions", "list-users", "show-session", "show-user", "session-status", "user-status"].contains(firstVerb(args)) }
        let interpreter: @Sendable ([String]) -> Bool = { args in args.first == "--version" || args.first == "-V" || args.first == "-v" }
        table["python3"] = interpreter; table["python"] = interpreter; table["node"] = interpreter
        table["curl"] = { args in
            !args.contains { ["-d", "--data", "--data-binary", "--data-raw", "--data-urlencode", "-F", "--form", "-T", "--upload-file", "-o", "--output", "-O", "--remote-name", "-X", "--request"].contains($0) || $0.hasPrefix("-d") && $0.count > 2 || $0.hasPrefix("-o") && $0.count > 2 }
        }
        table["wget"] = { args in args.contains("--spider") }
        return table
    }()

    private static func firstVerb(_ args: [String]) -> String {
        args.first { !$0.hasPrefix("-") } ?? ""
    }

    /// True when every part of the command only inspects the host.
    public static func isReadOnly(_ command: String) -> Bool {
        var text = normalizedForScan(command)
        // Anything that can run arbitrary code or write files disqualifies the whole line.
        if text.contains("$(") || text.contains("`") || text.contains("<(") || text.contains(">(") { return false }
        if text.contains(">") { return false }
        text = text.replacingOccurrences(of: "\\\n", with: " ")
        let segments = text.split(whereSeparator: { "|;&\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !segments.isEmpty else { return false }
        for segment in segments where !segmentIsReadOnly(segment) { return false }
        return true
    }

    private static func segmentIsReadOnly(_ segment: String) -> Bool {
        var tokens = ShellWords.split(segment)
        // Leading environment assignments.
        while let first = tokens.first, first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
            tokens.removeFirst()
        }
        // Harmless wrappers.
        var wrapperPrintsEnvironment = false
        while let first = tokens.first {
            if first == "sudo" || first == "doas" {
                tokens.removeFirst()
                while let option = tokens.first, option.hasPrefix("-") {
                    tokens.removeFirst()
                    if ["-u", "-g", "-p", "-h", "-C", "-D", "-r", "-t", "-T", "-U"].contains(option), !tokens.isEmpty { tokens.removeFirst() }
                }
            } else if first == "env" || first == "nice" || first == "ionice" || first == "time" || first == "command" || first == "nohup" {
                wrapperPrintsEnvironment = first == "env"
                tokens.removeFirst()
                while let option = tokens.first, option.hasPrefix("-") || option.contains("=") && option.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
                    tokens.removeFirst()
                    if ["-n", "-c", "-p", "-u"].contains(option), !tokens.isEmpty { tokens.removeFirst() }
                }
            } else if first == "timeout" {
                tokens.removeFirst()
                while let option = tokens.first, option.hasPrefix("-") { tokens.removeFirst(); if ["-s", "-k"].contains(option), !tokens.isEmpty { tokens.removeFirst() } }
                if !tokens.isEmpty { tokens.removeFirst() } // the duration
            } else {
                break
            }
        }
        // A bare `env` (possibly with assignments) prints the environment.
        guard let first = tokens.first else { return wrapperPrintsEnvironment }
        let name = (first as NSString).lastPathComponent
        guard let entry = readOnlyCommands[name] else { return false }
        let args = Array(tokens.dropFirst())
        if let rule = entry { return rule(args) }
        return true
    }

    // MARK: Allowlist

    /// The allowlist pattern the command matches, if any. Patterns are globs
    /// (`*` any text, `?` one character) matched against the whole command,
    /// or regular expressions written as `/pattern/`.
    public static func allowlistMatch(_ command: String, patterns: [String]) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in patterns {
            let candidate = pattern.trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, !candidate.hasPrefix("#") else { continue }
            guard let regex = regex(forPattern: candidate) else { continue }
            if regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                return pattern
            }
        }
        return nil
    }

    static func regex(forPattern pattern: String) -> NSRegularExpression? {
        if pattern.count >= 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            let body = String(pattern.dropFirst().dropLast())
            return try? NSRegularExpression(pattern: "^(?:\(body))$", options: [.dotMatchesLineSeparators])
        }
        var out = "^"
        for character in pattern {
            switch character {
            case "*": out += ".*"
            case "?": out += "."
            default: out += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        out += "$"
        return try? NSRegularExpression(pattern: out, options: [.dotMatchesLineSeparators])
    }

    // MARK: Decision

    /// The verdict for a shell command on a host with the given mode.
    public static func decide(command: String, mode: AgentPermissionMode, allowlist: [String]) -> Verdict {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .deny("Empty command.") }
        let destructive = destructiveMatch(trimmed)
        let readOnly = destructive == nil && isReadOnly(trimmed)
        switch mode {
        case .readOnly:
            if readOnly { return .allow("on the read-only list") }
            if let destructive { return .deny("This host is read-only and the command is destructive (\(destructive)).") }
            return .deny("This host is read-only; only inspection commands such as ls, cat, grep, df, ps and systemctl status may run.")
        case .ask:
            if let destructive { return .ask("Destructive: \(destructive).") }
            return .ask(readOnly ? "Read-only command; this host asks for every command." : "This host asks for every command.")
        case .allowlist:
            if let destructive { return .ask("Destructive (\(destructive)); destructive commands always ask.") }
            if let pattern = allowlistMatch(trimmed, patterns: allowlist) { return .allow("matches allowlist pattern \(pattern)") }
            return .ask(readOnly ? "Read-only command, not on this host's allowlist." : "Not on this host's allowlist.")
        }
    }

    /// The verdict for an action that is not a shell command the user wrote,
    /// such as writing a file. `readOnly` says whether it only reads.
    public static func decide(action description: String, readOnly: Bool, mode: AgentPermissionMode, allowlist: [String]) -> Verdict {
        switch mode {
        case .readOnly:
            return readOnly ? .allow("read-only action") : .deny("This host is read-only; \(description) would change it.")
        case .ask:
            return .ask("This host asks for every action.")
        case .allowlist:
            if let pattern = allowlistMatch(description, patterns: allowlist) { return .allow("matches allowlist pattern \(pattern)") }
            return .ask("Not on this host's allowlist.")
        }
    }
}

/// Splits a shell segment into words, honouring quotes and backslashes.
public enum ShellWords {
    public static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                current.append(character); escaped = false; inWord = true; continue
            }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            switch character {
            case "\\": escaped = true; inWord = true
            case "\"", "'": quote = character; inWord = true
            case " ", "\t", "\n":
                if inWord { words.append(current); current = ""; inWord = false }
            default: current.append(character); inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// Single-quotes a string for a POSIX shell.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
