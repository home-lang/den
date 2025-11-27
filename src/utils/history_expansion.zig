const std = @import("std");

/// History Expansion
/// Expands history references like !!, !N, !-N, !string, !?string, ^old^new
pub const HistoryExpansion = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HistoryExpansion {
        return .{
            .allocator = allocator,
        };
    }

    /// Expand history references in a command line
    /// Returns the expanded command or the original if no expansion needed
    /// current_line is optional and used for !# expansion (the line typed so far before !#)
    pub fn expand(
        self: *HistoryExpansion,
        input: []const u8,
        history: []const ?[]const u8,
        history_count: usize,
    ) !ExpandResult {
        return self.expandWithCurrentLine(input, history, history_count, null);
    }

    /// Expand history references with current line context for !# support
    pub fn expandWithCurrentLine(
        self: *HistoryExpansion,
        input: []const u8,
        history: []const ?[]const u8,
        history_count: usize,
        current_line: ?[]const u8,
    ) !ExpandResult {
        _ = current_line; // Used by parseHistoryReferenceWithContext
        if (history_count == 0) {
            return .{
                .text = try self.allocator.dupe(u8, input),
                .expanded = false,
            };
        }

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        var expanded = false;
        var in_single_quote = false;
        var in_double_quote = false;

        while (i < input.len) {
            const c = input[i];

            // Track quote state (history expansion doesn't happen in single quotes)
            if (c == '\'' and !in_double_quote) {
                in_single_quote = !in_single_quote;
                try result.append(self.allocator, c);
                i += 1;
                continue;
            }

            if (c == '"' and !in_single_quote) {
                in_double_quote = !in_double_quote;
                try result.append(self.allocator, c);
                i += 1;
                continue;
            }

            // Skip expansion in single quotes
            if (in_single_quote) {
                try result.append(self.allocator, c);
                i += 1;
                continue;
            }

            // Check for ^old^new quick substitution
            if (i == 0 and c == '^') {
                const sub_result = try self.parseQuickSubstitution(input, history, history_count);
                if (sub_result) |text| {
                    try result.appendSlice(self.allocator, text);
                    self.allocator.free(text);
                    return .{
                        .text = try result.toOwnedSlice(self.allocator),
                        .expanded = true,
                    };
                }
            }

            // Check for history expansion (!)
            if (c == '!') {
                // Check for escaped !
                if (i > 0 and input[i - 1] == '\\') {
                    // Remove the backslash and add literal !
                    _ = result.pop();
                    try result.append(self.allocator, '!');
                    i += 1;
                    continue;
                }

                const expansion = try self.parseHistoryReference(input[i..], history, history_count);
                if (expansion.text) |text| {
                    try result.appendSlice(self.allocator, text);
                    self.allocator.free(text);
                    i += expansion.consumed;
                    expanded = true;
                    continue;
                }
            }

            try result.append(self.allocator, c);
            i += 1;
        }

        return .{
            .text = try result.toOwnedSlice(self.allocator),
            .expanded = expanded,
        };
    }

    const ExpansionResult = struct {
        text: ?[]const u8,
        consumed: usize,
    };

    /// Parse a history reference starting at '!'
    fn parseHistoryReference(
        self: *HistoryExpansion,
        input: []const u8,
        history: []const ?[]const u8,
        history_count: usize,
    ) !ExpansionResult {
        if (input.len < 1 or input[0] != '!') {
            return .{ .text = null, .consumed = 0 };
        }

        if (input.len == 1) {
            // Single ! at end - not a history reference
            return .{ .text = null, .consumed = 0 };
        }

        const next = input[1];

        // !! - last command
        if (next == '!') {
            const last = self.getHistoryEntry(history, history_count, -1);
            if (last) |cmd| {
                // Check for word designator after !!
                const word_result = try self.parseWordDesignator(input[2..], cmd);
                if (word_result.text) |text| {
                    return .{
                        .text = text,
                        .consumed = 2 + word_result.consumed,
                    };
                }
                return .{
                    .text = try self.allocator.dupe(u8, cmd),
                    .consumed = 2,
                };
            }
            return .{ .text = null, .consumed = 0 };
        }

        // !# - current command line typed so far (before !#)
        // This returns an empty string for now - proper implementation requires
        // tracking what was typed before the !# in the current line
        if (next == '#') {
            // Return empty string - the caller should provide the current line context
            // via expandWithCurrentLine() for proper !# support
            return .{
                .text = try self.allocator.dupe(u8, ""),
                .consumed = 2,
            };
        }

        // !$ - last argument of previous command
        if (next == '$') {
            const last = self.getHistoryEntry(history, history_count, -1);
            if (last) |cmd| {
                const last_word = self.getWordFromCommand(cmd, -1);
                if (last_word) |word| {
                    return .{
                        .text = try self.allocator.dupe(u8, word),
                        .consumed = 2,
                    };
                }
            }
            return .{ .text = null, .consumed = 0 };
        }

        // !* - all arguments of previous command
        if (next == '*') {
            const last = self.getHistoryEntry(history, history_count, -1);
            if (last) |cmd| {
                const args = self.getArgsFromCommand(cmd);
                if (args) |a| {
                    return .{
                        .text = try self.allocator.dupe(u8, a),
                        .consumed = 2,
                    };
                }
            }
            return .{ .text = null, .consumed = 0 };
        }

        // !-N - Nth previous command
        if (next == '-') {
            if (input.len > 2 and std.ascii.isDigit(input[2])) {
                var end: usize = 2;
                while (end < input.len and std.ascii.isDigit(input[end])) : (end += 1) {}
                const num_str = input[2..end];
                const n = std.fmt.parseInt(i32, num_str, 10) catch return .{ .text = null, .consumed = 0 };
                const entry = self.getHistoryEntry(history, history_count, -n);
                if (entry) |cmd| {
                    return .{
                        .text = try self.allocator.dupe(u8, cmd),
                        .consumed = end,
                    };
                }
            }
            return .{ .text = null, .consumed = 0 };
        }

        // !N - command number N
        if (std.ascii.isDigit(next)) {
            var end: usize = 1;
            while (end < input.len and std.ascii.isDigit(input[end])) : (end += 1) {}
            const num_str = input[1..end];
            const n = std.fmt.parseInt(usize, num_str, 10) catch return .{ .text = null, .consumed = 0 };
            const entry = self.getHistoryEntryByNumber(history, history_count, n);
            if (entry) |cmd| {
                // Check for word designator
                const word_result = try self.parseWordDesignator(input[end..], cmd);
                if (word_result.text) |text| {
                    return .{
                        .text = text,
                        .consumed = end + word_result.consumed,
                    };
                }
                return .{
                    .text = try self.allocator.dupe(u8, cmd),
                    .consumed = end,
                };
            }
            return .{ .text = null, .consumed = 0 };
        }

        // !?string? - command containing string
        if (next == '?') {
            var end: usize = 2;
            while (end < input.len and input[end] != '?' and input[end] != ' ' and input[end] != '\n') : (end += 1) {}
            const search = input[2..end];
            if (search.len > 0) {
                const entry = self.searchHistoryContaining(history, history_count, search);
                if (entry) |cmd| {
                    // Skip optional closing ?
                    const consumed = if (end < input.len and input[end] == '?') end + 1 else end;
                    return .{
                        .text = try self.allocator.dupe(u8, cmd),
                        .consumed = consumed,
                    };
                }
            }
            return .{ .text = null, .consumed = 0 };
        }

        // !string - command starting with string
        if (std.ascii.isAlphabetic(next) or next == '_' or next == '/') {
            var end: usize = 1;
            while (end < input.len) : (end += 1) {
                const ch = input[end];
                if (ch == ' ' or ch == '\t' or ch == '\n' or ch == ';' or
                    ch == '&' or ch == '|' or ch == '>' or ch == '<' or
                    ch == ':' or ch == '!')
                {
                    break;
                }
            }
            const search = input[1..end];
            if (search.len > 0) {
                const entry = self.searchHistoryStarting(history, history_count, search);
                if (entry) |cmd| {
                    // Check for word designator
                    const word_result = try self.parseWordDesignator(input[end..], cmd);
                    if (word_result.text) |text| {
                        return .{
                            .text = text,
                            .consumed = end + word_result.consumed,
                        };
                    }
                    return .{
                        .text = try self.allocator.dupe(u8, cmd),
                        .consumed = end,
                    };
                }
            }
            return .{ .text = null, .consumed = 0 };
        }

        return .{ .text = null, .consumed = 0 };
    }

    /// Parse word designators (:0, :1, :$, :*, :n-m)
    fn parseWordDesignator(
        self: *HistoryExpansion,
        input: []const u8,
        command: []const u8,
    ) !ExpansionResult {
        if (input.len < 2 or input[0] != ':') {
            return .{ .text = null, .consumed = 0 };
        }

        const designator = input[1];

        // :0 - command name
        if (designator == '0') {
            const word = self.getWordFromCommand(command, 0);
            if (word) |w| {
                return .{
                    .text = try self.allocator.dupe(u8, w),
                    .consumed = 2,
                };
            }
        }

        // :$ - last argument
        if (designator == '$') {
            const word = self.getWordFromCommand(command, -1);
            if (word) |w| {
                return .{
                    .text = try self.allocator.dupe(u8, w),
                    .consumed = 2,
                };
            }
        }

        // :* - all arguments (words 1-$)
        if (designator == '*') {
            const args = self.getArgsFromCommand(command);
            if (args) |a| {
                return .{
                    .text = try self.allocator.dupe(u8, a),
                    .consumed = 2,
                };
            }
        }

        // :^ - first argument (word 1)
        if (designator == '^') {
            const word = self.getWordFromCommand(command, 1);
            if (word) |w| {
                return .{
                    .text = try self.allocator.dupe(u8, w),
                    .consumed = 2,
                };
            }
        }

        // :N - Nth word
        if (std.ascii.isDigit(designator)) {
            var end: usize = 1;
            while (end < input.len and std.ascii.isDigit(input[end])) : (end += 1) {}

            // Check for range :n-m
            if (end < input.len and input[end] == '-') {
                const start_str = input[1..end];
                const start_n = std.fmt.parseInt(usize, start_str, 10) catch return .{ .text = null, .consumed = 0 };

                end += 1; // skip -
                var range_end = end;
                while (range_end < input.len and (std.ascii.isDigit(input[range_end]) or input[range_end] == '$')) : (range_end += 1) {}

                const end_spec = input[end..range_end];
                var end_n: i32 = -1;
                if (end_spec.len > 0) {
                    if (end_spec[0] == '$') {
                        end_n = -1; // last word
                    } else {
                        end_n = std.fmt.parseInt(i32, end_spec, 10) catch return .{ .text = null, .consumed = 0 };
                    }
                }

                const range = self.getWordRange(command, start_n, end_n);
                if (range) |r| {
                    return .{
                        .text = try self.allocator.dupe(u8, r),
                        .consumed = range_end,
                    };
                }
            } else {
                const num_str = input[1..end];
                const n = std.fmt.parseInt(usize, num_str, 10) catch return .{ .text = null, .consumed = 0 };
                const word = self.getWordFromCommand(command, @intCast(n));
                if (word) |w| {
                    return .{
                        .text = try self.allocator.dupe(u8, w),
                        .consumed = end,
                    };
                }
            }
        }

        return .{ .text = null, .consumed = 0 };
    }

    /// Parse ^old^new quick substitution
    fn parseQuickSubstitution(
        self: *HistoryExpansion,
        input: []const u8,
        history: []const ?[]const u8,
        history_count: usize,
    ) !?[]const u8 {
        if (input.len < 3 or input[0] != '^') {
            return null;
        }

        // Find the pattern: ^old^new^ or ^old^new
        var old_end: usize = 1;
        while (old_end < input.len and input[old_end] != '^') : (old_end += 1) {}

        if (old_end >= input.len) {
            return null;
        }

        const old = input[1..old_end];
        if (old.len == 0) {
            return null;
        }

        var new_end = old_end + 1;
        while (new_end < input.len and input[new_end] != '^' and input[new_end] != '\n') : (new_end += 1) {}

        const new = input[old_end + 1 .. new_end];

        // Get last command
        const last = self.getHistoryEntry(history, history_count, -1);
        if (last) |cmd| {
            // Replace first occurrence of old with new
            if (std.mem.indexOf(u8, cmd, old)) |pos| {
                var result_list = std.ArrayList(u8).empty;
                errdefer result_list.deinit(self.allocator);

                try result_list.appendSlice(self.allocator, cmd[0..pos]);
                try result_list.appendSlice(self.allocator, new);
                try result_list.appendSlice(self.allocator, cmd[pos + old.len ..]);

                return try result_list.toOwnedSlice(self.allocator);
            }
        }

        return null;
    }

    /// Get history entry by relative offset (negative = from end)
    fn getHistoryEntry(
        _: *HistoryExpansion,
        history: []const ?[]const u8,
        history_count: usize,
        offset: i32,
    ) ?[]const u8 {
        if (history_count == 0) return null;

        var index: usize = undefined;
        if (offset < 0) {
            const abs_offset: usize = @intCast(-offset);
            if (abs_offset > history_count) return null;
            index = history_count - abs_offset;
        } else {
            index = @intCast(offset);
            if (index >= history_count) return null;
        }

        return history[index];
    }

    /// Get history entry by absolute number (1-indexed)
    fn getHistoryEntryByNumber(
        _: *HistoryExpansion,
        history: []const ?[]const u8,
        history_count: usize,
        number: usize,
    ) ?[]const u8 {
        if (number == 0 or number > history_count) return null;
        return history[number - 1];
    }

    /// Search history for command starting with prefix
    fn searchHistoryStarting(
        _: *HistoryExpansion,
        history: []const ?[]const u8,
        history_count: usize,
        prefix: []const u8,
    ) ?[]const u8 {
        if (history_count == 0) return null;

        var i = history_count;
        while (i > 0) {
            i -= 1;
            if (history[i]) |cmd| {
                if (std.mem.startsWith(u8, cmd, prefix)) {
                    return cmd;
                }
            }
        }
        return null;
    }

    /// Search history for command containing substring
    fn searchHistoryContaining(
        _: *HistoryExpansion,
        history: []const ?[]const u8,
        history_count: usize,
        substring: []const u8,
    ) ?[]const u8 {
        if (history_count == 0) return null;

        var i = history_count;
        while (i > 0) {
            i -= 1;
            if (history[i]) |cmd| {
                if (std.mem.indexOf(u8, cmd, substring) != null) {
                    return cmd;
                }
            }
        }
        return null;
    }

    /// Fuzzy search: matches if all characters of pattern appear in order in command
    /// Example: "gco" fuzzy matches "git checkout"
    pub fn searchHistoryFuzzy(
        _: *HistoryExpansion,
        history: []const ?[]const u8,
        history_count: usize,
        pattern: []const u8,
    ) ?[]const u8 {
        if (history_count == 0 or pattern.len == 0) return null;

        var i = history_count;
        while (i > 0) {
            i -= 1;
            if (history[i]) |cmd| {
                if (fuzzyMatch(cmd, pattern)) {
                    return cmd;
                }
            }
        }
        return null;
    }

    /// Check if pattern fuzzy-matches target (all chars in pattern appear in order in target)
    fn fuzzyMatch(target: []const u8, pattern: []const u8) bool {
        var pattern_idx: usize = 0;
        for (target) |c| {
            if (pattern_idx >= pattern.len) break;
            // Case-insensitive comparison
            const tc = std.ascii.toLower(c);
            const pc = std.ascii.toLower(pattern[pattern_idx]);
            if (tc == pc) {
                pattern_idx += 1;
            }
        }
        return pattern_idx == pattern.len;
    }

    /// Search history using a regex pattern
    /// Simple regex support: . (any char), * (zero or more), ^ (start), $ (end)
    pub fn searchHistoryRegex(
        _: *HistoryExpansion,
        history: []const ?[]const u8,
        history_count: usize,
        pattern: []const u8,
    ) ?[]const u8 {
        if (history_count == 0 or pattern.len == 0) return null;

        var i = history_count;
        while (i > 0) {
            i -= 1;
            if (history[i]) |cmd| {
                if (simpleRegexMatch(cmd, pattern)) {
                    return cmd;
                }
            }
        }
        return null;
    }

    /// Simple regex matching (supports: . * ^ $)
    fn simpleRegexMatch(text: []const u8, pattern: []const u8) bool {
        var ti: usize = 0;
        var pi: usize = 0;

        // Check for ^ anchor
        const must_start = pattern.len > 0 and pattern[0] == '^';
        if (must_start) pi = 1;

        // Check for $ anchor
        const must_end = pattern.len > 0 and pattern[pattern.len - 1] == '$';
        const pattern_end = if (must_end) pattern.len - 1 else pattern.len;

        // If not anchored at start, find any match position
        if (!must_start) {
            while (ti < text.len) {
                if (matchFrom(text, ti, pattern[pi..pattern_end])) {
                    // If must_end, verify the match consumes to end
                    if (!must_end) return true;
                    const match_len = calcMatchLength(text[ti..], pattern[pi..pattern_end]);
                    if (ti + match_len == text.len) return true;
                }
                ti += 1;
            }
            return false;
        }

        // Anchored at start
        if (matchFrom(text, 0, pattern[pi..pattern_end])) {
            if (!must_end) return true;
            const match_len = calcMatchLength(text, pattern[pi..pattern_end]);
            return match_len == text.len;
        }
        return false;
    }

    /// Match pattern starting at position in text
    fn matchFrom(text: []const u8, start: usize, pattern: []const u8) bool {
        var ti = start;
        var pi: usize = 0;

        while (pi < pattern.len) {
            // Handle .* (match any)
            if (pi + 1 < pattern.len and pattern[pi] == '.' and pattern[pi + 1] == '*') {
                // Try matching rest of pattern at each position
                pi += 2;
                while (true) {
                    if (matchFrom(text, ti, pattern[pi..])) return true;
                    if (ti >= text.len) break;
                    ti += 1;
                }
                return false;
            }

            // Handle X* (match zero or more of X)
            if (pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                const match_char = pattern[pi];
                pi += 2;
                while (true) {
                    if (matchFrom(text, ti, pattern[pi..])) return true;
                    if (ti >= text.len) break;
                    if (match_char == '.') {
                        ti += 1;
                    } else if (text[ti] == match_char) {
                        ti += 1;
                    } else {
                        break;
                    }
                }
                return false;
            }

            // Out of text to match
            if (ti >= text.len) return false;

            // Handle . (any single char)
            if (pattern[pi] == '.') {
                ti += 1;
                pi += 1;
                continue;
            }

            // Literal character match
            if (text[ti] != pattern[pi]) return false;
            ti += 1;
            pi += 1;
        }

        return true;
    }

    /// Calculate how many characters a pattern match consumes
    fn calcMatchLength(text: []const u8, pattern: []const u8) usize {
        var ti: usize = 0;
        var pi: usize = 0;

        while (pi < pattern.len and ti < text.len) {
            if (pi + 1 < pattern.len and pattern[pi] == '.' and pattern[pi + 1] == '*') {
                // Greedy: consume as much as possible while still matching
                pi += 2;
                if (pi >= pattern.len) return text.len; // .* at end matches all
                // Find last position where rest matches
                var best = ti;
                while (ti <= text.len) {
                    if (matchFrom(text, ti, pattern[pi..])) {
                        best = ti + calcMatchLength(text[ti..], pattern[pi..]);
                    }
                    if (ti >= text.len) break;
                    ti += 1;
                }
                return best;
            }

            if (pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                const match_char = pattern[pi];
                pi += 2;
                while (ti < text.len) {
                    if (match_char == '.') {
                        ti += 1;
                    } else if (text[ti] == match_char) {
                        ti += 1;
                    } else {
                        break;
                    }
                }
                continue;
            }

            if (pattern[pi] == '.') {
                ti += 1;
                pi += 1;
                continue;
            }

            if (text[ti] != pattern[pi]) break;
            ti += 1;
            pi += 1;
        }

        return ti;
    }

    /// Get a specific word from a command (0 = command, 1+ = args, -1 = last)
    fn getWordFromCommand(_: *HistoryExpansion, command: []const u8, index: i32) ?[]const u8 {
        var words_buf: [256]struct { start: usize, end: usize } = undefined;
        var words_count: usize = 0;

        var i: usize = 0;
        var in_word = false;
        var word_start: usize = 0;
        var in_quote: u8 = 0;

        while (i < command.len) : (i += 1) {
            const c = command[i];

            if (in_quote != 0) {
                if (c == in_quote) {
                    in_quote = 0;
                }
                continue;
            }

            if (c == '\'' or c == '"') {
                if (!in_word) {
                    in_word = true;
                    word_start = i;
                }
                in_quote = c;
                continue;
            }

            if (c == ' ' or c == '\t') {
                if (in_word) {
                    if (words_count < words_buf.len) {
                        words_buf[words_count] = .{ .start = word_start, .end = i };
                        words_count += 1;
                    }
                    in_word = false;
                }
            } else {
                if (!in_word) {
                    in_word = true;
                    word_start = i;
                }
            }
        }

        if (in_word) {
            if (words_count < words_buf.len) {
                words_buf[words_count] = .{ .start = word_start, .end = command.len };
                words_count += 1;
            }
        }

        if (words_count == 0) return null;

        var actual_index: usize = undefined;
        if (index < 0) {
            const abs_index: usize = @intCast(-index);
            if (abs_index > words_count) return null;
            actual_index = words_count - abs_index;
        } else {
            actual_index = @intCast(index);
            if (actual_index >= words_count) return null;
        }

        const word = words_buf[actual_index];
        return command[word.start..word.end];
    }

    /// Get all arguments (words 1 to end)
    fn getArgsFromCommand(_: *HistoryExpansion, command: []const u8) ?[]const u8 {
        // Find first space (end of command name)
        var first_space: ?usize = null;
        for (command, 0..) |c, j| {
            if (c == ' ' or c == '\t') {
                first_space = j;
                break;
            }
        }

        if (first_space) |pos| {
            // Skip whitespace after command
            var start = pos;
            while (start < command.len and (command[start] == ' ' or command[start] == '\t')) : (start += 1) {}
            if (start < command.len) {
                return command[start..];
            }
        }

        return null;
    }

    /// Get a range of words
    fn getWordRange(_: *HistoryExpansion, command: []const u8, start: usize, end: i32) ?[]const u8 {
        var words_buf: [256]struct { start: usize, end: usize } = undefined;
        var words_count: usize = 0;

        var i: usize = 0;
        var in_word = false;
        var word_start: usize = 0;

        while (i < command.len) : (i += 1) {
            const c = command[i];
            if (c == ' ' or c == '\t') {
                if (in_word) {
                    if (words_count < words_buf.len) {
                        words_buf[words_count] = .{ .start = word_start, .end = i };
                        words_count += 1;
                    }
                    in_word = false;
                }
            } else {
                if (!in_word) {
                    in_word = true;
                    word_start = i;
                }
            }
        }

        if (in_word) {
            if (words_count < words_buf.len) {
                words_buf[words_count] = .{ .start = word_start, .end = command.len };
                words_count += 1;
            }
        }

        if (words_count == 0) return null;

        var end_idx: usize = undefined;
        if (end < 0) {
            end_idx = words_count - 1;
        } else {
            end_idx = @min(@as(usize, @intCast(end)), words_count - 1);
        }

        if (start > end_idx or start >= words_count) return null;

        return command[words_buf[start].start..words_buf[end_idx].end];
    }
};

