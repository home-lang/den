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
        }

        // Alt+key sequences (ESC followed by character)
        if (bytes[0] == 0x1B and bytes.len >= 2) {
            return .unknown;
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
    completion_fn: ?CompletionFn = null, // Callback for tab completion
    // Completion cycling state
    completion_list: ?[][]const u8 = null,
    completion_index: usize = 0,
    completion_word_start: usize = 0,
    completion_path_prefix: ?[]const u8 = null, // Save the path prefix (e.g., "Documents/Projects/")

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
                    try self.writeBytes("\r\n");
                    try self.terminal.disableRawMode();

                    if (self.length == 0) return try self.allocator.dupe(u8, "");
                    return try self.allocator.dupe(u8, self.buffer[0..self.length]);
                },
                0x03 => {
                    // Ctrl+C
                    try self.writeBytes("^C\r\n");
                    try self.terminal.disableRawMode();
                    return error.Interrupted;
                },
                0x04 => {
                    // Ctrl+D (EOF)
                    if (self.length == 0) {
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
                0x15 => {
                    self.clearCompletionState();
                    try self.killToStart(); // Ctrl+U
                },
                0x17 => {
                    self.clearCompletionState();
                    try self.deleteWord(); // Ctrl+W
                },
                0x09 => {
                    // Tab - handle completion
                    try self.handleTabCompletion();
                },
                0x7F, 0x08 => {
                    // Backspace (DEL or BS)
                    self.clearCompletionState();
                    try self.backspace();
                },
                0x20...0x7E => {
                    // Printable ASCII
                    self.clearCompletionState();
                    try self.insertChar(byte);
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

    fn insertChar(self: *LineEditor, char: u8) !void {
        if (self.length >= self.buffer.len) return;

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
    }

    fn backspace(self: *LineEditor) !void {
        if (self.cursor == 0) return;

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
    }

    fn deleteChar(self: *LineEditor) !void {
        if (self.cursor >= self.length) return;

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
        try self.writeBytes("\x1B[K"); // Clear to end of line
        self.length = self.cursor;
    }

    fn killToStart(self: *LineEditor) !void {
        if (self.cursor == 0) return;

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

    fn deleteWord(self: *LineEditor) !void {
        if (self.cursor == 0) return;

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
        switch (seq) {
            .up_arrow => try self.historyPrevious(),
            .down_arrow => try self.historyNext(),
            .left_arrow => try self.moveCursorLeft(),
            .right_arrow => try self.moveCursorRight(),
            .home => try self.moveCursorHome(),
            .end_key => try self.moveCursorEnd(),
            .delete => try self.deleteChar(),
            else => {},
        }
    }

    fn historyPrevious(self: *LineEditor) !void {
        const history = self.history orelse return;
        const count = self.history_count orelse return;

        // Save current line if first time browsing history
        if (self.history_index == null and self.length > 0) {
            self.saved_line = try self.allocator.dupe(u8, self.buffer[0..self.length]);
        }

        const current_index = self.history_index orelse count.*;

        if (current_index == 0) return; // At oldest entry

        const new_index = current_index - 1;
        const entry = history[new_index] orelse return;

        // Replace current line with history entry
        try self.replaceLine(entry);
        self.history_index = new_index;
    }

    fn historyNext(self: *LineEditor) !void {
        const history = self.history orelse return;
        const count = self.history_count orelse return;

        const current_index = self.history_index orelse return; // Not browsing history

        if (current_index >= count.* - 1) {
            // At newest entry, restore saved line
            if (self.saved_line) |saved| {
                try self.replaceLine(saved);
                self.allocator.free(saved);
                self.saved_line = null;
            } else {
                try self.replaceLine("");
            }
            self.history_index = null;
            return;
        }

        const new_index = current_index + 1;
        const entry = history[new_index] orelse return;

        try self.replaceLine(entry);
        self.history_index = new_index;
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
                // Single completion - insert it directly
                const completion = completions[0];
                const typed_word = self.buffer[word_start..self.cursor];

                // Find just the basename part (after last /)
                const typed_basename = blk: {
                    if (std.mem.lastIndexOfScalar(u8, typed_word, '/')) |last_slash| {
                        break :blk typed_word[last_slash + 1 ..];
                    } else {
                        break :blk typed_word;
                    }
                };

                // Insert the rest of the completion
                if (completion.len >= typed_basename.len) {
                    const to_insert = completion[typed_basename.len..];
                    for (to_insert) |c| {
                        try self.insertChar(c);
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

        // Use the SAVED path prefix, not the current buffer (which may be corrupted)
        const path_prefix = self.completion_path_prefix orelse "";

        // Save the old length for terminal cursor positioning
        const old_word_len = self.cursor - self.completion_word_start;

        // Update buffer: replace from word_start with path_prefix + completion
        self.cursor = self.completion_word_start;
        self.length = self.completion_word_start;

        // Insert path prefix (e.g., "Documents/Projects/")
        for (path_prefix) |c| {
            self.buffer[self.length] = c;
            self.length += 1;
        }

        // Insert the completion basename (e.g., "better-dx/")
        for (completion) |c| {
            self.buffer[self.length] = c;
            self.length += 1;
        }

        self.cursor = self.length;

        // Update terminal display
        // Move cursor back to where the old word started
        if (old_word_len > 0) {
            var buf: [32]u8 = undefined;
            const move_back = try std.fmt.bufPrint(&buf, "\x1b[{d}D", .{old_word_len});
            try self.writeBytes(move_back);
        }

        // Clear to end of line
        try self.writeBytes("\x1b[K");

        // Write the new text (path_prefix + completion)
        try self.writeBytes(path_prefix);
        try self.writeBytes(completion);
    }

    /// Display completion list
    fn displayCompletionList(self: *LineEditor) !void {
        const completions = self.completion_list orelse return;

        // Save cursor, show list, restore cursor
        try self.writeBytes("\x1b[s");
        try self.writeBytes("\r\n");

        // Display in columns
        var col: usize = 0;
        const max_cols = 4;
        for (completions, 0..) |completion, i| {
            try self.writeBytes(completion);
            try self.writeBytes("  ");
            col += 1;

            if (col >= max_cols or i == completions.len - 1) {
                if (i < completions.len - 1) {
                    try self.writeBytes("\r\n");
                }
                col = 0;
            }
        }

        try self.writeBytes("\x1b[u");
    }

    /// Clear completion state
    fn clearCompletionState(self: *LineEditor) void {
        if (self.completion_list) |list| {
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

    pub fn deinit(self: *LineEditor) void {
        self.terminal.disableRawMode() catch {};
        if (self.saved_line) |saved| {
            self.allocator.free(saved);
            self.saved_line = null;
        }
        self.clearCompletionState();
    }
};
