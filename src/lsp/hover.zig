const std = @import("std");

/// LSP Position (0-based line and character)
pub const Position = struct {
    line: u32,
    character: u32,
};

/// LSP Range
pub const Range = struct {
    start: Position,
    end: Position,
};

/// The result of a hover request -- markdown content and the range of the
/// token that was hovered.
pub const HoverResult = struct {
    contents: []const u8,
    range: Range,
    /// True when `contents` was heap-allocated and must be freed by the caller
    owned: bool = false,
};

// ---------------------------------------------------------------------------
// Built-in command documentation
// ---------------------------------------------------------------------------

const CommandDoc = struct {
    name: []const u8,
    summary: []const u8,
    usage: []const u8,
};

const command_docs = [_]CommandDoc{
    .{
        .name = "echo",
        .summary = "Print arguments to standard output.",
        .usage = "```den\necho \"Hello, world!\"\necho -n \"no newline\"\n```",
    },
    .{
        .name = "cd",
        .summary = "Change the current working directory.",
        .usage = "```den\ncd /path/to/dir\ncd ~\ncd -   # go to previous directory\n```",
    },
    .{
        .name = "ls",
        .summary = "List directory contents.",
        .usage = "```den\nls\nls -la /tmp\nls *.zig\n```",
    },
    .{
        .name = "grep",
        .summary = "Search for patterns in text.",
        .usage = "```den\ngrep \"pattern\" file.txt\nls | grep \".zig\"\ngrep -r \"TODO\" src/\n```",
    },
    .{
        .name = "seq",
        .summary = "Generate a numeric sequence.",
        .usage = "```den\nseq 1 10\nseq 0 2 20   # start step end\n```",
    },
    .{
        .name = "watch",
        .summary = "Execute a command periodically and display its output.",
        .usage = "```den\nwatch 2 \"date\"    # run date every 2 seconds\nwatch 1 \"ls -l\"\n```",
    },
    .{
        .name = "http",
        .summary = "HTTP client for making web requests.",
        .usage = "```den\nhttp get https://api.example.com/data\nhttp post https://api.example.com/data '{\"key\": \"value\"}'\nhttp put https://api.example.com/data --header \"Content-Type: application/json\"\n```",
    },
    .{
        .name = "str",
        .summary = "String manipulation commands.",
        .usage = "```den\nstr trim \"  hello  \"\nstr replace \"hello\" \"world\" \"hello there\"\nstr split \",\" \"a,b,c\"\nstr upper \"hello\"    # HELLO\nstr lower \"HELLO\"    # hello\nstr length \"hello\"   # 5\n```",
    },
    .{
        .name = "path",
        .summary = "Path manipulation commands.",
        .usage = "```den\npath join \"/home\" \"user\" \"file.txt\"\npath dirname \"/home/user/file.txt\"   # /home/user\npath basename \"/home/user/file.txt\"  # file.txt\npath extension \"file.tar.gz\"          # .gz\npath exists \"/tmp\"                    # true\n```",
    },
    .{
        .name = "math",
        .summary = "Mathematical operations.",
        .usage = "```den\nmath sum 1 2 3 4       # 10\nmath avg 10 20 30      # 20\nmath sqrt 144          # 12\nmath pow 2 8           # 256\nmath round 3.7         # 4\n```",
    },
    .{
        .name = "date",
        .summary = "Date and time operations.",
        .usage = "```den\ndate now\ndate format \"%Y-%m-%d\"\ndate add 1d             # add one day\ndate diff \"2024-01-01\" \"2024-12-31\"\n```",
    },
    .{
        .name = "pwd",
        .summary = "Print the current working directory.",
        .usage = "```den\npwd\n```",
    },
    .{
        .name = "exit",
        .summary = "Exit the shell with an optional status code.",
        .usage = "```den\nexit\nexit 1\n```",
    },
    .{
        .name = "export",
        .summary = "Set an environment variable.",
        .usage = "```den\nexport MY_VAR=\"hello\"\nexport PATH=\"$HOME/bin:$PATH\"\n```",
    },
    .{
        .name = "source",
        .summary = "Execute commands from a file in the current shell.",
        .usage = "```den\nsource ~/.denrc\nsource ./setup.den\n```",
    },
    .{
        .name = "alias",
        .summary = "Define or display command aliases.",
        .usage = "```den\nalias ll=\"ls -la\"\nalias gs=\"git status\"\nalias       # show all aliases\n```",
    },
    .{
        .name = "read",
        .summary = "Read a line from standard input into a variable.",
        .usage = "```den\nread name\necho \"Hello, $name\"\nread -p \"Enter value: \" val\n```",
    },
    .{
        .name = "printf",
        .summary = "Format and print data.",
        .usage = "```den\nprintf \"%s has %d items\\n\" \"list\" 5\nprintf \"%.2f\\n\" 3.14159\n```",
    },
    .{
        .name = "jobs",
        .summary = "List active background jobs.",
        .usage = "```den\njobs\n```",
    },
    .{
        .name = "fg",
        .summary = "Move a background job to the foreground.",
        .usage = "```den\nfg %1\n```",
    },
    .{
        .name = "bg",
        .summary = "Resume a suspended job in the background.",
        .usage = "```den\nbg %1\n```",
    },
    .{
        .name = "kill",
        .summary = "Send a signal to a process.",
        .usage = "```den\nkill 1234\nkill -9 1234\nkill -SIGTERM %1\n```",
    },
    .{
        .name = "history",
        .summary = "Display the command history.",
        .usage = "```den\nhistory\nhistory 20      # last 20 commands\n```",
    },
    .{
        .name = "test",
        .summary = "Evaluate a conditional expression.",
        .usage = "```den\ntest -f /etc/passwd && echo \"exists\"\ntest \"$x\" = \"hello\"\n```",
    },
    .{
        .name = "true",
        .summary = "Do nothing, successfully (exit status 0).",
        .usage = "```den\ntrue\nwhile true; do ...; done\n```",
    },
    .{
        .name = "false",
        .summary = "Do nothing, unsuccessfully (exit status 1).",
        .usage = "```den\nfalse\nif false; then ...; fi\n```",
    },
    .{
        .name = "set",
        .summary = "Set or display shell options and positional parameters.",
        .usage = "```den\nset -e          # exit on error\nset -x          # print commands before execution\nset +x          # disable command tracing\n```",
    },
    .{
        .name = "unset",
        .summary = "Unset a shell variable or function.",
        .usage = "```den\nunset MY_VAR\nunset -f my_function\n```",
    },
    .{
        .name = "type",
        .summary = "Display information about a command type.",
        .usage = "```den\ntype ls      # ls is /bin/ls\ntype cd      # cd is a shell builtin\n```",
    },
    .{
        .name = "which",
        .summary = "Locate a command on the filesystem.",
        .usage = "```den\nwhich python\nwhich -a node\n```",
    },
    .{
        .name = "wait",
        .summary = "Wait for background processes to finish.",
        .usage = "```den\nwait\nwait %1\nwait 1234\n```",
    },
    .{
        .name = "help",
        .summary = "Display help information for den commands.",
        .usage = "```den\nhelp\nhelp cd\n```",
    },
};

