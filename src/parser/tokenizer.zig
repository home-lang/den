const std = @import("std");

// ============================================================================
// Compile-time operator lookup table for fast tokenization
// ============================================================================

const OperatorEntry = struct {
    chars: [2]u8,
    token_type: TokenType,
    value: []const u8,
};

/// Two-character operators lookup table (sorted by first char for binary search)
const two_char_operators = [_]OperatorEntry{
    .{ .chars = .{ '&', '>' }, .token_type = .redirect_both, .value = "&>" },
    .{ .chars = .{ '&', '&' }, .token_type = .and_op, .value = "&&" },
    .{ .chars = .{ '2', '>' }, .token_type = .redirect_err, .value = "2>" },
    .{ .chars = .{ '<', '<' }, .token_type = .heredoc, .value = "<<" },
    .{ .chars = .{ '<', '>' }, .token_type = .redirect_inout, .value = "<>" },
    .{ .chars = .{ '>', '>' }, .token_type = .redirect_append, .value = ">>" },
    .{ .chars = .{ '|', '|' }, .token_type = .or_op, .value = "||" },
};

/// Fast lookup for two-character operators using direct comparison
fn lookupTwoCharOperator(c1: u8, c2: u8) ?OperatorEntry {
    // Use a switch on first character for fast dispatch
    return switch (c1) {
        '&' => if (c2 == '>') two_char_operators[0] else if (c2 == '&') two_char_operators[1] else null,
        '2' => if (c2 == '>') two_char_operators[2] else null,
        '<' => if (c2 == '<') two_char_operators[3] else if (c2 == '>') two_char_operators[4] else null,
        '>' => if (c2 == '>') two_char_operators[5] else null,
        '|' => if (c2 == '|') two_char_operators[6] else null,
        else => null,
    };
}

/// Token types for shell parsing
pub const TokenType = enum {
    word, // Regular word/command
    pipe, // |
    and_op, // &&
    or_op, // ||
    semicolon, // ;
    background, // &
    redirect_out, // >
    redirect_append, // >>
    redirect_in, // <
    redirect_inout, // <>
    redirect_err, // 2>
    redirect_both, // &>
    redirect_fd_dup, // N>&M or N<&M for FD duplication
    heredoc, // <<
    herestring, // <<<
    process_sub_in, // <( for process substitution input
    process_sub_out, // >( for process substitution output
    lparen, // (
    rparen, // )
    newline,
    eof,
    // Control flow keywords
    kw_if,
    kw_then,
    kw_else,
    kw_elif,
    kw_fi,
    kw_for,
    kw_while,
    kw_do,
    kw_done,
    kw_case,
    kw_esac,
    kw_in,
    kw_function,
};

pub const Token = struct {
    type: TokenType,
    value: []const u8,
    line: usize,
    column: usize,
};

