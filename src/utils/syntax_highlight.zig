const std = @import("std");

/// Syntax highlighting for shell commands
pub const SyntaxHighlighter = struct {
    allocator: std.mem.Allocator,

    // ANSI color codes
    const Color = struct {
        const RESET = "\x1b[0m";
        const GREEN = "\x1b[32m";      // Valid commands
        const BLUE = "\x1b[34m";       // Builtins
        const CYAN = "\x1b[36m";       // Flags/options
        const YELLOW = "\x1b[33m";     // Strings
        const MAGENTA = "\x1b[35m";    // Variables
        const RED = "\x1b[31m";        // Errors/invalid
        const GRAY = "\x1b[90m";       // Comments
        const BOLD_GREEN = "\x1b[1;32m"; // Commands (bold)
    };

    // Shell builtins for highlighting
    const builtins = [_][]const u8{
        "cd", "pwd", "echo", "exit", "env", "export", "set", "unset",
        "true", "false", "test", "[", "alias", "unalias", "which",
        "type", "help", "read", "printf", "source", ".", "history",
        "pushd", "popd", "dirs", "eval", "exec", "command", "builtin",
        "jobs", "fg", "bg", "wait", "disown", "kill", "trap", "times",
        "umask", "getopts", "clear", "time", "hash", "yes", "reload",
        "watch", "tree", "grep", "find", "calc", "json", "ls",
        "seq", "date", "parallel", "http", "base64", "uuid",
    };

    // Shell keywords
    const keywords = [_][]const u8{
        "if", "then", "else", "elif", "fi",
        "case", "esac",
        "for", "while", "until", "do", "done",
        "function", "in",
    };

    pub fn init(allocator: std.mem.Allocator) SyntaxHighlighter {
        return .{ .allocator = allocator };
    }

    /// Apply syntax highlighting to a command line
    pub fn highlight(self: *SyntaxHighlighter, line: []const u8) ![]const u8 {
        if (line.len == 0) return try self.allocator.dupe(u8, line);

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        var pos: usize = 0;
        var in_string: bool = false;
        var string_char: u8 = 0;
        var in_comment: bool = false;
        var word_start: ?usize = null;
        var is_first_word: bool = true;

        while (pos < line.len) {
            const c = line[pos];

            // Handle comments
            if (c == '#' and !in_string) {
                in_comment = true;
                try result.appendSlice(self.allocator, Color.GRAY);
                try result.append(self.allocator, c);
                pos += 1;
                continue;
            }

            if (in_comment) {
                try result.append(self.allocator, c);
                pos += 1;
                continue;
            }

            // Handle strings
            if ((c == '"' or c == '\'') and !in_string) {
                in_string = true;
                string_char = c;
                try result.appendSlice(self.allocator, Color.YELLOW);
                try result.append(self.allocator, c);
                pos += 1;
                continue;
            } else if (in_string and c == string_char) {
                try result.append(self.allocator, c);
                try result.appendSlice(self.allocator, Color.RESET);
                in_string = false;
                pos += 1;
                continue;
            } else if (in_string) {
                try result.append(self.allocator, c);
                pos += 1;
                continue;
            }

            // Handle variables
            if (c == '$') {
                try result.appendSlice(self.allocator, Color.MAGENTA);
                try result.append(self.allocator, c);
                pos += 1;

                // Read variable name
                if (pos < line.len and line[pos] == '{') {
                    try result.append(self.allocator, line[pos]);
                    pos += 1;
                    while (pos < line.len and line[pos] != '}') {
                        try result.append(self.allocator, line[pos]);
                        pos += 1;
                    }
                    if (pos < line.len) {
                        try result.append(self.allocator, line[pos]);
                        pos += 1;
                    }
                } else {
                    while (pos < line.len and (std.ascii.isAlphanumeric(line[pos]) or line[pos] == '_')) {
                        try result.append(self.allocator, line[pos]);
                        pos += 1;
                    }
                }
                try result.appendSlice(self.allocator, Color.RESET);
                continue;
            }

            // Handle flags (- or --)
            if (c == '-' and word_start == null) {
                word_start = pos;
                try result.appendSlice(self.allocator, Color.CYAN);
                try result.append(self.allocator, c);
                pos += 1;

                // Read the rest of the flag
                while (pos < line.len and !std.ascii.isWhitespace(line[pos])) {
                    try result.append(self.allocator, line[pos]);
                    pos += 1;
                }
                try result.appendSlice(self.allocator, Color.RESET);
                word_start = null;
                continue;
            }

            // Handle word boundaries
            if (std.ascii.isWhitespace(c) or c == '|' or c == '&' or c == ';' or c == '(' or c == ')') {
                // End of word - check if it was a command/keyword/builtin
                if (word_start) |start| {
                    const word = line[start..pos];
                    if (is_first_word) {
                        if (self.isBuiltin(word)) {
                            try result.appendSlice(self.allocator, Color.BLUE);
                        } else if (self.isKeyword(word)) {
                            try result.appendSlice(self.allocator, Color.BLUE);
                        } else {
                            try result.appendSlice(self.allocator, Color.BOLD_GREEN);
                        }
                        try result.appendSlice(self.allocator, word);
                        try result.appendSlice(self.allocator, Color.RESET);
                        is_first_word = false;
                    } else {
                        try result.appendSlice(self.allocator, word);
                    }
                    word_start = null;
                }

                try result.append(self.allocator, c);
                if (c == '|' or c == '&' or c == ';') {
                    is_first_word = true;
                }
                pos += 1;
                continue;
            }

            // Start of a new word
            if (word_start == null) {
                word_start = pos;
            }

            pos += 1;
        }

        // Handle final word
        if (word_start) |start| {
            const word = line[start..];
            if (is_first_word) {
                if (self.isBuiltin(word)) {
                    try result.appendSlice(self.allocator, Color.BLUE);
                } else if (self.isKeyword(word)) {
                    try result.appendSlice(self.allocator, Color.BLUE);
                } else {
                    try result.appendSlice(self.allocator, Color.BOLD_GREEN);
                }
                try result.appendSlice(self.allocator, word);
                try result.appendSlice(self.allocator, Color.RESET);
            } else {
                try result.appendSlice(self.allocator, word);
            }
        }

        // Add final reset if still in comment
        if (in_comment) {
            try result.appendSlice(self.allocator, Color.RESET);
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn isBuiltin(self: *SyntaxHighlighter, word: []const u8) bool {
        _ = self;
        for (builtins) |builtin| {
            if (std.mem.eql(u8, word, builtin)) {
                return true;
            }
        }
        return false;
    }

    fn isKeyword(self: *SyntaxHighlighter, word: []const u8) bool {
        _ = self;
        for (keywords) |keyword| {
            if (std.mem.eql(u8, word, keyword)) {
                return true;
            }
        }
        return false;
    }
};

test "syntax highlighting - basic command" {
    const allocator = std.testing.allocator;
    var highlighter = SyntaxHighlighter.init(allocator);

    const input = "ls -la /home";
    const output = try highlighter.highlight(input);
    defer allocator.free(output);

    // Should have color codes
    try std.testing.expect(output.len > input.len);
}

test "syntax highlighting - builtin" {
    const allocator = std.testing.allocator;
    var highlighter = SyntaxHighlighter.init(allocator);

    const input = "echo hello";
    const output = try highlighter.highlight(input);
    defer allocator.free(output);

    // Should have color codes for builtin
    try std.testing.expect(output.len > input.len);
}
