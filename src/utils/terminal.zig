const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

/// Windows console mode flags and APIs
const windows = if (builtin.os.tag == .windows) struct {
    const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
    const ENABLE_PROCESSED_OUTPUT: u32 = 0x0001;
    const ENABLE_WRAP_AT_EOL_OUTPUT: u32 = 0x0002;
    const ENABLE_LINE_INPUT: u32 = 0x0002;
    const ENABLE_ECHO_INPUT: u32 = 0x0004;
    const ENABLE_PROCESSED_INPUT: u32 = 0x0001;

    // Windows API functions not in std.os.windows.kernel32
    pub extern "kernel32" fn GetNumberOfConsoleInputEvents(
        hConsoleInput: std.os.windows.HANDLE,
        lpcNumberOfEvents: *u32,
    ) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

/// Terminal mode management and raw input handling
pub const Terminal = struct {
    original_termios: if (builtin.os.tag == .windows) ?u32 else ?std.posix.termios = null,
    original_output_mode: if (builtin.os.tag == .windows) ?u32 else void = if (builtin.os.tag == .windows) null else {},
    is_raw: bool = false,

    /// Enable raw terminal mode (disable canonical mode, echo, etc.)
    pub fn enableRawMode(self: *Terminal) !void {
        if (builtin.os.tag == .windows) {
            return self.enableRawModeWindows();
        }

        if (self.is_raw) return; // Already in raw mode

        // Get current terminal settings
        const stdin_fd = posix.STDIN_FILENO;
        const original = try std.posix.tcgetattr(stdin_fd);
        self.original_termios = original;

        var raw = original;

        // Disable canonical mode (line buffering)
        raw.lflag.ICANON = false;
        // Disable echo
        raw.lflag.ECHO = false;
        // Disable signal generation (Ctrl+C, Ctrl+Z)
        raw.lflag.ISIG = false;
        // Disable extended input processing
        raw.lflag.IEXTEN = false;

        // Disable input processing (Ctrl+S, Ctrl+Q)
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;

        // Disable output processing for raw mode
        raw.oflag.OPOST = false;

        // Set character size to 8 bits
        raw.cflag.CSIZE = .CS8;

        // Minimum number of characters for non-canonical read
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        // Timeout in deciseconds for non-canonical read
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;

        // Apply the settings
        try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
        self.is_raw = true;
    }

    /// Enable raw mode on Windows
    fn enableRawModeWindows(self: *Terminal) !void {
        if (builtin.os.tag != .windows) unreachable;

        if (self.is_raw) return;

        const win = std.os.windows;
        const stdin_handle = try win.GetStdHandle(win.STD_INPUT_HANDLE);
        const stdout_handle = try win.GetStdHandle(win.STD_OUTPUT_HANDLE);

        // Get current console modes
        var input_mode: u32 = undefined;
        if (win.kernel32.GetConsoleMode(stdin_handle, &input_mode) == 0) {
            return error.GetConsoleModeFailed;
        }
        self.original_termios = input_mode;

        var output_mode: u32 = undefined;
        if (win.kernel32.GetConsoleMode(stdout_handle, &output_mode) == 0) {
            return error.GetConsoleModeFailed;
        }
        self.original_output_mode = output_mode;

        // Disable line input and echo for raw mode
        var new_input_mode = input_mode;
        new_input_mode &= ~(@as(u32, windows.ENABLE_LINE_INPUT));
        new_input_mode &= ~(@as(u32, windows.ENABLE_ECHO_INPUT));
        new_input_mode &= ~(@as(u32, windows.ENABLE_PROCESSED_INPUT));
        new_input_mode |= windows.ENABLE_VIRTUAL_TERMINAL_INPUT;

        if (win.kernel32.SetConsoleMode(stdin_handle, new_input_mode) == 0) {
            return error.SetConsoleModeFailed;
        }

        // Enable virtual terminal processing for ANSI escape codes
        var new_output_mode = output_mode;
        new_output_mode |= windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
        new_output_mode |= windows.ENABLE_PROCESSED_OUTPUT;
        new_output_mode |= windows.ENABLE_WRAP_AT_EOL_OUTPUT;

        if (win.kernel32.SetConsoleMode(stdout_handle, new_output_mode) == 0) {
            return error.SetConsoleModeFailed;
        }

        self.is_raw = true;
    }

    /// Disable raw terminal mode (restore original settings)
    pub fn disableRawMode(self: *Terminal) !void {
        if (!self.is_raw) return; // Already in normal mode
        if (self.original_termios == null) return;

        if (builtin.os.tag == .windows) {
            const win = std.os.windows;
            const stdin_handle = try win.GetStdHandle(win.STD_INPUT_HANDLE);
            const stdout_handle = try win.GetStdHandle(win.STD_OUTPUT_HANDLE);

            _ = win.kernel32.SetConsoleMode(stdin_handle, self.original_termios.?);
            if (self.original_output_mode) |output_mode| {
                _ = win.kernel32.SetConsoleMode(stdout_handle, output_mode);
            }
            self.is_raw = false;
            return;
        }

        const stdin_fd = posix.STDIN_FILENO;
        try std.posix.tcsetattr(stdin_fd, .FLUSH, self.original_termios.?);
        self.is_raw = false;
    }

    /// Read a single byte from stdin (non-blocking in raw mode)
    /// Returns null if no data available
    pub fn readByte(self: *Terminal) !?u8 {
        if (!self.is_raw) return error.NotInRawMode;

        if (builtin.os.tag == .windows) {
            const win = std.os.windows;
            const stdin_handle = try win.GetStdHandle(win.STD_INPUT_HANDLE);

            // Check if input available
            var num_events: u32 = undefined;
            if (windows.GetNumberOfConsoleInputEvents(stdin_handle, &num_events) == 0) {
                return error.GetInputEventsFailed;
            }

            if (num_events == 0) return null;

            // Read one character
            var buf: [1]u8 = undefined;
            var bytes_read: u32 = undefined;
            if (win.kernel32.ReadFile(stdin_handle, &buf, 1, &bytes_read, null) == 0) {
                return error.ReadFailed;
            }

            if (bytes_read == 0) return null;
            return buf[0];
        }

        var buf: [1]u8 = undefined;
        const bytes_read = posix.read(posix.STDIN_FILENO, &buf) catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };

        if (bytes_read == 0) return null;
        return buf[0];
    }
};