pub const Tokenizer = struct {
    input: []const u8,
    pos: usize,
    line: usize,
    column: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Tokenizer {
        return .{
            .input = input,
            .pos = 0,
            .line = 1,
            .column = 1,
            .allocator = allocator,
        };
    }

    /// Free all allocated token values (words and process substitutions)
    pub fn deinitTokens(self: *Tokenizer, tokens: []const Token) void {
        for (tokens) |token| {
            switch (token.type) {
                // These token types have dynamically allocated values
                .word, .process_sub_in, .process_sub_out => {
                    if (token.value.len > 0) {
                        self.allocator.free(token.value);
                    }
                },
                // All other types use static strings or slices from input
                else => {},
            }
        }
        self.allocator.free(tokens);
    }

    pub fn nextToken(self: *Tokenizer) !?Token {
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

        const char = self.input[self.pos];

        // Check for FD duplication patterns (N>&M or N<&M)
        if (std.ascii.isDigit(char)) {
            var lookahead = self.pos + 1;
            // Skip digits to get the FD number
            while (lookahead < self.input.len and std.ascii.isDigit(self.input[lookahead])) {
                lookahead += 1;
            }
            // Check if followed by >& or <&
            if (lookahead + 1 < self.input.len) {
                const op = self.input[lookahead .. lookahead + 2];
                if (std.mem.eql(u8, op, ">&") or std.mem.eql(u8, op, "<&")) {
                    // Look for target FD or dash
                    const target_start = lookahead + 2;
                    var target_end = target_start;
                    if (target_start < self.input.len) {
                        if (self.input[target_start] == '-') {
                            target_end = target_start + 1;
                        } else {
                            while (target_end < self.input.len and std.ascii.isDigit(self.input[target_end])) {
                                target_end += 1;
                            }
                        }
                    }
                    // If we found a valid target, create the token
                    if (target_end > target_start) {
                        const token_value = self.input[self.pos..target_end];
                        const len = target_end - self.pos;
                        self.pos = target_end;
                        self.column += len;
                        return Token{
                            .type = .redirect_fd_dup,
                            .value = token_value,
                            .line = start_line,
                            .column = start_col,
                        };
                    }
                }
            }
        }

        // Check for operators (multi-character first) using optimized lookup
        if (self.pos + 1 < self.input.len) {
            const c1 = self.input[self.pos];
            const c2 = self.input[self.pos + 1];

            // Fast path: use lookup table for two-char operators
            if (lookupTwoCharOperator(c1, c2)) |op| {
                // Special case for heredoc/herestring (<<< vs <<)
                if (op.token_type == .heredoc) {
                    self.pos += 2;
                    self.column += 2;
                    if (self.pos < self.input.len and self.input[self.pos] == '<') {
                        self.pos += 1;
                        self.column += 1;
                        return Token{
                            .type = .herestring,
                            .value = "<<<",
                            .line = start_line,
                            .column = start_col,
                        };
                    }
                    return Token{
                        .type = .heredoc,
                        .value = "<<",
                        .line = start_line,
                        .column = start_col,
                    };
                }
                // All other two-char operators
                self.pos += 2;
                self.column += 2;
                return Token{
                    .type = op.token_type,
                    .value = op.value,
                    .line = start_line,
                    .column = start_col,
                };
            }
        }

        // Single-character operators
        switch (char) {
            '|' => {
                self.pos += 1;
                self.column += 1;
                return Token{
                    .type = .pipe,
                    .value = "|",
                    .line = start_line,
                    .column = start_col,
                };
            },
            ';' => {
                self.pos += 1;
                self.column += 1;
                return Token{
                    .type = .semicolon,
                    .value = ";",
                    .line = start_line,
                    .column = start_col,
                };
            },
            '&' => {
                self.pos += 1;
                self.column += 1;
                return Token{
                    .type = .background,
                    .value = "&",
                    .line = start_line,
                    .column = start_col,
                };
            },
            '>' => {
                // Check for >( process substitution
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '(') {
                    // Process substitution >( - read the whole construct
                    return try self.readProcessSubstitution(false, start_line, start_col);
                }
                self.pos += 1;
                self.column += 1;
                return Token{
                    .type = .redirect_out,
                    .value = ">",
                    .line = start_line,
                    .column = start_col,
                };
            },
            '<' => {
                // Check for <( process substitution
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '(') {
                    // Process substitution <( - read the whole construct
                    return try self.readProcessSubstitution(true, start_line, start_col);
                }
                self.pos += 1;
                self.column += 1;
                return Token{
                    .type = .redirect_in,
                    .value = "<",
                    .line = start_line,
                    .column = start_col,
                };
            },
            '(' => {
                self.pos += 1;
                self.column += 1;
                return Token{
                    .type = .lparen,
                    .value = "(",
                    .line = start_line,
                    .column = start_col,
                };
            },
            ')' => {
                self.pos += 1;
                self.column += 1;
                return Token{
                    .type = .rparen,
                    .value = ")",
                    .line = start_line,
                    .column = start_col,
                };
            },
            '\n' => {
                self.pos += 1;
                self.line += 1;
                self.column = 1;
                return Token{
                    .type = .newline,
                    .value = "\n",
                    .line = start_line,
                    .column = start_col,
                };
            },
            else => {
                // Parse a word (may include quotes)
                return try self.parseWord(start_line, start_col);
            },
        }
    }

    fn getKeywordType(self: *Tokenizer, word: []const u8) TokenType {
        _ = self;
        if (std.mem.eql(u8, word, "if")) return .kw_if;
        if (std.mem.eql(u8, word, "then")) return .kw_then;
        if (std.mem.eql(u8, word, "else")) return .kw_else;
        if (std.mem.eql(u8, word, "elif")) return .kw_elif;
        if (std.mem.eql(u8, word, "fi")) return .kw_fi;
        if (std.mem.eql(u8, word, "for")) return .kw_for;
        if (std.mem.eql(u8, word, "while")) return .kw_while;
        if (std.mem.eql(u8, word, "do")) return .kw_do;
        if (std.mem.eql(u8, word, "done")) return .kw_done;
        if (std.mem.eql(u8, word, "case")) return .kw_case;
        if (std.mem.eql(u8, word, "esac")) return .kw_esac;
        if (std.mem.eql(u8, word, "in")) return .kw_in;
        if (std.mem.eql(u8, word, "function")) return .kw_function;
        return .word;
    }

    fn parseWord(self: *Tokenizer, start_line: usize, start_col: usize) !Token {
        var in_single_quote = false;
        var in_double_quote = false;
        var in_ansi_quote = false; // $'...' ANSI-C quoting
        var subst_depth: u32 = 0; // Track $(...) / $((...)) nesting depth
        var brace_depth: u32 = 0; // Track ${...} parameter expansion depth
        var in_backtick = false; // Track `...` command substitution

        // Build the word with escape processing
        var word_buffer: [4096]u8 = undefined;
        var word_len: usize = 0;

        while (self.pos < self.input.len) {
            const char = self.input[self.pos];

            // Handle backslash escapes (not in regular single quotes, but yes in ANSI quotes)
            if (char == '\\' and (!in_single_quote or in_ansi_quote)) {
                if (self.pos + 1 < self.input.len) {
                    const next_char = self.input[self.pos + 1];
                    if (in_ansi_quote) {
                        // ANSI-C escape: always interpret
                        self.pos += 2;
                        self.column += 2;
                        const result = self.processAnsiEscape(next_char);
                        if (word_len < word_buffer.len) {
                            word_buffer[word_len] = result;
                            word_len += 1;
                        }
                    } else if (in_double_quote) {
                        // In double quotes: backslash is only special before $ ` " \ newline
                        if (next_char == '$' or next_char == '`' or next_char == '"' or
                            next_char == '\\' or next_char == '\n')
                        {
                            // Consume backslash, use next char literally
                            self.pos += 2;
                            self.column += 2;
                            if (next_char != '\n') {
                                if (word_len < word_buffer.len) {
                                    word_buffer[word_len] = next_char;
                                    word_len += 1;
                                }
                            }
                        } else {
                            // Preserve the backslash
                            if (word_len < word_buffer.len) {
                                word_buffer[word_len] = '\\';
                                word_len += 1;
                            }
                            self.pos += 1;
                            self.column += 1;
                        }
                    } else {
                        // Outside quotes: backslash escapes next char
                        self.pos += 2;
                        self.column += 2;
                        if (word_len < word_buffer.len) {
                            word_buffer[word_len] = next_char;
                            word_len += 1;
                        }
                    }
                } else {
                    // Trailing backslash
                    self.pos += 1;
                    self.column += 1;
                }
                continue;
            }

            // Check for $' ANSI-C quoting start
            if (char == '$' and !in_single_quote and !in_double_quote and !in_ansi_quote) {
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '\'') {
                    in_ansi_quote = true;
                    self.pos += 2; // Skip $'
                    self.column += 2;
                    continue;
                }
            }

            // Handle quotes
            if (char == '\'' and !in_double_quote) {
                if (in_ansi_quote) {
                    in_ansi_quote = false;
                } else {
                    in_single_quote = !in_single_quote;
                }
                self.pos += 1;
                self.column += 1;
                continue;
            }

            if (char == '"' and !in_single_quote and !in_ansi_quote) {
                in_double_quote = !in_double_quote;
                self.pos += 1;
                self.column += 1;
                continue;
            }

            // If not in quotes, handle special characters
            if (!in_single_quote and !in_double_quote and !in_ansi_quote) {
                // Toggle backtick command substitution tracking
                if (char == '`') {
                    in_backtick = !in_backtick;
                    // Add backtick to word buffer and continue (don't break)
                    if (word_len < word_buffer.len) {
                        word_buffer[word_len] = char;
                        word_len += 1;
                    }
                    self.pos += 1;
                    self.column += 1;
                    continue;
                }
                if (char == '{') {
                    // Check if this is ${ - parameter expansion
                    if (word_len > 0 and word_buffer[word_len - 1] == '$') {
                        brace_depth += 1;
                    } else if (brace_depth > 0) {
                        brace_depth += 1;
                    }
                } else if (char == '}' and brace_depth > 0) {
                    brace_depth -= 1;
                } else if (char == '(') {
                    // Check if this is $( or $(( - command/arithmetic substitution
                    if (word_len > 0 and word_buffer[word_len - 1] == '$') {
                        subst_depth += 1;
                        // Don't break - consume as part of word
                    } else if (subst_depth > 0) {
                        // Nested parenthesis inside substitution
                        subst_depth += 1;
                    } else if (!in_backtick and brace_depth == 0) {
                        break; // Standalone ( - break (but not inside backticks/braces)
                    }
                } else if (char == ')') {
                    if (subst_depth > 0) {
                        subst_depth -= 1;
                        // Don't break - consume as part of word
                    } else if (!in_backtick and brace_depth == 0) {
                        break; // Standalone ) - break (but not inside backticks/braces)
                    }
                } else if (subst_depth == 0 and brace_depth == 0 and !in_backtick) {
                    // Only break on special chars when not inside a substitution, brace, or backtick
                    if (std.ascii.isWhitespace(char) or
                        char == '|' or char == ';' or char == '&' or
                        char == '>' or char == '<')
                    {
                        break;
                    }
                }
                // When subst_depth > 0 or in_backtick, all chars are part of the command
            }

            // Add character to word
            // If in single quotes, escape special characters ($, `) so they're not expanded
            if (in_single_quote and (char == '$' or char == '`')) {
                if (word_len + 1 < word_buffer.len) {
                    word_buffer[word_len] = '\\';
                    word_len += 1;
                    word_buffer[word_len] = char;
                    word_len += 1;
                }
            } else if (word_len < word_buffer.len) {
                word_buffer[word_len] = char;
                word_len += 1;
            }

            self.pos += 1;
            self.column += 1;
        }

        // Allocate and copy the processed word
        const word = try self.allocator.dupe(u8, word_buffer[0..word_len]);

        // Check for keywords (only if not quoted)
        const token_type = if (in_single_quote or in_double_quote or in_ansi_quote)
            TokenType.word
        else
            self.getKeywordType(word);

        return Token{
            .type = token_type,
            .value = word,
            .line = start_line,
            .column = start_col,
        };
    }

    /// Process ANSI-C escape sequences for $'...' quoting
    fn processAnsiEscape(self: *Tokenizer, char: u8) u8 {
        _ = self;
        return switch (char) {
            'a' => 0x07, // Alert (bell)
            'b' => 0x08, // Backspace
            'e', 'E' => 0x1B, // Escape
            'f' => 0x0C, // Form feed
            'n' => 0x0A, // Newline
            'r' => 0x0D, // Carriage return
            't' => 0x09, // Horizontal tab
            'v' => 0x0B, // Vertical tab
            '\\' => '\\', // Backslash
            '\'' => '\'', // Single quote
            '"' => '"', // Double quote
            '?' => '?', // Question mark
            '0' => 0x00, // Null (simplified - full octal would need more parsing)
            else => char, // Unknown escape - return as is
        };
    }

    /// Read a process substitution <(...) or >(...)
    /// Returns the entire construct including the delimiters as the token value
    fn readProcessSubstitution(self: *Tokenizer, is_input: bool, start_line: usize, start_col: usize) !Token {
        const start_pos = self.pos;

        // Skip the < or > and the (
        self.pos += 2;
        self.column += 2;

        // Track nesting level of parentheses
        var depth: u32 = 1;
        var in_single_quote = false;
        var in_double_quote = false;

        while (self.pos < self.input.len and depth > 0) {
            const c = self.input[self.pos];

            if (in_single_quote) {
                if (c == '\'') {
                    in_single_quote = false;
                }
            } else if (in_double_quote) {
                if (c == '"' and (self.pos == 0 or self.input[self.pos - 1] != '\\')) {
                    in_double_quote = false;
                }
            } else {
                switch (c) {
                    '\'' => in_single_quote = true,
                    '"' => in_double_quote = true,
                    '(' => depth += 1,
                    ')' => depth -= 1,
                    else => {},
                }
            }

            if (c == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }

            if (depth > 0) {
                self.pos += 1;
            }
        }

        if (depth == 0) {
            // Include the closing paren
            self.pos += 1;
            self.column += 1;
        }

        // Get the full token value including delimiters
        const value = self.input[start_pos..self.pos];
        const duped_value = try self.allocator.dupe(u8, value);

        return Token{
            .type = if (is_input) .process_sub_in else .process_sub_out,
            .value = duped_value,
            .line = start_line,
            .column = start_col,
        };
    }

    pub fn tokenize(self: *Tokenizer) ![]Token {
        // Manual implementation to avoid ArrayList API issues in Zig 0.15
        var tokens_buffer: [256]Token = undefined;
        var token_count: usize = 0;

        while (try self.nextToken()) |token| {
            if (token.type == .eof) break;
            if (token.type == .newline) continue; // Skip newlines for now

            if (token_count >= tokens_buffer.len) {
                return error.TooManyTokens;
            }

            tokens_buffer[token_count] = token;
            token_count += 1;
        }

        // Allocate and copy
        const result = try self.allocator.alloc(Token, token_count);
        @memcpy(result, tokens_buffer[0..token_count]);
        return result;
    }
};

test "tokenizer basic" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo hello");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(TokenType.word, tokens[0].type);
    try std.testing.expectEqualStrings("echo", tokens[0].value);
    try std.testing.expectEqual(TokenType.word, tokens[1].type);
    try std.testing.expectEqualStrings("hello", tokens[1].value);
}

test "tokenizer pipe" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "ls | grep foo");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqual(TokenType.word, tokens[0].type);
    try std.testing.expectEqual(TokenType.pipe, tokens[1].type);
    try std.testing.expectEqual(TokenType.word, tokens[2].type);
    try std.testing.expectEqual(TokenType.word, tokens[3].type);
}

test "tokenizer operators" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "cmd1 && cmd2 || cmd3");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 5), tokens.len);
    try std.testing.expectEqual(TokenType.and_op, tokens[1].type);
    try std.testing.expectEqual(TokenType.or_op, tokens[3].type);
}
