import Foundation

/// What the destination app wants a paste to look like.
///
/// This is a local lookup rather than something we ask the model, for two
/// reasons: it costs nothing, and it lets the preview panel show an accurate
/// "Table → TSV for Numbers" label the instant the hotkey fires, before a single
/// token has streamed back.
struct Destination {
    /// Shown in the preview panel header.
    let label: String
    /// Appended to the prompt as the concrete formatting target.
    let guidance: String

    static func profile(for context: AppContext) -> Destination {
        let title = (context.windowTitle ?? "").lowercased()

        switch context.bundleID {
        case "com.apple.Numbers", "com.microsoft.Excel":
            return spreadsheet

        case "com.tinyspeck.slackmacgap", "com.hnc.Discord",
             "net.whatsapp.WhatsApp", "com.apple.MobileSMS", "ru.keepcoder.Telegram":
            return chat

        case "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
             "com.github.wez.wezterm", "net.kovidgoyal.kitty":
            return shell

        case "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.sublimetext.4",
             "com.jetbrains.intellij", "com.jetbrains.pycharm", "dev.zed.Zed":
            return code(languageHint: languageHint(fromTitle: title))

        case "com.apple.mail", "com.readdle.SparkDesktop", "com.superhuman.electron":
            return email

        case "com.apple.Notes", "notion.id", "md.obsidian", "com.apple.TextEdit":
            return notes

        default:
            // Browsers are the ambiguous case — the window title is the only
            // clue about what web app is actually focused.
            if title.contains("google sheets") || title.contains("airtable") {
                return spreadsheet
            }
            if title.contains("gmail") || title.contains("outlook") {
                return email
            }
            if title.contains("github") || title.contains("gitlab")
                || title.contains("linear") || title.contains("notion") {
                return markdown
            }
            return general
        }
    }

    // MARK: - Profiles

    static let spreadsheet = Destination(
        label: "→ spreadsheet cells",
        guidance: """
        The destination is a spreadsheet. Emit tab-separated values with one row \
        per line and no surrounding prose, header rules, or markdown pipes, so it \
        lands as real cells. Keep the header row if the source had one. Strip \
        currency symbols and thousands separators from numeric columns so they \
        stay numeric; leave the unit in the column header instead.
        """)

    static let chat = Destination(
        label: "→ chat message",
        guidance: """
        The destination is a chat app. Emit compact, readable plain text. Convert \
        tables into short labelled lines rather than aligned columns, since the \
        font is proportional. Keep any URLs bare. Do not add a greeting, a \
        sign-off, or an explanation of what you did.
        """)

    static let shell = Destination(
        label: "→ shell-safe",
        guidance: """
        The destination is a terminal. Emit exactly one line unless the content is \
        genuinely a multi-line script, because a newline in a shell executes the \
        command. Quote and escape anything that the shell would otherwise expand: \
        spaces, quotes, backticks, $, and glob characters. Strip leading prompt \
        markers such as `$ ` or `% ` that were copied along with a command.
        """)

    static func code(languageHint: String?) -> Destination {
        let target = languageHint.map { "The file appears to be \($0)." } ?? ""
        return Destination(
            label: languageHint.map { "→ \($0) literal" } ?? "→ code",
            guidance: """
            The destination is a code editor. \(target) If the clipboard holds \
            structured data (a table, a list, key-value pairs), emit it as a \
            literal in that language — an array of objects, a dict, a struct — \
            using the file's conventions for quoting and indentation. If it holds \
            prose, emit it as a comment in that language's comment syntax. Emit \
            only the code, with no markdown fence around it.
            """)
    }

    static let email = Destination(
        label: "→ email body",
        guidance: """
        The destination is an email composer. Emit clean prose paragraphs. Keep \
        tables as tables but format them as plain aligned text, not markdown. Do \
        not invent a subject line, a greeting, or a signature.
        """)

    static let notes = Destination(
        label: "→ notes",
        guidance: """
        The destination is a note-taking app. Preserve the structure of the source \
        — headings, lists, and tables stay headings, lists, and tables — but strip \
        web page furniture such as navigation text, cookie notices, "share this" \
        prompts, and footnote markers with no matching footnote.
        """)

    static let markdown = Destination(
        label: "→ markdown",
        guidance: """
        The destination renders markdown. Emit well-formed markdown: real tables \
        with pipes, fenced code blocks with a language tag where the language is \
        evident, and reference-free inline links.
        """)

    static let general = Destination(
        label: "→ clean text",
        guidance: """
        The destination is a general text field. Emit clean, readable plain text. \
        Fix whitespace mangled by the copy — hard-wrapped lines rejoined into \
        paragraphs, PDF column bleed separated, repeated blank lines collapsed. \
        Preserve the meaning and wording exactly; this is a reformat, not a rewrite.
        """)

    // MARK: - Helpers

    private static func languageHint(fromTitle title: String) -> String? {
        let extensions: [String: String] = [
            ".swift": "Swift", ".py": "Python", ".ts": "TypeScript", ".tsx": "TypeScript",
            ".js": "JavaScript", ".jsx": "JavaScript", ".go": "Go", ".rs": "Rust",
            ".java": "Java", ".rb": "Ruby", ".c": "C", ".cpp": "C++", ".cs": "C#",
            ".php": "PHP", ".kt": "Kotlin", ".sql": "SQL", ".json": "JSON",
            ".yaml": "YAML", ".yml": "YAML", ".sh": "shell", ".dart": "Dart"
        ]
        for (ext, name) in extensions where title.contains(ext) {
            return name
        }
        return nil
    }
}