/// Escape sequence parser for arrow keys, function keys, etc.
pub const EscapeSequence = enum {
    up_arrow,
    down_arrow,
    left_arrow,
    right_arrow,
    ctrl_left,     // Ctrl+Left arrow (word back)
    ctrl_right,    // Ctrl+Right arrow (word forward)
    alt_b,         // Alt+B (word back)
    alt_f,         // Alt+F (word forward)
    alt_d,         // Alt+D (delete word forward)
    home,
    end_key,
    delete,
    page_up,
    page_down,
    unknown,

    /// Parse escape sequence from input
    /// Returns null if not a complete sequence yet
    pub fn parse(bytes: []const u8) ?EscapeSequence {
        if (bytes.len < 2) return null;

        // Check for CSI sequence (ESC [)
        if (bytes[0] == 0x1B and bytes[1] == '[') {
            if (bytes.len < 3) return null;

            // Single character sequences
            switch (bytes[2]) {
                'A' => return .up_arrow,
                'B' => return .down_arrow,
                'C' => return .right_arrow,
                'D' => return .left_arrow,
                'H' => return .home,
                'F' => return .end_key,
                else => {},
            }

            // Multi-character sequences
            if (bytes.len >= 4 and bytes[3] == '~') {
                switch (bytes[2]) {
                    '3' => return .delete,
                    '5' => return .page_up,
                    '6' => return .page_down,
                    else => {},
                }
            }

            // Ctrl+Arrow sequences: ESC[1;5C (right) or ESC[1;5D (left)
            if (bytes.len >= 6 and bytes[2] == '1' and bytes[3] == ';' and bytes[4] == '5') {
                switch (bytes[5]) {
                    'C' => return .ctrl_right,
                    'D' => return .ctrl_left,
                    else => {},
                }
            }
        }

        // Alt+key sequences (ESC followed by character)
        if (bytes[0] == 0x1B and bytes.len >= 2 and bytes[1] != '[') {
            switch (bytes[1]) {
                'b', 'B' => return .alt_b,  // Alt+B (word back)
                'f', 'F' => return .alt_f,  // Alt+F (word forward)
                'd', 'D' => return .alt_d,  // Alt+D (delete word forward)
                else => return .unknown,
            }
        }

        return .unknown;
    }
};

/// Completion callback function type
/// Takes the current input and returns a list of completions
pub const CompletionFn = *const fn (input: []const u8, allocator: std.mem.Allocator) anyerror![][]const u8;