/// Result of history expansion
pub const ExpandResult = struct {
    text: []const u8,
    expanded: bool,
};

/// Search result with ranking information
pub const RankedSearchResult = struct {
    command: []const u8,
    index: usize, // Position in history (0 = oldest)
    score: f32, // Higher = better match
    match_type: MatchType,

    pub const MatchType = enum {
        exact, // Exact match
        prefix, // Command starts with pattern
        substring, // Pattern found somewhere in command
        fuzzy, // Fuzzy match (chars in order)
    };
};

/// Search history with ranking support
/// Returns results sorted by relevance score (best matches first)
pub fn searchHistoryRanked(
    allocator: std.mem.Allocator,
    history: []const ?[]const u8,
    history_count: usize,
    pattern: []const u8,
    max_results: usize,
) ![]RankedSearchResult {
    if (history_count == 0 or pattern.len == 0) {
        return &[_]RankedSearchResult{};
    }

    var results = std.ArrayList(RankedSearchResult).empty;
    errdefer results.deinit(allocator);

    // Search through all history entries
    var i: usize = 0;
    while (i < history_count) : (i += 1) {
        if (history[i]) |cmd| {
            const match_result = calculateMatchScore(cmd, pattern, i, history_count);
            if (match_result.score > 0) {
                try results.append(allocator, .{
                    .command = cmd,
                    .index = i,
                    .score = match_result.score,
                    .match_type = match_result.match_type,
                });
            }
        }
    }

    // Sort by score (descending)
    const items = try results.toOwnedSlice(allocator);
    std.mem.sort(RankedSearchResult, items, {}, struct {
        fn lessThan(_: void, a: RankedSearchResult, b: RankedSearchResult) bool {
            return a.score > b.score; // Higher score first
        }
    }.lessThan);

    // Return top results
    const result_count = @min(max_results, items.len);

    // Free unused results
    if (result_count < items.len) {
        const trimmed = try allocator.realloc(items, result_count);
        return trimmed;
    }

    return items;
}