// ---------------------------------------------------------------------------
// Keyword documentation
// ---------------------------------------------------------------------------

const KeywordDoc = struct {
    name: []const u8,
    summary: []const u8,
};

const keyword_docs = [_]KeywordDoc{
    .{ .name = "if", .summary = "**if** -- Conditional branch. Executes a block if the condition succeeds.\n\n```den\nif condition\nthen\n  ...\nfi\n```" },
    .{ .name = "else", .summary = "**else** -- Alternative branch executed when the preceding `if` / `elif` condition is false." },
    .{ .name = "elif", .summary = "**elif** -- Additional conditional branch inside an `if` block." },
    .{ .name = "fi", .summary = "**fi** -- Closes an `if` block." },
    .{ .name = "for", .summary = "**for** -- Iterate over a list of values.\n\n```den\nfor item in a b c\ndo\n  echo $item\ndone\n```" },
    .{ .name = "while", .summary = "**while** -- Loop while a condition is true.\n\n```den\nwhile condition\ndo\n  ...\ndone\n```" },
    .{ .name = "do", .summary = "**do** -- Begins the body of a `for`, `while`, or `until` loop." },
    .{ .name = "done", .summary = "**done** -- Closes the body of a `for`, `while`, or `until` loop." },
    .{ .name = "match", .summary = "**match** -- Pattern matching expression. Matches a value against multiple patterns." },
    .{ .name = "try", .summary = "**try** -- Begin an error-handling block. Errors can be caught by a following `catch`." },
    .{ .name = "catch", .summary = "**catch** -- Handle errors raised inside the preceding `try` block." },
    .{ .name = "let", .summary = "**let** -- Declare an immutable variable.\n\n```den\nlet name = \"den\"\n```" },
    .{ .name = "mut", .summary = "**mut** -- Declare a mutable variable.\n\n```den\nmut count = 0\n```" },
    .{ .name = "module", .summary = "**module** -- Define a named module that groups related functions and variables." },
    .{ .name = "use", .summary = "**use** -- Import a module into the current scope.\n\n```den\nuse math\nuse ./helpers.den\n```" },
    .{ .name = "def", .summary = "**def** -- Define a function.\n\n```den\ndef greet(name) {\n  echo \"Hello, $name!\"\n}\n```" },
    .{ .name = "return", .summary = "**return** -- Return a value from a function." },
    .{ .name = "break", .summary = "**break** -- Exit the innermost loop immediately." },
    .{ .name = "continue", .summary = "**continue** -- Skip to the next iteration of the innermost loop." },
    .{ .name = "in", .summary = "**in** -- Used with `for` to separate the variable name from the value list." },
    .{ .name = "then", .summary = "**then** -- Begins the body of an `if` or `elif` clause." },
    .{ .name = "case", .summary = "**case** -- Pattern-based conditional.\n\n```den\ncase $val in\n  a) echo \"alpha\" ;;\n  b) echo \"beta\" ;;\nesac\n```" },
    .{ .name = "esac", .summary = "**esac** -- Closes a `case` statement." },
};