/// Line editor with history support
pub const LineEditor = struct {
    allocator: std.mem.Allocator,
    buffer: [4096]u8 = undefined,
    cursor: usize = 0,
    length: usize = 0,
    terminal: Terminal = .{},
    prompt: []const u8 = "",
    history: ?*[1000]?[]const u8 = null,
    history_count: ?*usize = null,
    history_index: ?usize = null,
    saved_line: ?[]const u8 = null, // Save current line when browsing history
    history_search_query: ?[]const u8 = null, // Substring to filter history (for substring search)
    completion_fn: ?CompletionFn = null, // Callback for tab completion
    // Completion cycling state
    completion_list: ?[][]const u8 = null,
    completion_index: usize = 0,
    completion_word_start: usize = 0,
    completion_path_prefix: ?[]const u8 = null, // Save the path prefix (e.g., "Documents/Projects/")
    // Inline suggestion state
    suggestion: ?[]const u8 = null, // The suggested text from history
    // Reverse search mode (Ctrl+R)
    reverse_search_mode: bool = false,
    reverse_search_query: [256]u8 = undefined,
    reverse_search_query_len: usize = 0,
    reverse_search_match: ?[]const u8 = null,
    reverse_search_history_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, prompt: []const u8) LineEditor {
        return .{
            .allocator = allocator,
            .prompt = prompt,
        };
    }

    pub fn setHistory(self: *LineEditor, history: *[1000]?[]const u8, count: *usize) void {
        self.history = history;
        self.history_count = count;
    }

    pub fn setCompletionFn(self: *LineEditor, completion_fn: CompletionFn) void {
        self.completion_fn = completion_fn;
    }

    /// Read a line with editing support
    pub fn readLine(self: *LineEditor) !?[]u8 {
        // Display prompt BEFORE entering raw mode so ANSI codes work
        try self.displayPrompt();

        // Enable raw mode after displaying prompt
        try self.terminal.enableRawMode();
        errdefer self.terminal.disableRawMode() catch {};

        // Reset state
        self.cursor = 0;
        self.length = 0;
        self.history_index = null;
        if (self.saved_line) |saved| {
            self.allocator.free(saved);
            self.saved_line = null;
        }

        var escape_buffer: [8]u8 = undefined;
        var escape_len: usize = 0;
        var in_escape: bool = false;

        while (true) {
            const byte = (try self.terminal.readByte()) orelse {
                // No data, sleep briefly (10ms)
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            };

            // Handle escape sequences
            if (in_escape) {
                escape_buffer[escape_len] = byte;
                escape_len += 1;

                if (EscapeSequence.parse(escape_buffer[0..escape_len])) |seq| {
                    try self.handleEscapeSequence(seq);
                    in_escape = false;
                    escape_len = 0;
                } else if (escape_len >= escape_buffer.len) {
                    // Invalid sequence, ignore
                    in_escape = false;
                    escape_len = 0;
                }
                continue;
            }

            // Check for escape start
            if (byte == 0x1B) {
                escape_buffer[0] = byte;
                escape_len = 1;
                in_escape = true;
                continue;
            }

            // Handle special characters
            switch (byte) {
                '\r', '\n' => {
                    // Enter key
                    // If in reverse search mode, accept the match
                    if (self.reverse_search_mode) {
                        try self.acceptReverseSearch();
                        if (self.length > 0) {
                            try self.writeBytes("\r\n");
                            try self.terminal.disableRawMode();
                            return try self.allocator.dupe(u8, self.buffer[0..self.length]);
                        }
                        continue;
                    }

                    // If we have an active completion list, accept it instead of submitting
                    if (self.completion_list != null) {
                        self.clearCompletionState();
                        continue;
                    }

                    try self.writeBytes("\r\n");
                    try self.terminal.disableRawMode();

                    if (self.length == 0) return try self.allocator.dupe(u8, "");
                    return try self.allocator.dupe(u8, self.buffer[0..self.length]);
                },
                0x03 => {
                    // Ctrl+C
                    if (self.reverse_search_mode) {
                        // Cancel reverse search and clear line
                        try self.cancelReverseSearch();
                        try self.writeBytes("\r\n");
                        try self.writeBytes(self.prompt);
                        self.length = 0;
                        self.cursor = 0;
                        continue;
                    }

                    // Clear any visible completion list first
                    if (self.completion_list != null) {
                        try self.clearCompletionDisplay();
                    }
                    try self.writeBytes("^C\r\n");
                    try self.terminal.disableRawMode();
                    return error.Interrupted;
                },
                0x04 => {
                    // Ctrl+D (EOF)
                    if (self.length == 0) {
                        // Clear any visible completion list first
                        if (self.completion_list != null) {
                            try self.clearCompletionDisplay();
                        }
                        try self.writeBytes("\r\n");
                        try self.terminal.disableRawMode();
                        return null; // Signal EOF
                    }
                    // Otherwise, delete character under cursor
                    try self.deleteChar();
                },
                0x01 => {
                    self.clearCompletionState();
                    try self.moveCursorHome(); // Ctrl+A
                },
                0x05 => {
                    self.clearCompletionState();
                    try self.moveCursorEnd(); // Ctrl+E
                },
                0x02 => {
                    self.clearCompletionState();
                    try self.moveCursorLeft(); // Ctrl+B
                },
                0x06 => {
                    self.clearCompletionState();
                    try self.moveCursorRight(); // Ctrl+F
                },
                0x0B => {
                    self.clearCompletionState();
                    try self.killToEnd(); // Ctrl+K
                },
                0x0C => {
                    self.clearCompletionState();
                    try self.clearScreen(); // Ctrl+L
                },
                0x14 => {
                    self.clearCompletionState();
                    try self.transposeChars(); // Ctrl+T
                },
                0x15 => {
                    self.clearCompletionState();
                    try self.killToStart(); // Ctrl+U
                },
                0x17 => {
                    self.clearCompletionState();
                    try self.deleteWord(); // Ctrl+W
                },
                0x12 => {
                    // Ctrl+R - Reverse search
                    if (self.reverse_search_mode) {
                        // Already in search mode - find next match
                        try self.continueReverseSearch();
                    } else {
                        // Enter reverse search mode
                        try self.startReverseSearch();
                    }
                },
                0x09 => {
                    // Tab - handle completion
                    if (!self.reverse_search_mode) {
                        try self.handleTabCompletion();
                    }
                },
                0x7F, 0x08 => {
                    // Backspace (DEL or BS)
                    if (self.reverse_search_mode) {
                        // Delete character from search query
                        if (self.reverse_search_query_len > 0) {
                            self.reverse_search_query_len -= 1;
                            if (self.history_count) |count| {
                                self.reverse_search_history_index = count.*;
                            }
                            try self.updateReverseSearch();
                        }
                    } else {
                        self.clearCompletionState();
                        try self.backspace();
                    }
                },
                0x20...0x7E => {
                    // Printable ASCII
                    if (self.reverse_search_mode) {
                        // Add character to search query
                        if (self.reverse_search_query_len < self.reverse_search_query.len) {
                            self.reverse_search_query[self.reverse_search_query_len] = byte;
                            self.reverse_search_query_len += 1;
                            if (self.history_count) |count| {
                                self.reverse_search_history_index = count.*;
                            }
                            try self.updateReverseSearch();
                        }
                    } else {
                        self.clearCompletionState();
                        try self.insertChar(byte);
                    }
                },
                else => {
                    // Ignore other control characters
                },
            }
        }
    }

    fn displayPrompt(self: *LineEditor) !void {
        // Debug logging
        const log_file = std.fs.cwd().createFile("/tmp/den_debug.log", .{ .truncate = false }) catch return;
        defer log_file.close();
        try log_file.seekFromEnd(0);

        var buf: [4096]u8 = undefined;
        const log_msg = try std.fmt.bufPrint(&buf, "=== displayPrompt called ===\nPrompt string ({d} bytes): ", .{self.prompt.len});
        _ = try log_file.write(log_msg);
        _ = try log_file.write(self.prompt);
        _ = try log_file.write("\nHex dump: ");

        for (self.prompt) |byte| {
            const hex = try std.fmt.bufPrint(buf[0..3], "{x:0>2} ", .{byte});
            _ = try log_file.write(hex);
        }
        _ = try log_file.write("\n\n");

        try self.writeBytes(self.prompt);
        // Flush stdout to ensure prompt is displayed before entering raw mode
        if (builtin.os.tag != .windows) {
            // Force flush by calling fsync on stdout
            _ = posix.fsync(posix.STDOUT_FILENO) catch {};
        }
    }

    /// Clear history search state (called when user modifies the line during search)
    fn clearHistorySearch(self: *LineEditor) void {
        if (self.history_search_query) |query| {
            self.allocator.free(query);
            self.history_search_query = null;
        }
        self.history_index = null;
        if (self.saved_line) |saved| {
            self.allocator.free(saved);
            self.saved_line = null;
        }
    }

    /// Start reverse search mode (Ctrl+R)
    fn startReverseSearch(self: *LineEditor) !void {
        _ = self.history orelse return;
        const count = self.history_count orelse return;
        if (count.* == 0) return;

        self.reverse_search_mode = true;
        self.reverse_search_query_len = 0;
        self.reverse_search_history_index = count.*;
        try self.updateReverseSearch();
    }

    /// Update reverse search with current query
    fn updateReverseSearch(self: *LineEditor) !void {
        const history = self.history orelse return;
        _ = self.history_count orelse return;

        const query = self.reverse_search_query[0..self.reverse_search_query_len];

        // Search backwards from current position
        var i = self.reverse_search_history_index;
        while (i > 0) {
            i -= 1;
            if (history[i]) |entry| {
                // Check if entry contains the query
                if (query.len == 0 or std.mem.indexOf(u8, entry, query) != null) {
                    self.reverse_search_match = entry;
                    self.reverse_search_history_index = i;
                    try self.redrawReverseSearch();
                    return;
                }
            }
        }

        // No match found - keep current match or show no results
        try self.redrawReverseSearch();
    }

    /// Continue reverse search (find next match) - called when user presses Ctrl+R again
    fn continueReverseSearch(self: *LineEditor) !void {
        if (!self.reverse_search_mode) return;
        if (self.reverse_search_history_index > 0) {
            self.reverse_search_history_index -= 1;
            try self.updateReverseSearch();
        }
    }

    /// Redraw the reverse search prompt and matched line
    fn redrawReverseSearch(self: *LineEditor) !void {
        // Clear current line
        try self.writeBytes("\r\x1B[K");

        // Show reverse search prompt
        const query = self.reverse_search_query[0..self.reverse_search_query_len];
        var prompt_buf: [512]u8 = undefined;
        const search_prompt = if (self.reverse_search_match) |match|
            try std.fmt.bufPrint(&prompt_buf, "(reverse-i-search)`{s}': {s}", .{ query, match })
        else
            try std.fmt.bufPrint(&prompt_buf, "(failed reverse-i-search)`{s}': ", .{query});

        try self.writeBytes(search_prompt);
    }

    /// Accept reverse search result
    fn acceptReverseSearch(self: *LineEditor) !void {
        if (self.reverse_search_match) |match| {
            // Copy match to buffer
            const len = @min(match.len, self.buffer.len);
            @memcpy(self.buffer[0..len], match[0..len]);
            self.length = len;
            self.cursor = len;
        }
        try self.cancelReverseSearch();
    }

    /// Cancel reverse search mode
    fn cancelReverseSearch(self: *LineEditor) !void {
        self.reverse_search_mode = false;
        self.reverse_search_match = null;
        self.reverse_search_query_len = 0;
        self.reverse_search_history_index = 0;

        // Redraw normal prompt and buffer
        try self.writeBytes("\r\x1B[K");
        try self.writeBytes(self.prompt);
        try self.writeBytes(self.buffer[0..self.length]);

        // Move cursor to end
        self.cursor = self.length;
    }

    fn insertChar(self: *LineEditor, char: u8) !void {
        if (self.length >= self.buffer.len) return;

        // Clear history search when user types
        self.clearHistorySearch();

        // Clear old suggestion from screen if present
        if (self.suggestion != null) {
            try self.writeBytes("\x1b[0K"); // Clear from cursor to end of line
        }

        // Move characters after cursor to the right
        if (self.cursor < self.length) {
            var i = self.length;
            while (i > self.cursor) : (i -= 1) {
                self.buffer[i] = self.buffer[i - 1];
            }
        }

        self.buffer[self.cursor] = char;
        self.cursor += 1;
        self.length += 1;

        // Redraw from cursor to end
        try self.writeBytes(self.buffer[self.cursor - 1 .. self.length]);

        // Move cursor back to correct position
        if (self.cursor < self.length) {
            const back_count = self.length - self.cursor;
            var i: usize = 0;
            while (i < back_count) : (i += 1) {
                try self.writeBytes("\x1B[D"); // ESC [ D = cursor left
            }
        }

        // Update and display suggestion only if cursor is at end and we have at least 3 characters
        if (self.cursor == self.length and self.length >= 3) {
            try self.updateSuggestion();
            try self.displaySuggestion();
        }
    }

    fn backspace(self: *LineEditor) !void {
        if (self.cursor == 0) return;

        // Clear history search when user types
        self.clearHistorySearch();

        // Clear old suggestion from screen if present
        if (self.suggestion != null) {
            try self.writeBytes("\x1b[0K"); // Clear from cursor to end of line
        }

        // Move characters after cursor to the left
        var i = self.cursor - 1;
        while (i < self.length - 1) : (i += 1) {
            self.buffer[i] = self.buffer[i + 1];
        }

        self.cursor -= 1;
        self.length -= 1;

        // Move cursor back, redraw line, clear to end
        try self.writeBytes("\x1B[D"); // Move cursor left
        try self.writeBytes(self.buffer[self.cursor..self.length]);
        try self.writeBytes(" "); // Clear the last character
        try self.writeBytes("\x1B[K"); // Clear to end of line

        // Move cursor back to correct position
        const back_count = self.length - self.cursor + 1;
        var j: usize = 0;
        while (j < back_count) : (j += 1) {
            try self.writeBytes("\x1B[D");
        }

        // Update and display suggestion only if cursor is at end and we have at least 3 characters
        if (self.cursor == self.length and self.length >= 3) {
            try self.updateSuggestion();
            try self.displaySuggestion();
        }
    }

    fn deleteChar(self: *LineEditor) !void {
        if (self.cursor >= self.length) return;

        // Clear history search when user deletes
        self.clearHistorySearch();

        // Move characters after cursor to the left
        var i = self.cursor;
        while (i < self.length - 1) : (i += 1) {
            self.buffer[i] = self.buffer[i + 1];
        }

        self.length -= 1;

        // Redraw from cursor to end
        try self.writeBytes(self.buffer[self.cursor..self.length]);
        try self.writeBytes(" ");
        try self.writeBytes("\x1B[K");

        // Move cursor back
        const back_count = self.length - self.cursor + 1;
        var j: usize = 0;
        while (j < back_count) : (j += 1) {
            try self.writeBytes("\x1B[D");
        }
    }

    fn moveCursorLeft(self: *LineEditor) !void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        try self.writeBytes("\x1B[D");
    }

    fn moveCursorRight(self: *LineEditor) !void {
        if (self.cursor >= self.length) return;
        self.cursor += 1;
        try self.writeBytes("\x1B[C");
    }

    /// Find the start of the previous word
    fn findPreviousWord(self: *LineEditor) usize {
        if (self.cursor == 0) return 0;

        var pos = self.cursor;

        // Skip any whitespace immediately before cursor
        while (pos > 0 and std.ascii.isWhitespace(self.buffer[pos - 1])) {
            pos -= 1;
        }

        // Skip non-whitespace (the word)
        while (pos > 0 and !std.ascii.isWhitespace(self.buffer[pos - 1])) {
            pos -= 1;
        }

        return pos;
    }

    /// Find the start of the next word
    fn findNextWord(self: *LineEditor) usize {
        if (self.cursor >= self.length) return self.length;

        var pos = self.cursor;

        // Skip non-whitespace (current word)
        while (pos < self.length and !std.ascii.isWhitespace(self.buffer[pos])) {
            pos += 1;
        }

        // Skip whitespace to get to next word
        while (pos < self.length and std.ascii.isWhitespace(self.buffer[pos])) {
            pos += 1;
        }

        return pos;
    }

    /// Move cursor to the start of the previous word
    fn moveCursorWordLeft(self: *LineEditor) !void {
        const target = self.findPreviousWord();
        while (self.cursor > target) {
            try self.moveCursorLeft();
        }
    }

    /// Move cursor to the start of the next word
    fn moveCursorWordRight(self: *LineEditor) !void {
        const target = self.findNextWord();
        while (self.cursor < target) {
            try self.moveCursorRight();
        }
    }

    fn deleteWordForward(self: *LineEditor) !void {
        if (self.cursor >= self.length) return;

        // Clear history search when user deletes word
        self.clearHistorySearch();

        // Find end of next word
        const delete_to = self.findNextWord();
        const chars_to_delete = delete_to - self.cursor;

        if (chars_to_delete == 0) return;

        // Shift remaining characters left
        const remaining = self.length - delete_to;
        var i: usize = 0;
        while (i < remaining) : (i += 1) {
            self.buffer[self.cursor + i] = self.buffer[delete_to + i];
        }
        self.length -= chars_to_delete;

        // Redraw line from cursor position
        try self.writeBytes(self.buffer[self.cursor..self.length]);
        try self.writeBytes(" ");  // Clear the last character
        try self.writeBytes("\x1B[K");  // Clear to end of line

        // Move cursor back to correct position
        const moves_needed = self.length - self.cursor + 1;
        i = 0;
        while (i < moves_needed) : (i += 1) {
            try self.writeBytes("\x1B[D");
        }
    }

    fn transposeChars(self: *LineEditor) !void {
        // Need at least 2 characters to transpose
        if (self.length < 2) return;
        if (self.cursor == 0) return;

        // Clear history search when user transposes
        self.clearHistorySearch();

        var pos1: usize = undefined;
        var pos2: usize = undefined;

        if (self.cursor == self.length) {
            // At end of line: swap last two characters
            pos1 = self.length - 2;
            pos2 = self.length - 1;
        } else {
            // Middle of line: swap char before cursor with char at cursor
            pos1 = self.cursor - 1;
            pos2 = self.cursor;
        }

        // Swap the characters
        const temp = self.buffer[pos1];
        self.buffer[pos1] = self.buffer[pos2];
        self.buffer[pos2] = temp;

        // Redraw the affected area
        // Move cursor to pos1
        while (self.cursor > pos1) {
            try self.writeBytes("\x1B[D");
            self.cursor -= 1;
        }
        while (self.cursor < pos1) {
            try self.writeBytes("\x1B[C");
            self.cursor += 1;
        }

        // Redraw from pos1 to end
        try self.writeBytes(self.buffer[pos1..self.length]);

        // Position cursor after the transposed pair
        const target_pos = pos2 + 1;
        while (self.cursor < target_pos and self.cursor < self.length) {
            try self.writeBytes("\x1B[C");
            self.cursor += 1;
        }

        // Move cursor back to where it should be
        while (self.cursor > target_pos) {
            try self.writeBytes("\x1B[D");
            self.cursor -= 1;
        }
    }

    fn moveCursorHome(self: *LineEditor) !void {
        while (self.cursor > 0) {
            try self.moveCursorLeft();
        }
    }

    fn moveCursorEnd(self: *LineEditor) !void {
        while (self.cursor < self.length) {
            try self.moveCursorRight();
        }
    }

    fn killToEnd(self: *LineEditor) !void {
        if (self.cursor >= self.length) return;

        // Clear history search when user kills text
        self.clearHistorySearch();

        try self.writeBytes("\x1B[K"); // Clear to end of line
        self.length = self.cursor;
    }

    fn killToStart(self: *LineEditor) !void {
        if (self.cursor == 0) return;

        // Clear history search when user kills text
        self.clearHistorySearch();

        // Move remaining characters to start
        const remaining = self.length - self.cursor;
        var i: usize = 0;
        while (i < remaining) : (i += 1) {
            self.buffer[i] = self.buffer[self.cursor + i];
        }
        self.length = remaining;

        // Move cursor to home
        while (self.cursor > 0) {
            try self.writeBytes("\x1B[D");
            self.cursor -= 1;
        }

        // Redraw line
        try self.writeBytes(self.buffer[0..self.length]);
        try self.writeBytes("\x1B[K");

        // Move cursor to home
        while (self.cursor < self.length) {
            try self.writeBytes("\x1B[D");
        }
        self.cursor = 0;
    }

    fn clearScreen(self: *LineEditor) !void {
        // Clear entire screen and move cursor to home
        try self.writeBytes("\x1B[2J\x1B[H");

        // Redisplay prompt
        try self.displayPrompt();

        // Redraw current buffer
        if (self.length > 0) {
            try self.writeBytes(self.buffer[0..self.length]);

            // Move cursor back to correct position
            const moves_needed = self.length - self.cursor;
            var i: usize = 0;
            while (i < moves_needed) : (i += 1) {
                try self.writeBytes("\x1B[D");
            }
        }
    }

    fn deleteWord(self: *LineEditor) !void {
        if (self.cursor == 0) return;

        // Clear history search when user deletes word
        self.clearHistorySearch();

        // Find start of previous word
        var word_start = self.cursor;
        while (word_start > 0 and self.buffer[word_start - 1] == ' ') {
            word_start -= 1;
        }
        while (word_start > 0 and self.buffer[word_start - 1] != ' ') {
            word_start -= 1;
        }

        // Delete from word_start to cursor
        const delete_count = self.cursor - word_start;
        var i: usize = word_start;
        while (i < self.length - delete_count) : (i += 1) {
            self.buffer[i] = self.buffer[i + delete_count];
        }
        self.length -= delete_count;

        // Move cursor back and redraw
        var j: usize = 0;
        while (j < delete_count) : (j += 1) {
            try self.writeBytes("\x1B[D");
        }
        self.cursor = word_start;

        // Redraw from cursor to end
        try self.writeBytes(self.buffer[self.cursor..self.length]);
        try self.writeBytes(" " ** 16);
        try self.writeBytes("\x1B[K");

        // Move cursor back to position
        const back_count = self.length - self.cursor + 16;
        j = 0;
        while (j < back_count) : (j += 1) {
            try self.writeBytes("\x1B[D");
        }
    }

    fn handleEscapeSequence(self: *LineEditor, seq: EscapeSequence) !void {
        // If we have an active completion list, handle arrow keys for completion navigation
        if (self.completion_list != null) {
            switch (seq) {
                .down_arrow, .right_arrow => {
                    // Move to next completion
                    const list_len = self.completion_list.?.len;
                    self.completion_index = (self.completion_index + 1) % list_len;
                    try self.applyCurrentCompletion();
                    try self.updateCompletionListHighlight();
                    return;
                },
                .up_arrow, .left_arrow => {
                    // Move to previous completion
                    const list_len = self.completion_list.?.len;
                    if (self.completion_index == 0) {
                        self.completion_index = list_len - 1;
                    } else {
                        self.completion_index -= 1;
                    }
                    try self.applyCurrentCompletion();
                    try self.updateCompletionListHighlight();
                    return;
                },
                else => {
                    // Clear completion on other keys
                    self.clearCompletionState();
                },
            }
        }

        // Normal arrow key handling (no active completions)
        switch (seq) {
            .up_arrow => try self.historyPrevious(),
            .down_arrow => try self.historyNext(),
            .left_arrow => try self.moveCursorLeft(),
            .right_arrow => {
                // If there's a suggestion and cursor is at end, accept it
                if (self.suggestion != null and self.cursor == self.length) {
                    try self.acceptSuggestion();
                } else {
                    try self.moveCursorRight();
                }
            },
            .ctrl_left, .alt_b => try self.moveCursorWordLeft(),
            .ctrl_right, .alt_f => try self.moveCursorWordRight(),
            .alt_d => try self.deleteWordForward(),
            .home => try self.moveCursorHome(),
            .end_key => {
                // End key also accepts suggestion if present
                if (self.suggestion != null and self.cursor == self.length) {
                    try self.acceptSuggestion();
                } else {
                    try self.moveCursorEnd();
                }
            },
            .delete => try self.deleteChar(),
            else => {},
        }
    }

    fn historyPrevious(self: *LineEditor) !void {
        const history = self.history orelse return;
        const count = self.history_count orelse return;

        // If first time browsing history, set up search query and save line
        if (self.history_index == null) {
            if (self.length > 0) {
                // Save current line
                self.saved_line = try self.allocator.dupe(u8, self.buffer[0..self.length]);
                // Set up substring search with current input
                self.history_search_query = try self.allocator.dupe(u8, self.buffer[0..self.length]);
            }
        }

        const current_index = self.history_index orelse count.*;
        const search_query = self.history_search_query;

        // Search backward through history for matching entry
        var i: usize = current_index;
        while (i > 0) {
            i -= 1;

            if (history[i]) |entry| {
                // If we have a search query, only match entries containing it
                if (search_query) |query| {
                    if (std.mem.indexOf(u8, entry, query) != null) {
                        // Found a match!
                        try self.replaceLine(entry);
                        self.history_index = i;
                        return;
                    }
                } else {
                    // No search query, show all history
                    try self.replaceLine(entry);
                    self.history_index = i;
                    return;
                }
            }
        }

        // No more matches found (stay at current position)
    }

    fn historyNext(self: *LineEditor) !void {
        const history = self.history orelse return;
        const count = self.history_count orelse return;

        const current_index = self.history_index orelse return; // Not browsing history
        const search_query = self.history_search_query;

        // Search forward through history for matching entry
        var i: usize = current_index + 1;
        while (i < count.*) : (i += 1) {
            if (history[i]) |entry| {
                // If we have a search query, only match entries containing it
                if (search_query) |query| {
                    if (std.mem.indexOf(u8, entry, query) != null) {
                        // Found a match!
                        try self.replaceLine(entry);
                        self.history_index = i;
                        return;
                    }
                } else {
                    // No search query, show all history
                    try self.replaceLine(entry);
                    self.history_index = i;
                    return;
                }
            }
        }

        // Reached end of history, restore saved line or search query
        if (self.saved_line) |saved| {
            try self.replaceLine(saved);
            self.allocator.free(saved);
            self.saved_line = null;
        } else {
            try self.replaceLine("");
        }

        // Clear search state
        if (self.history_search_query) |query| {
            self.allocator.free(query);
            self.history_search_query = null;
        }

        self.history_index = null;
    }

    fn replaceLine(self: *LineEditor, text: []const u8) !void {
        // Clear current line
        try self.moveCursorHome();
        try self.writeBytes("\x1B[K"); // Clear to end of line

        // Copy new text
        self.length = @min(text.len, self.buffer.len);
        @memcpy(self.buffer[0..self.length], text[0..self.length]);
        self.cursor = self.length;

        // Display new text
        try self.writeBytes(self.buffer[0..self.length]);
    }

    fn writeBytes(self: *LineEditor, bytes: []const u8) !void {
        _ = self;

        // Debug logging
        const log_file = std.fs.cwd().createFile("/tmp/den_debug.log", .{ .truncate = false }) catch {
            // Continue even if logging fails
            if (builtin.os.tag == .windows) {
                const handle = std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) orelse return error.NoStdOut;
                const stdout = std.fs.File{ .handle = handle };
                _ = try stdout.write(bytes);
            } else {
                _ = try posix.write(posix.STDERR_FILENO, bytes);
            }
            return;
        };
        defer log_file.close();
        log_file.seekFromEnd(0) catch {};

        var buf: [256]u8 = undefined;
        const log_msg = std.fmt.bufPrint(&buf, "writeBytes: {d} bytes to STDERR_FILENO\n", .{bytes.len}) catch return;
        _ = log_file.write(log_msg) catch {};

        if (builtin.os.tag == .windows) {
            const handle = std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) orelse return error.NoStdOut;
            const stdout = std.fs.File{ .handle = handle };
            const written = try stdout.write(bytes);
            const w_msg = std.fmt.bufPrint(&buf, "  -> wrote {d} bytes to Windows stdout\n", .{written}) catch return;
            _ = log_file.write(w_msg) catch {};
        } else {
            const written = try posix.write(posix.STDERR_FILENO, bytes);
            const w_msg = std.fmt.bufPrint(&buf, "  -> wrote {d} bytes to stderr\n", .{written}) catch return;
            _ = log_file.write(w_msg) catch {};
        }
    }

    /// Handle tab completion
    fn handleTabCompletion(self: *LineEditor) !void {
        const completion_fn = self.completion_fn orelse return;

        // Get current line up to cursor
        const input = self.buffer[0..self.cursor];

        // If input is empty or only whitespace, insert spaces like a normal tab
        const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            try self.insertChar(' ');
            try self.insertChar(' ');
            try self.insertChar(' ');
            try self.insertChar(' ');
            return;
        }

        const word_start = self.findWordStart();

        // Check if we're cycling through existing completions
        const is_cycling = blk: {
            if (self.completion_list) |_| {
                // Check if the word start position is the same
                if (self.completion_word_start == word_start) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        if (is_cycling) {
            // Cycle to next completion
            self.completion_index = (self.completion_index + 1) % self.completion_list.?.len;
            try self.applyCurrentCompletion();
            // Update the list to show new highlight
            try self.updateCompletionListHighlight();
        } else {
            // Clear old state
            self.clearCompletionState();

            // Get new completions
            const completions = try completion_fn(input, self.allocator);

            if (completions.len == 0) {
                // No completions, beep
                for (completions) |c| {
                    self.allocator.free(c);
                }
                self.allocator.free(completions);
                try self.writeBytes("\x07");
                return;
            }

            if (completions.len == 1) {
                // Single completion - replace the word with completion
                const completion = completions[0];
                const typed_word = self.buffer[word_start..self.cursor];

                // Strip marker if present (e.g., \x02 for scripts/commands)
                const actual_completion = if (completion.len > 0 and completion[0] == '\x02')
                    completion[1..]
                else
                    completion;

                // Check if completion is a full path (contains /) and typed_word also contains /
                // This indicates mid-word expansion where we need to replace the whole thing
                const is_path_expansion = std.mem.indexOfScalar(u8, actual_completion, '/') != null and
                                         std.mem.indexOfScalar(u8, typed_word, '/') != null;

                if (is_path_expansion) {
                    // Replace the entire typed word with the completion
                    // Save any text after cursor
                    const text_after_cursor = self.buffer[self.cursor..self.length];
                    var saved_after: [4096]u8 = undefined;
                    const saved_len = text_after_cursor.len;
                    if (saved_len > 0) {
                        @memcpy(saved_after[0..saved_len], text_after_cursor);
                    }

                    // Replace buffer content from word_start
                    const new_len = word_start + actual_completion.len + saved_len;
                    if (new_len <= self.buffer.len) {
                        @memcpy(self.buffer[word_start..word_start + actual_completion.len], actual_completion);
                        if (saved_len > 0) {
                            @memcpy(self.buffer[word_start + actual_completion.len..new_len], saved_after[0..saved_len]);
                        }
                        self.length = new_len;

                        // Redraw from word_start
                        // Move cursor back to word_start
                        while (self.cursor > word_start) {
                            try self.writeBytes("\x1B[D");
                            self.cursor -= 1;
                        }

                        // Write the new content from word_start onward
                        const bytes_to_write = self.buffer[word_start..self.length];
                        try self.writeBytes(bytes_to_write);
                        try self.writeBytes("\x1B[K"); // Clear to end of line

                        // After writing, cursor is at self.length
                        // Move cursor back to after completion (word_start + actual_completion.len)
                        const target_cursor = word_start + actual_completion.len;
                        const chars_to_go_back = self.length - target_cursor;
                        var i: usize = 0;
                        while (i < chars_to_go_back) : (i += 1) {
                            try self.writeBytes("\x1B[D");
                        }
                        self.cursor = target_cursor;
                    }
                } else {
                    // Traditional completion: just append the suffix
                    // Find just the basename part (after last /)
                    const typed_basename = blk: {
                        if (std.mem.lastIndexOfScalar(u8, typed_word, '/')) |last_slash| {
                            break :blk typed_word[last_slash + 1 ..];
                        } else {
                            break :blk typed_word;
                        }
                    };

                    // Insert the rest of the completion
                    if (actual_completion.len >= typed_basename.len) {
                        const to_insert = actual_completion[typed_basename.len..];
                        for (to_insert) |c| {
                            try self.insertChar(c);
                        }
                    }
                }

                // Clean up
                for (completions) |c| {
                    self.allocator.free(c);
                }
                self.allocator.free(completions);
            } else {
                // Multiple completions - save state and show list
                self.completion_list = completions;
                self.completion_index = 0;
                self.completion_word_start = word_start;

                // Save the path prefix from the original input
                const current_word = self.buffer[word_start..self.cursor];
                const path_prefix = blk: {
                    if (std.mem.lastIndexOfScalar(u8, current_word, '/')) |last_slash| {
                        break :blk current_word[0 .. last_slash + 1];
                    } else {
                        break :blk "";
                    }
                };
                self.completion_path_prefix = if (path_prefix.len > 0)
                    try self.allocator.dupe(u8, path_prefix)
                else
                    null;

                // Show the list
                try self.displayCompletionList();
            }
        }
    }

    /// Apply the current completion from the cycling list
    fn applyCurrentCompletion(self: *LineEditor) !void {
        const completions = self.completion_list orelse return;
        const completion = completions[self.completion_index];

        // Strip marker if present (e.g., \x02 for scripts)
        const actual_completion = if (completion.len > 0 and completion[0] == '\x02')
            completion[1..]
        else
            completion;

        // Use the SAVED path prefix, not the current buffer (which may be corrupted)
        const path_prefix = self.completion_path_prefix orelse "";

        // Calculate how far back we need to go from current cursor position
        const old_word_len = self.cursor - self.completion_word_start;

        // Hide cursor to prevent flicker
        try self.writeBytes("\x1b[?25l");

        // First, move cursor back to word start position (do this BEFORE updating buffer)
        if (old_word_len > 0) {
            var buf: [32]u8 = undefined;
            const move_back = try std.fmt.bufPrint(&buf, "\x1b[{d}D", .{old_word_len});
            try self.writeBytes(move_back);
        }

        // Clear from current position to end of line
        try self.writeBytes("\x1b[K");

        // Update buffer: replace from word_start with path_prefix + completion
        self.cursor = self.completion_word_start;
        self.length = self.completion_word_start;

        // Insert path prefix (e.g., "Documents/Projects/")
        for (path_prefix) |c| {
            self.buffer[self.length] = c;
            self.length += 1;
        }

        // Insert the actual completion (without marker)
        for (actual_completion) |c| {
            self.buffer[self.length] = c;
            self.length += 1;
        }

        self.cursor = self.length;

        // Write the new text (path_prefix + completion) - cursor naturally follows
        try self.writeBytes(path_prefix);
        try self.writeBytes(actual_completion);

        // Show cursor again
        try self.writeBytes("\x1b[?25h");
    }

    /// Display completion list
    fn displayCompletionList(self: *LineEditor) !void {
        const completions = self.completion_list orelse return;

        // Save cursor, show list, restore cursor
        try self.writeBytes("\x1b[s");
        try self.writeBytes("\r\n");

        // Display one per line with highlighting
        for (completions, 0..) |completion, i| {
            // Check if this is a script (marked with \x02)
            const is_script = completion.len > 0 and completion[0] == '\x02';
            const display_text = if (is_script) completion[1..] else completion;

            // Highlight the current selection only
            if (i == self.completion_index) {
                try self.writeBytes("\x1b[30;47m"); // Black text on light gray background
            }

            try self.writeBytes(display_text);

            if (i == self.completion_index) {
                try self.writeBytes("\x1b[0m"); // Reset colors after highlight
            }

            // New line after each completion (except the last one)
            if (i < completions.len - 1) {
                try self.writeBytes("\r\n");
            }
        }

        try self.writeBytes("\x1b[u");
    }

    /// Update the completion list highlight without redrawing the input line
    fn updateCompletionListHighlight(self: *LineEditor) !void {
        const completions = self.completion_list orelse return;

        // Save current cursor position
        try self.writeBytes("\x1b[s");

        // Move to where the completion list starts (one line below current)
        try self.writeBytes("\r\n");

        // Redraw the list with updated highlighting (one per line)
        for (completions, 0..) |completion, i| {
            // Check if this is a script (marked with \x02)
            const is_script = completion.len > 0 and completion[0] == '\x02';
            const display_text = if (is_script) completion[1..] else completion;

            // Highlight the current selection only
            if (i == self.completion_index) {
                try self.writeBytes("\x1b[30;47m"); // Black text on light gray background
            }

            try self.writeBytes(display_text);

            if (i == self.completion_index) {
                try self.writeBytes("\x1b[0m"); // Reset colors after highlight
            }

            // New line after each completion (except the last one)
            if (i < completions.len - 1) {
                try self.writeBytes("\r\n");
            }
        }

        // Restore cursor position
        try self.writeBytes("\x1b[u");
    }

    /// Clear the completion list display from the screen
    fn clearCompletionDisplay(self: *LineEditor) !void {
        const completions = self.completion_list orelse return;

        // Each completion occupies one line
        const num_rows = completions.len;

        // Save cursor position
        try self.writeBytes("\x1b[s");

        // Move down and clear each line of the completion list
        var i: usize = 0;
        while (i < num_rows) : (i += 1) {
            try self.writeBytes("\r\n");
            try self.writeBytes("\x1b[2K"); // Clear entire line
        }

        // Restore cursor position
        try self.writeBytes("\x1b[u");
    }

    /// Clear completion state
    fn clearCompletionState(self: *LineEditor) void {
        if (self.completion_list) |list| {
            // Clear the completion list from screen before freeing memory
            self.clearCompletionDisplay() catch {};

            for (list) |item| {
                self.allocator.free(item);
            }
            self.allocator.free(list);
            self.completion_list = null;
        }
        if (self.completion_path_prefix) |prefix| {
            self.allocator.free(prefix);
            self.completion_path_prefix = null;
        }
        self.completion_index = 0;
        self.completion_word_start = 0;
    }

    /// Redraw the current line
    fn redrawLine(self: *LineEditor) !void {
        // Move to start of line and clear it
        try self.writeBytes("\r");
        try self.writeBytes("\x1b[2K"); // Clear entire line

        // Redraw prompt and buffer
        try self.writeBytes(self.prompt);
        try self.writeBytes(self.buffer[0..self.length]);
    }

    /// Find the start of the current word (for completion)
    fn findWordStart(self: *LineEditor) usize {
        if (self.cursor == 0) return 0;

        var pos = self.cursor;
        while (pos > 0) {
            pos -= 1;
            const c = self.buffer[pos];
            // Break on whitespace or special shell characters
            if (c == ' ' or c == '\t' or c == '|' or c == '&' or c == ';' or c == '(' or c == ')') {
                return pos + 1;
            }
        }
        return 0;
    }

    /// Search history for a suggestion matching current input
    fn updateSuggestion(self: *LineEditor) !void {
        // Clear any existing suggestion
        self.clearSuggestion();

        // Only suggest if we have input and history
        if (self.length == 0) return;
        if (self.history == null or self.history_count == null) return;

        const current_input = self.buffer[0..self.length];
        const history = self.history.?;
        const count = self.history_count.?.*;

        // Search backward through history for most recent match
        var i: usize = count;
        while (i > 0) {
            i -= 1;
            if (history[i]) |entry| {
                // Check if this history entry starts with current input
                if (entry.len > current_input.len and std.mem.startsWith(u8, entry, current_input)) {
                    // Found a match! Save the suggestion (the part after current input)
                    self.suggestion = try self.allocator.dupe(u8, entry[current_input.len..]);
                    return;
                }
            }
        }
    }

    /// Display the suggestion in gray text
    fn displaySuggestion(self: *LineEditor) !void {
        if (self.suggestion) |sugg| {
            try self.writeBytes("\x1b[90m"); // Gray text
            try self.writeBytes(sugg);
            try self.writeBytes("\x1b[0m"); // Reset

            // Move cursor back to original position
            var i: usize = 0;
            while (i < sugg.len) : (i += 1) {
                try self.writeBytes("\x1b[D");
            }
        }
    }

    /// Clear the suggestion from screen and memory
    fn clearSuggestion(self: *LineEditor) void {
        if (self.suggestion) |sugg| {
            self.allocator.free(sugg);
            self.suggestion = null;
        }
    }

    /// Accept the current suggestion
    fn acceptSuggestion(self: *LineEditor) !void {
        if (self.suggestion) |sugg| {
            // Add suggestion text to buffer
            for (sugg) |char| {
                if (self.length >= self.buffer.len) break;
                self.buffer[self.length] = char;
                self.length += 1;
                self.cursor += 1;
            }

            // Display the accepted text
            try self.writeBytes(sugg);

            self.clearSuggestion();
        }
    }

    pub fn deinit(self: *LineEditor) void {
        self.terminal.disableRawMode() catch {};
        if (self.saved_line) |saved| {
            self.allocator.free(saved);
            self.saved_line = null;
        }
        if (self.history_search_query) |query| {
            self.allocator.free(query);
            self.history_search_query = null;
        }
        self.clearCompletionState();
        self.clearSuggestion();
    }
};