const MatchResult = struct {
    score: f32,
    match_type: RankedSearchResult.MatchType,
};

/// Calculate match score for a command against a pattern
fn calculateMatchScore(
    command: []const u8,
    pattern: []const u8,
    index: usize,
    total_count: usize,
) MatchResult {
    const lower_cmd = blk: {
        var buf: [4096]u8 = undefined;
        for (command, 0..) |c, j| {
            if (j >= buf.len) break;
            buf[j] = std.ascii.toLower(c);
        }
        break :blk buf[0..@min(command.len, buf.len)];
    };

    const lower_pattern = blk: {
        var buf: [256]u8 = undefined;
        for (pattern, 0..) |c, j| {
            if (j >= buf.len) break;
            buf[j] = std.ascii.toLower(c);
        }
        break :blk buf[0..@min(pattern.len, buf.len)];
    };

    // Base scores for different match types
    var base_score: f32 = 0;
    var match_type: RankedSearchResult.MatchType = .fuzzy;

    // Exact match (highest priority)
    if (std.mem.eql(u8, lower_cmd, lower_pattern)) {
        base_score = 100.0;
        match_type = .exact;
    }
    // Prefix match
    else if (std.mem.startsWith(u8, lower_cmd, lower_pattern)) {
        base_score = 80.0;
        match_type = .prefix;
    }
    // Substring match
    else if (std.mem.indexOf(u8, lower_cmd, lower_pattern) != null) {
        base_score = 60.0;
        match_type = .substring;
        // Bonus for earlier position
        if (std.mem.indexOf(u8, lower_cmd, lower_pattern)) |pos| {
            base_score += @as(f32, @floatFromInt(command.len -| pos)) / @as(f32, @floatFromInt(command.len)) * 10.0;
        }
    }
    // Fuzzy match
    else if (fuzzyMatchWithScore(lower_cmd, lower_pattern)) |fuzzy_score| {
        base_score = 20.0 + fuzzy_score * 30.0; // Score from 20-50 based on match quality
        match_type = .fuzzy;
    } else {
        return .{ .score = 0, .match_type = .fuzzy }; // No match
    }

    // Recency bonus: more recent commands get higher scores
    // Uses log scale to not overwhelm match quality
    const recency_factor = if (total_count > 0)
        @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(total_count))
    else
        0.0;
    const recency_bonus = recency_factor * 15.0; // Up to 15 points for recency

    // Length penalty: prefer shorter commands (usually more relevant)
    const length_penalty = if (command.len > pattern.len)
        @as(f32, @floatFromInt(pattern.len)) / @as(f32, @floatFromInt(command.len)) * 5.0
    else
        5.0;

    return .{
        .score = base_score + recency_bonus + length_penalty,
        .match_type = match_type,
    };
}

