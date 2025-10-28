const std = @import("std");

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
    redirect_err, // 2>
    redirect_both, // &>
    redirect_fd_dup, // N>&M or N<&M for FD duplication
    heredoc, // <<
    herestring, // <<<
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

        // Check for operators (multi-character first)
        if (self.pos + 1 < self.input.len) {
            const two_char = self.input[self.pos .. self.pos + 2];

            if (std.mem.eql(u8, two_char, "&&")) {
                self.pos += 2;
                self.column += 2;
                return Token{
                    .type = .and_op,
                    .value = "&&",
                    .line = start_line,
                    .column = start_col,
                };
            } else if (std.mem.eql(u8, two_char, "||")) {
                self.pos += 2;
                self.column += 2;
                return Token{
                    .type = .or_op,
                    .value = "||",
                    .line = start_line,
                    .column = start_col,
                };
            } else if (std.mem.eql(u8, two_char, ">>")) {
                self.pos += 2;
                self.column += 2;
                return Token{
                    .type = .redirect_append,
                    .value = ">>",
                    .line = start_line,
                    .column = start_col,
                };
            } else if (std.mem.eql(u8, two_char, "&>")) {
                self.pos += 2;
                self.column += 2;
                return Token{
                    .type = .redirect_both,
                    .value = "&>",
                    .line = start_line,
                    .column = start_col,
                };
            } else if (std.mem.eql(u8, two_char, "2>")) {
                self.pos += 2;
                self.column += 2;
                return Token{
                    .type = .redirect_err,
                    .value = "2>",
                    .line = start_line,
                    .column = start_col,
                };
            } else if (std.mem.eql(u8, two_char, "<<")) {
                self.pos += 2;
                self.column += 2;
                // Check for <<<
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
        const start_pos = self.pos;
        var in_single_quote = false;
        var in_double_quote = false;

        while (self.pos < self.input.len) {
            const char = self.input[self.pos];

            // Handle quotes
            if (char == '\'' and !in_double_quote) {
                in_single_quote = !in_single_quote;
                self.pos += 1;
                self.column += 1;
                continue;
            }

            if (char == '"' and !in_single_quote) {
                in_double_quote = !in_double_quote;
                self.pos += 1;
                self.column += 1;
                continue;
            }

            // If not in quotes, stop at special characters
            if (!in_single_quote and !in_double_quote) {
                if (std.ascii.isWhitespace(char) or
                    char == '|' or char == ';' or char == '&' or
                    char == '>' or char == '<' or char == '(' or char == ')')
                {
                    break;
                }
            }

            self.pos += 1;
            self.column += 1;
        }

        const word = self.input[start_pos..self.pos];

        // Check for keywords (only if not quoted)
        const token_type = if (in_single_quote or in_double_quote)
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
