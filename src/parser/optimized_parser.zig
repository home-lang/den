// Optimized single-pass parser for Den Shell
const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const TokenType = tokenizer.TokenType;
const Tokenizer = tokenizer.Tokenizer;

/// Optimized parser that combines tokenization and parsing in a single pass
pub const OptimizedParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize,
    line: usize,
    column: usize,

    // Token buffer to avoid repeated allocations
    token_buffer: [256]Token,
    token_count: usize,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) OptimizedParser {
        return .{
            .allocator = allocator,
            .input = input,
            .pos = 0,
            .line = 1,
            .column = 1,
            .token_buffer = undefined,
            .token_count = 0,
        };
    }

    /// Fast path for simple commands (no pipes, redirects, etc.)
    pub fn parseSimpleCommand(self: *OptimizedParser) !?SimpleCommand {
        self.skipWhitespace();

        if (self.pos >= self.input.len) {
            return null;
        }

        var cmd = SimpleCommand{
            .name = "",
            .args = undefined,
            .arg_count = 0,
        };

        // Parse command name (fast path - no allocation)
        const name_start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (std.ascii.isWhitespace(c) or c == '|' or c == ';' or c == '&' or c == '>' or c == '<') {
                break;
            }
            self.pos += 1;
        }

        if (self.pos == name_start) {
            return null;
        }

        cmd.name = self.input[name_start..self.pos];

        // Parse arguments (fast path - stack allocated)
        while (self.pos < self.input.len) {
            self.skipWhitespace();

            if (self.pos >= self.input.len) break;

            const c = self.input[self.pos];
            if (c == '|' or c == ';' or c == '&' or c == '>' or c == '<' or c == '\n') {
                break;
            }

            const arg_start = self.pos;
            while (self.pos < self.input.len) {
                const ch = self.input[self.pos];
                if (std.ascii.isWhitespace(ch) or ch == '|' or ch == ';' or ch == '&') {
                    break;
                }
                self.pos += 1;
            }

            if (self.pos > arg_start and cmd.arg_count < 64) {
                cmd.args[cmd.arg_count] = self.input[arg_start..self.pos];
                cmd.arg_count += 1;
            }
        }

        return cmd;
    }

    fn skipWhitespace(self: *OptimizedParser) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (!std.ascii.isWhitespace(c) or c == '\n') {
                break;
            }
            self.pos += 1;
            self.column += 1;
        }
    }

    /// Check if input contains complex features (pipes, redirects, background)
    pub fn isSimpleCommand(input: []const u8) bool {
        for (input) |c| {
            if (c == '|' or c == '>' or c == '<' or c == '&' or c == ';') {
                return false;
            }
        }
        return true;
    }
};

/// Simple command structure (stack-allocated for performance)
pub const SimpleCommand = struct {
    name: []const u8,
    args: [64][]const u8,
    arg_count: usize,

    pub fn getArgs(self: *const SimpleCommand) []const []const u8 {
        return self.args[0..self.arg_count];
    }
};

/// Single-pass tokenizer that reuses buffer
pub const StreamingTokenizer = struct {
    input: []const u8,
    pos: usize,
    line: usize,
    column: usize,

    pub fn init(input: []const u8) StreamingTokenizer {
        return .{
            .input = input,
            .pos = 0,
            .line = 1,
            .column = 1,
        };
    }

    pub fn next(self: *StreamingTokenizer) ?Token {
        // Skip whitespace
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) {
            if (self.input[self.pos] == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.pos += 1;
        }

        if (self.pos >= self.input.len) {
            return Token{
                .type = .eof,
                .value = "",
                .line = self.line,
                .column = self.column,
            };
        }

        const start_line = self.line;
        const start_col = self.column;
        const start_pos = self.pos;

        // Fast operator detection (no string comparisons)
        const char = self.input[self.pos];
        if (self.pos + 1 < self.input.len) {
            const next_char = self.input[self.pos + 1];

            // Two-character operators
            if (char == '&' and next_char == '&') {
                self.pos += 2;
                self.column += 2;
                return Token{
                    .type = .and_op,
                    .value = "&&",
                    .line = start_line,
                    .column = start_col,
                };
            } else if (char == '|' and next_char == '|') {
                self.pos += 2;
                self.column += 2;
                return Token{
                    .type = .or_op,
                    .value = "||",
                    .line = start_line,
                    .column = start_col,
                };
            } else if (char == '>' and next_char == '>') {
                self.pos += 2;
                self.column += 2;
                return Token{
                    .type = .redirect_append,
                    .value = ">>",
                    .line = start_line,
                    .column = start_col,
                };
            }
        }

        // Single-character operators
        const token_type: TokenType = switch (char) {
            '|' => .pipe,
            ';' => .semicolon,
            '&' => .background,
            '>' => .redirect_out,
            '<' => .redirect_in,
            '(' => .lparen,
            ')' => .rparen,
            '\n' => .newline,
            else => {
                // Parse word
                while (self.pos < self.input.len) {
                    const c = self.input[self.pos];
                    if (std.ascii.isWhitespace(c) or
                        c == '|' or c == ';' or c == '&' or
                        c == '>' or c == '<' or c == '(' or c == ')')
                    {
                        break;
                    }
                    self.pos += 1;
                    self.column += 1;
                }

                return Token{
                    .type = .word,
                    .value = self.input[start_pos..self.pos],
                    .line = start_line,
                    .column = start_col,
                };
            },
        };

        self.pos += 1;
        if (char == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }

        return Token{
            .type = token_type,
            .value = self.input[start_pos..self.pos],
            .line = start_line,
            .column = start_col,
        };
    }
};

// Tests
test "OptimizedParser simple command" {
    var parser = OptimizedParser.init(std.testing.allocator, "echo hello world");

    const cmd = try parser.parseSimpleCommand();
    try std.testing.expect(cmd != null);

    try std.testing.expectEqualStrings("echo", cmd.?.name);
    try std.testing.expectEqual(@as(usize, 2), cmd.?.arg_count);
    try std.testing.expectEqualStrings("hello", cmd.?.args[0]);
    try std.testing.expectEqualStrings("world", cmd.?.args[1]);
}

test "StreamingTokenizer performance" {
    var tokenizer_stream = StreamingTokenizer.init("echo hello && ls -la | grep foo");

    var count: usize = 0;
    while (tokenizer_stream.next()) |token| {
        if (token.type == .eof) break;
        count += 1;
    }

    try std.testing.expect(count > 0);
}