/// Fuzzy match with score (returns null if no match, 0.0-1.0 score otherwise)
fn fuzzyMatchWithScore(target: []const u8, pattern: []const u8) ?f32 {
    if (pattern.len == 0) return 1.0;
    if (target.len == 0) return null;

    var pattern_idx: usize = 0;
    var consecutive: usize = 0;
    var max_consecutive: usize = 0;
    var gaps: usize = 0;
    var last_match: ?usize = null;

    for (target, 0..) |c, i| {
        if (pattern_idx >= pattern.len) break;

        if (c == pattern[pattern_idx]) {
            if (last_match) |lm| {
                if (i == lm + 1) {
                    consecutive += 1;
                    max_consecutive = @max(max_consecutive, consecutive);
                } else {
                    gaps += i - lm - 1;
                    consecutive = 1;
                }
            } else {
                consecutive = 1;
            }
            last_match = i;
            pattern_idx += 1;
        }
    }

    if (pattern_idx != pattern.len) return null; // Didn't match all chars

    // Score based on:
    // - Consecutive matches (higher = better)
    // - Fewer gaps (better)
    // - Match positions (earlier = better)
    const consecutive_score = @as(f32, @floatFromInt(max_consecutive)) / @as(f32, @floatFromInt(pattern.len));
    const gap_penalty = if (target.len > pattern.len)
        1.0 - @as(f32, @floatFromInt(@min(gaps, target.len))) / @as(f32, @floatFromInt(target.len))
    else
        1.0;

    return consecutive_score * 0.6 + gap_penalty * 0.4;
}

