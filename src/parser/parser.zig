const std = @import("std");
const tokenizer_mod = @import("tokenizer.zig");
const types = @import("../types/mod.zig");

const Tokenizer = tokenizer_mod.Tokenizer;
const Token = tokenizer_mod.Token;
const TokenType = tokenizer_mod.TokenType;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []Token,
    pos: usize,

    pub fn init(allocator: std.mem.Allocator, tokens: []Token) Parser {
        return .{
            .allocator = allocator,
            .tokens = tokens,
            .pos = 0,
        };
    }

    pub fn parse(self: *Parser) !types.CommandChain {
        var commands_buffer: [32]types.ParsedCommand = undefined;
        var cmd_count: usize = 0;

        var operators_buffer: [31]types.Operator = undefined;
        var op_count: usize = 0;

        // Parse first command
        const first_cmd = try self.parseCommand();
        commands_buffer[cmd_count] = first_cmd;
        cmd_count += 1;

        // Parse chains with operators
        while (self.pos < self.tokens.len) {
            const token = self.tokens[self.pos];

            const op: types.Operator = switch (token.type) {
                .pipe => .pipe,
                .and_op => .and_op,
                .or_op => .or_op,
                .semicolon => .semicolon,
                .background => .background,
                else => break,
            };

            self.pos += 1; // Consume operator

            if (op_count >= operators_buffer.len) return error.TooManyOperators;
            operators_buffer[op_count] = op;
            op_count += 1;

            // Background operator can be at end of input
            if (op == .background) {
                break;
            }

            if (self.pos >= self.tokens.len) {
                return error.UnexpectedEndOfInput;
            }

            const next_cmd = try self.parseCommand();
            if (cmd_count >= commands_buffer.len) return error.TooManyCommands;
            commands_buffer[cmd_count] = next_cmd;
            cmd_count += 1;
        }

        // Allocate and copy
        const commands = try self.allocator.alloc(types.ParsedCommand, cmd_count);
        @memcpy(commands, commands_buffer[0..cmd_count]);

        const operators = try self.allocator.alloc(types.Operator, op_count);
        @memcpy(operators, operators_buffer[0..op_count]);

        return types.CommandChain{
            .commands = commands,
            .operators = operators,
        };
    }

    fn parseCommand(self: *Parser) !types.ParsedCommand {
        var args_buffer: [64][]const u8 = undefined;
        var arg_count: usize = 0;

        var redir_buffer: [8]types.Redirection = undefined;
        var redir_count: usize = 0;

        var command_name: ?[]const u8 = null;

        while (self.pos < self.tokens.len) {
            const token = self.tokens[self.pos];

            switch (token.type) {
                // Words and keyword tokens can be command names or arguments
                // Keywords like 'done', 'fi', 'if' etc. can be used as arguments in command context
                .word, .process_sub_in, .process_sub_out,
                .kw_if, .kw_then, .kw_else, .kw_elif, .kw_fi,
                .kw_for, .kw_while, .kw_do, .kw_done,
                .kw_case, .kw_esac, .kw_in, .kw_function => {
                    // Process substitution tokens are treated as word arguments
                    // The value contains the full construct like "<(echo hello)"
                    const value = try self.allocator.dupe(u8, token.value);
                    if (command_name == null) {
                        command_name = value;
                    } else {
                        if (arg_count >= args_buffer.len) return error.TooManyArguments;
                        args_buffer[arg_count] = value;
                        arg_count += 1;
                    }
                    self.pos += 1;
                },
                .redirect_out => {
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or self.tokens[self.pos].type != .word) {
                        return error.RedirectionMissingTarget;
                    }
                    const target = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .output_truncate,
                        .fd = 1,
                        .target = target,
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .redirect_append => {
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or self.tokens[self.pos].type != .word) {
                        return error.RedirectionMissingTarget;
                    }
                    const target = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .output_append,
                        .fd = 1,
                        .target = target,
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .redirect_in => {
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or self.tokens[self.pos].type != .word) {
                        return error.RedirectionMissingTarget;
                    }
                    const target = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .input,
                        .fd = 0,
                        .target = target,
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .redirect_inout => {
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or self.tokens[self.pos].type != .word) {
                        return error.RedirectionMissingTarget;
                    }
                    const target = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .input_output,
                        .fd = 0,
                        .target = target,
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .redirect_err => {
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or self.tokens[self.pos].type != .word) {
                        return error.RedirectionMissingTarget;
                    }
                    const target = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .output_truncate,
                        .fd = 2,
                        .target = target,
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .heredoc => {
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or self.tokens[self.pos].type != .word) {
                        return error.RedirectionMissingTarget;
                    }
                    const delimiter = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .heredoc,
                        .fd = 0,
                        .target = delimiter,
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .herestring => {
                    self.pos += 1;
                    if (self.pos >= self.tokens.len or self.tokens[self.pos].type != .word) {
                        return error.RedirectionMissingTarget;
                    }
                    const content = try self.allocator.dupe(u8, self.tokens[self.pos].value);
                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .herestring,
                        .fd = 0,
                        .target = content,
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                .redirect_fd_dup => {
                    // Parse token like "2>&1" or "3<&0"
                    const token_value = self.tokens[self.pos].value;

                    // Find the operator position (>& or <&)
                    var op_pos: usize = 0;
                    while (op_pos < token_value.len) : (op_pos += 1) {
                        if (op_pos + 1 < token_value.len) {
                            if ((token_value[op_pos] == '>' or token_value[op_pos] == '<') and
                                token_value[op_pos + 1] == '&') {
                                break;
                            }
                        }
                    }

                    // Extract source FD
                    const source_fd_str = token_value[0..op_pos];
                    const source_fd = std.fmt.parseInt(u32, source_fd_str, 10) catch {
                        return error.InvalidFileDescriptor;
                    };

                    // Extract target FD (skip >& or <&)
                    const target_fd_str = token_value[op_pos + 2 ..];
                    const target_fd_int = if (std.mem.eql(u8, target_fd_str, "-"))
                        @as(i32, -1) // Close FD
                    else
                        std.fmt.parseInt(i32, target_fd_str, 10) catch {
                            return error.InvalidFileDescriptor;
                        };

                    if (redir_count >= redir_buffer.len) return error.TooManyRedirections;
                    redir_buffer[redir_count] = .{
                        .kind = .fd_duplicate,
                        .fd = source_fd,
                        .target = try std.fmt.allocPrint(self.allocator, "{d}", .{target_fd_int}),
                    };
                    redir_count += 1;
                    self.pos += 1;
                },
                else => break, // Stop at operators or other non-command tokens
            }
        }

        if (command_name == null) {
            return error.EmptyCommand;
        }

        // Allocate and copy
        const args = try self.allocator.alloc([]const u8, arg_count);
        @memcpy(args, args_buffer[0..arg_count]);

        const redirections = try self.allocator.alloc(types.Redirection, redir_count);
        @memcpy(redirections, redir_buffer[0..redir_count]);

        return types.ParsedCommand{
            .name = command_name.?,
            .args = args,
            .redirections = redirections,
            .type = .external,
        };
    }
};

test "parser basic command" {
    const allocator = std.testing.allocator;

    var t = Tokenizer.init(allocator, "echo hello world");
    const tokens = try t.tokenize();
    defer allocator.free(tokens);

    var p = Parser.init(allocator, tokens);
    var chain = try p.parse();
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("echo", chain.commands[0].name);
    try std.testing.expectEqual(@as(usize, 2), chain.commands[0].args.len);
    try std.testing.expectEqualStrings("hello", chain.commands[0].args[0]);
}

test "parser pipeline" {
    const allocator = std.testing.allocator;

    var t = Tokenizer.init(allocator, "ls | grep foo");
    const tokens = try t.tokenize();
    defer allocator.free(tokens);

    var p = Parser.init(allocator, tokens);
    var chain = try p.parse();
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), chain.commands.len);
    try std.testing.expectEqual(@as(usize, 1), chain.operators.len);
    try std.testing.expectEqual(types.Operator.pipe, chain.operators[0]);
}