// ---------------------------------------------------------------------------
// Variable documentation
// ---------------------------------------------------------------------------

const VariableDoc = struct {
    name: []const u8,
    summary: []const u8,
};

const variable_docs = [_]VariableDoc{
    .{ .name = "$HOME", .summary = "**$HOME** (string) -- Home directory of the current user." },
    .{ .name = "$PATH", .summary = "**$PATH** (string) -- Colon-separated list of directories to search for executables." },
    .{ .name = "$PWD", .summary = "**$PWD** (string) -- The present working directory." },
    .{ .name = "$USER", .summary = "**$USER** (string) -- The name of the logged-in user." },
    .{ .name = "$SHELL", .summary = "**$SHELL** (string) -- Path to the current shell binary." },
    .{ .name = "$OLDPWD", .summary = "**$OLDPWD** (string) -- The previous working directory (set by `cd`)." },
    .{ .name = "$TERM", .summary = "**$TERM** (string) -- The terminal type." },
    .{ .name = "$LANG", .summary = "**$LANG** (string) -- The current locale setting." },
    .{ .name = "$EDITOR", .summary = "**$EDITOR** (string) -- The default text editor." },
    .{ .name = "$?", .summary = "**$?** (integer) -- Exit status of the most recently executed foreground command." },
    .{ .name = "$!", .summary = "**$!** (integer) -- PID of the most recently backgrounded process." },
    .{ .name = "$$", .summary = "**$$** (integer) -- PID of the current shell process." },
    .{ .name = "$#", .summary = "**$#** (integer) -- Number of positional parameters." },
    .{ .name = "$@", .summary = "**$@** (list) -- All positional parameters, each as a separate word." },
    .{ .name = "$*", .summary = "**$*** (string) -- All positional parameters joined into a single word." },
    .{ .name = "$0", .summary = "**$0** (string) -- The name of the shell or script." },
    .{ .name = "$DEN_VERSION", .summary = "**$DEN_VERSION** (string) -- The version of the Den shell." },
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Return hover information for the token under the cursor, or `null` if
/// there is nothing to show.
///
/// When non-null and `owned` is true the caller must free `contents` via
/// `allocator`.
pub fn getHoverInfo(
    document_text: []const u8,
    position: Position,
    allocator: std.mem.Allocator,
) !?HoverResult {
    const line_text = getLineAt(document_text, position.line);
    const word_range = getWordRangeAt(line_text, position.character);
    if (word_range.start == word_range.end) return null;

    const word = line_text[word_range.start..word_range.end];

    const range = Range{
        .start = .{ .line = position.line, .character = @intCast(word_range.start) },
        .end = .{ .line = position.line, .character = @intCast(word_range.end) },
    };

    // Check if it is a $-variable
    if (word.len > 0 and word[0] == '$') {
        for (&variable_docs) |*vd| {
            if (std.mem.eql(u8, vd.name, word)) {
                return HoverResult{
                    .contents = vd.summary,
                    .range = range,
                };
            }
        }
        // Special two-char variables like $$
        if (word.len >= 2) {
            const short = word[0..2];
            for (&variable_docs) |*vd| {
                if (std.mem.eql(u8, vd.name, short)) {
                    return HoverResult{
                        .contents = vd.summary,
                        .range = range,
                    };
                }
            }
        }
    }

    // Check keywords
    for (&keyword_docs) |*kd| {
        if (std.mem.eql(u8, kd.name, word)) {
            return HoverResult{
                .contents = kd.summary,
                .range = range,
            };
        }
    }

    // Check built-in commands
    for (&command_docs) |*cd| {
        if (std.mem.eql(u8, cd.name, word)) {
            const hover_text = try std.fmt.allocPrint(
                allocator,
                "**{s}** -- {s}\n\n{s}",
                .{ cd.name, cd.summary, cd.usage },
            );
            return HoverResult{
                .contents = hover_text,
                .range = range,
                .owned = true,
            };
        }
    }

    return null;
}

/// Free a `HoverResult` if its content was heap-allocated.
pub fn freeHoverResult(result: HoverResult, allocator: std.mem.Allocator) void {
    if (result.owned) {
        allocator.free(result.contents);
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const WordRange = struct { start: usize, end: usize };

/// Find the start and end byte offsets of the word at the given column.
fn getWordRangeAt(line: []const u8, col: u32) WordRange {
    if (line.len == 0) return .{ .start = 0, .end = 0 };

    const c: usize = @min(col, @as(u32, @intCast(line.len)));

    // Walk backwards to find the start of the word
    var start: usize = c;
    while (start > 0 and isWordChar(line[start - 1])) {
        start -= 1;
    }

    // Walk forwards to find the end
    var end: usize = c;
    while (end < line.len and isWordChar(line[end])) {
        end += 1;
    }

    return .{ .start = start, .end = end };
}

fn isWordChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '$', '?', '!', '#', '@', '*' => true,
        else => false,
    };
}

/// Get the contents of a specific line (0-based) from document text.
fn getLineAt(text: []const u8, line: u32) []const u8 {
    var current_line: u32 = 0;
    var start: usize = 0;
    for (text, 0..) |c, idx| {
        if (c == '\n') {
            if (current_line == line) {
                return text[start..idx];
            }
            current_line += 1;
            start = idx + 1;
        }
    }
    if (current_line == line) {
        return text[start..];
    }
    return "";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "hover on echo returns command doc" {
    const doc = "echo hello";
    const result = try getHoverInfo(doc, .{ .line = 0, .character = 2 }, std.testing.allocator);
    try std.testing.expect(result != null);
    if (result) |r| {
        defer freeHoverResult(r, std.testing.allocator);
        try std.testing.expect(std.mem.startsWith(u8, r.contents, "**echo**"));
    }
}

test "hover on keyword returns doc" {
    const doc = "if true";
    const result = try getHoverInfo(doc, .{ .line = 0, .character = 1 }, std.testing.allocator);
    try std.testing.expect(result != null);
    if (result) |r| {
        defer freeHoverResult(r, std.testing.allocator);
        try std.testing.expect(std.mem.startsWith(u8, r.contents, "**if**"));
    }
}

test "hover on variable returns doc" {
    const doc = "echo $HOME";
    const result = try getHoverInfo(doc, .{ .line = 0, .character = 7 }, std.testing.allocator);
    try std.testing.expect(result != null);
    if (result) |r| {
        defer freeHoverResult(r, std.testing.allocator);
        try std.testing.expect(std.mem.startsWith(u8, r.contents, "**$HOME**"));
    }
}

test "hover on unknown word returns null" {
    const doc = "somethingRandom";
    const result = try getHoverInfo(doc, .{ .line = 0, .character = 3 }, std.testing.allocator);
    try std.testing.expectEqual(@as(?HoverResult, null), result);
}