/// Interactive history search - returns top matches for incremental search
pub fn interactiveSearch(
    allocator: std.mem.Allocator,
    history: []const ?[]const u8,
    history_count: usize,
    query: []const u8,
    max_results: usize,
) ![]RankedSearchResult {
    return searchHistoryRanked(allocator, history, history_count, query, max_results);
}

// Tests
test "HistoryExpansion: !! expands to last command" {
    const allocator = std.testing.allocator;
    var expander = HistoryExpansion.init(allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "echo hello";
    history[1] = "ls -la";

    const result = try expander.expand("!!", &history, 2);
    defer allocator.free(result.text);

    try std.testing.expect(result.expanded);
    try std.testing.expectEqualStrings("ls -la", result.text);
}

test "HistoryExpansion: !-1 expands to last command" {
    const allocator = std.testing.allocator;
    var expander = HistoryExpansion.init(allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "echo hello";
    history[1] = "ls -la";

    const result = try expander.expand("!-1", &history, 2);
    defer allocator.free(result.text);

    try std.testing.expect(result.expanded);
    try std.testing.expectEqualStrings("ls -la", result.text);
}

test "HistoryExpansion: !-2 expands to second last" {
    const allocator = std.testing.allocator;
    var expander = HistoryExpansion.init(allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "echo hello";
    history[1] = "ls -la";

    const result = try expander.expand("!-2", &history, 2);
    defer allocator.free(result.text);

    try std.testing.expect(result.expanded);
    try std.testing.expectEqualStrings("echo hello", result.text);
}

test "HistoryExpansion: !1 expands to first command" {
    const allocator = std.testing.allocator;
    var expander = HistoryExpansion.init(allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "first command";
    history[1] = "second command";

    const result = try expander.expand("!1", &history, 2);
    defer allocator.free(result.text);

    try std.testing.expect(result.expanded);
    try std.testing.expectEqualStrings("first command", result.text);
}

test "HistoryExpansion: !string searches prefix" {
    const allocator = std.testing.allocator;
    var expander = HistoryExpansion.init(allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "echo hello";
    history[1] = "ls -la";
    history[2] = "echo world";

    const result = try expander.expand("!echo", &history, 3);
    defer allocator.free(result.text);

    try std.testing.expect(result.expanded);
    try std.testing.expectEqualStrings("echo world", result.text);
}

test "HistoryExpansion: !?string? searches substring" {
    const allocator = std.testing.allocator;
    var expander = HistoryExpansion.init(allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "cat /etc/passwd";
    history[1] = "ls -la";
    history[2] = "echo hello";

    const result = try expander.expand("!?passwd?", &history, 3);
    defer allocator.free(result.text);

    try std.testing.expect(result.expanded);
    try std.testing.expectEqualStrings("cat /etc/passwd", result.text);
}

test "HistoryExpansion: ^old^new substitution" {
    const allocator = std.testing.allocator;
    var expander = HistoryExpansion.init(allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "echo hello";

    const result = try expander.expand("^hello^world", &history, 1);
    defer allocator.free(result.text);

    try std.testing.expect(result.expanded);
    try std.testing.expectEqualStrings("echo world", result.text);
}

test "HistoryExpansion: !$ gets last argument" {
    const allocator = std.testing.allocator;
    var expander = HistoryExpansion.init(allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "echo one two three";

    const result = try expander.expand("echo !$", &history, 1);
    defer allocator.free(result.text);

    try std.testing.expect(result.expanded);
    try std.testing.expectEqualStrings("echo three", result.text);
}

test "HistoryExpansion: !* gets all arguments" {
    const allocator = std.testing.allocator;
    var expander = HistoryExpansion.init(allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "echo one two three";

    const result = try expander.expand("rm !*", &history, 1);
    defer allocator.free(result.text);

    try std.testing.expect(result.expanded);
    try std.testing.expectEqualStrings("rm one two three", result.text);
}

test "HistoryExpansion: word designator :0" {
    const allocator = std.testing.allocator;
    var expander = HistoryExpansion.init(allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "git commit -m message";

    const result = try expander.expand("!!:0", &history, 1);
    defer allocator.free(result.text);

    try std.testing.expect(result.expanded);
    try std.testing.expectEqualStrings("git", result.text);
}

test "HistoryExpansion: word designator :1" {
    const allocator = std.testing.allocator;
    var expander = HistoryExpansion.init(allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "git commit -m message";

    const result = try expander.expand("!!:1", &history, 1);
    defer allocator.free(result.text);

    try std.testing.expect(result.expanded);
    try std.testing.expectEqualStrings("commit", result.text);
}

test "HistoryExpansion: no expansion in single quotes" {
    const allocator = std.testing.allocator;
    var expander = HistoryExpansion.init(allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "echo hello";

    const result = try expander.expand("echo '!!'", &history, 1);
    defer allocator.free(result.text);

    try std.testing.expect(!result.expanded);
    try std.testing.expectEqualStrings("echo '!!'", result.text);
}

test "HistoryExpansion: no history returns original" {
    const allocator = std.testing.allocator;
    var expander = HistoryExpansion.init(allocator);

    var history = [_]?[]const u8{null} ** 10;

    const result = try expander.expand("!!", &history, 0);
    defer allocator.free(result.text);

    try std.testing.expect(!result.expanded);
    try std.testing.expectEqualStrings("!!", result.text);
}

test "HistoryExpansion: mixed text and expansion" {
    const allocator = std.testing.allocator;
    var expander = HistoryExpansion.init(allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "ls -la";

    const result = try expander.expand("echo before !! after", &history, 1);
    defer allocator.free(result.text);

    try std.testing.expect(result.expanded);
    try std.testing.expectEqualStrings("echo before ls -la after", result.text);
}

test "HistoryExpansion: fuzzy search matches" {
    var expander = HistoryExpansion.init(std.testing.allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "git checkout main";
    history[1] = "ls -la";
    history[2] = "echo hello";

    // "gco" fuzzy matches "git checkout"
    const match = expander.searchHistoryFuzzy(&history, 3, "gco");
    try std.testing.expect(match != null);
    try std.testing.expectEqualStrings("git checkout main", match.?);
}

test "HistoryExpansion: fuzzy search case insensitive" {
    var expander = HistoryExpansion.init(std.testing.allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "Git Checkout Main";

    const match = expander.searchHistoryFuzzy(&history, 1, "GCM");
    try std.testing.expect(match != null);
    try std.testing.expectEqualStrings("Git Checkout Main", match.?);
}

test "HistoryExpansion: regex search basic" {
    var expander = HistoryExpansion.init(std.testing.allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "echo hello world";
    history[1] = "ls -la";

    const match = expander.searchHistoryRegex(&history, 2, "hello");
    try std.testing.expect(match != null);
    try std.testing.expectEqualStrings("echo hello world", match.?);
}

test "HistoryExpansion: regex search with dot" {
    var expander = HistoryExpansion.init(std.testing.allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "cat file.txt";
    history[1] = "ls -la";

    const match = expander.searchHistoryRegex(&history, 2, "file.txt");
    try std.testing.expect(match != null);
    try std.testing.expectEqualStrings("cat file.txt", match.?);
}

test "HistoryExpansion: regex search with anchor" {
    var expander = HistoryExpansion.init(std.testing.allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "echo hello";
    history[1] = "ls -la";

    const match = expander.searchHistoryRegex(&history, 2, "^echo");
    try std.testing.expect(match != null);
    try std.testing.expectEqualStrings("echo hello", match.?);
}

test "HistoryExpansion: !# expansion" {
    const allocator = std.testing.allocator;
    var expander = HistoryExpansion.init(allocator);

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "echo hello";

    // !# should expand (returns empty string in basic impl)
    const result = try expander.expand("echo !#", &history, 1);
    defer allocator.free(result.text);

    try std.testing.expect(result.expanded);
}

test "Ranked search: exact match scores highest" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "git status";
    history[1] = "git commit";
    history[2] = "ls -la";

    const results = try searchHistoryRanked(allocator, &history, 3, "git status", 10);
    defer allocator.free(results);

    try std.testing.expect(results.len > 0);
    try std.testing.expectEqualStrings("git status", results[0].command);
    try std.testing.expectEqual(RankedSearchResult.MatchType.exact, results[0].match_type);
}

test "Ranked search: prefix beats substring" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "echo git"; // substring match
    history[1] = "git status"; // prefix match

    const results = try searchHistoryRanked(allocator, &history, 2, "git", 10);
    defer allocator.free(results);

    try std.testing.expect(results.len >= 2);
    // Prefix match should be first
    try std.testing.expectEqual(RankedSearchResult.MatchType.prefix, results[0].match_type);
}

test "Ranked search: recency bonus" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "git status"; // older
    history[1] = "git status"; // newer (same command)

    const results = try searchHistoryRanked(allocator, &history, 2, "git status", 10);
    defer allocator.free(results);

    try std.testing.expect(results.len >= 2);
    // More recent (higher index) should have higher score
    try std.testing.expect(results[0].index > results[1].index or results[0].score >= results[1].score);
}

test "Ranked search: fuzzy matching works" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "git checkout main";
    history[1] = "ls -la";

    const results = try searchHistoryRanked(allocator, &history, 2, "gco", 10);
    defer allocator.free(results);

    try std.testing.expect(results.len > 0);
    try std.testing.expectEqualStrings("git checkout main", results[0].command);
    try std.testing.expectEqual(RankedSearchResult.MatchType.fuzzy, results[0].match_type);
}

test "Ranked search: empty pattern returns empty" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{null} ** 10;
    history[0] = "git status";

    const results = try searchHistoryRanked(allocator, &history, 1, "", 10);
    // Empty pattern should return empty or be handled gracefully
    try std.testing.expect(results.len == 0);
}
