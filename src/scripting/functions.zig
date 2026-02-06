const std = @import("std");
const Shell = @import("../shell.zig").Shell;
const control_flow = @import("control_flow.zig");
const ControlFlowParser = control_flow.ControlFlowParser;
const ControlFlowExecutor = control_flow.ControlFlowExecutor;

/// Check if input contains a word (surrounded by word boundaries: start/end/space/semicolon)
fn containsWord(input: []const u8, word: []const u8) bool {
    var pos: usize = 0;
    while (pos + word.len <= input.len) {
        if (std.mem.eql(u8, input[pos..][0..word.len], word)) {
            const at_start = pos == 0 or input[pos - 1] == ' ' or input[pos - 1] == ';' or input[pos - 1] == '\t';
            const at_end = pos + word.len == input.len or input[pos + word.len] == ' ' or input[pos + word.len] == ';' or input[pos + word.len] == '\t' or input[pos + word.len] == '\n';
            if (at_start and at_end) return true;
        }
        pos += 1;
    }
    return false;
}

/// Function definition
pub const Function = struct {
    name: []const u8,
    body: [][]const u8, // Lines of the function body
    is_exported: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Function) void {
        self.allocator.free(self.name);
        for (self.body) |line| {
            self.allocator.free(line);
        }
        self.allocator.free(self.body);
    }
};

/// Function call frame (for call stack)
pub const CallFrame = struct {
    function_name: []const u8,
    positional_params: [64]?[]const u8,
    positional_params_count: usize,
    local_vars: std.StringHashMap([]const u8),
    return_requested: bool,
    return_code: i32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, function_name: []const u8) CallFrame {
        return .{
            .function_name = function_name,
            .positional_params = [_]?[]const u8{null} ** 64,
            .positional_params_count = 0,
            .local_vars = std.StringHashMap([]const u8).init(allocator),
            .return_requested = false,
            .return_code = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CallFrame) void {
        // Free positional parameters
        for (self.positional_params) |param_opt| {
            if (param_opt) |param| {
                self.allocator.free(param);
            }
        }

        // Free local variables
        var iter = self.local_vars.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.local_vars.deinit();
    }
};

/// Function manager - handles function storage and execution
pub const FunctionManager = struct {
    allocator: std.mem.Allocator,
    functions: std.StringHashMap(Function),
    call_stack: [64]CallFrame, // Max 64 nested calls
    call_stack_depth: usize,

    pub fn init(allocator: std.mem.Allocator) FunctionManager {
        return .{
            .allocator = allocator,
            .functions = std.StringHashMap(Function).init(allocator),
            .call_stack = undefined,
            .call_stack_depth = 0,
        };
    }

    pub fn deinit(self: *FunctionManager) void {
        // Free all functions
        var iter = self.functions.iterator();
        while (iter.next()) |entry| {
            var func = entry.value_ptr;
            func.deinit();
        }
        self.functions.deinit();

        // Clean up any remaining call frames
        var i: usize = 0;
        while (i < self.call_stack_depth) : (i += 1) {
            self.call_stack[i].deinit();
        }
    }

    /// Define a new function
    pub fn defineFunction(self: *FunctionManager, name: []const u8, body: [][]const u8, is_exported: bool) !void {
        // Check if function already exists
        if (self.functions.get(name)) |existing| {
            // Remove old function
            var func = existing;
            func.deinit();
            _ = self.functions.remove(name);
        }

        // Create new function
        const func = Function{
            .name = try self.allocator.dupe(u8, name),
            .body = try self.copyBody(body),
            .is_exported = is_exported,
            .allocator = self.allocator,
        };

        // Store function
        const key = try self.allocator.dupe(u8, name);
        try self.functions.put(key, func);
    }

    /// Get a function by name
    pub fn getFunction(self: *FunctionManager, name: []const u8) ?*Function {
        return self.functions.getPtr(name);
    }

    /// Check if a function exists
    pub fn hasFunction(self: *FunctionManager, name: []const u8) bool {
        return self.functions.contains(name);
    }

    /// Remove a function
    pub fn removeFunction(self: *FunctionManager, name: []const u8) void {
        if (self.functions.fetchRemove(name)) |entry| {
            var func = entry.value;
            func.deinit();
            self.allocator.free(entry.key);
        }
    }

    /// Push a new call frame onto the stack
    pub fn pushFrame(self: *FunctionManager, function_name: []const u8, args: []const []const u8) !void {
        if (self.call_stack_depth >= self.call_stack.len) {
            return error.CallStackOverflow;
        }

        var frame = CallFrame.init(self.allocator, function_name);

        // Set positional parameters
        var i: usize = 0;
        while (i < args.len and i < frame.positional_params.len) : (i += 1) {
            frame.positional_params[i] = try self.allocator.dupe(u8, args[i]);
            frame.positional_params_count = i + 1;
        }

        self.call_stack[self.call_stack_depth] = frame;
        self.call_stack_depth += 1;
    }

    /// Pop the current call frame
    pub fn popFrame(self: *FunctionManager) void {
        if (self.call_stack_depth == 0) return;

        self.call_stack_depth -= 1;
        self.call_stack[self.call_stack_depth].deinit();
    }

    /// Get the current call frame
    pub fn currentFrame(self: *FunctionManager) ?*CallFrame {
        if (self.call_stack_depth == 0) return null;
        return &self.call_stack[self.call_stack_depth - 1];
    }

    /// Execute a function
    pub fn executeFunction(self: *FunctionManager, shell: *Shell, name: []const u8, args: []const []const u8) error{FunctionNotFound,CallStackOverflow,OutOfMemory}!i32 {
        const func = self.getFunction(name) orelse return error.FunctionNotFound;

        // Push call frame
        try self.pushFrame(name, args);
        defer self.popFrame();

        var exit_code: i32 = 0;

        // Execute function body with control flow support
        var line_num: usize = 0;
        var cf_parser = ControlFlowParser.init(self.allocator);
        var cf_executor = ControlFlowExecutor.init(shell);

        while (line_num < func.body.len) {
            const line = func.body[line_num];
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

            if (trimmed.len == 0 or trimmed[0] == '#') {
                line_num += 1;
                continue;
            }

            // Check for control flow constructs
            // One-liner detection: if the line contains both opener and closer
            // (e.g., "for...done" or "if...fi"), treat as one-liner via executeCommand
            const is_oneliner = (std.mem.startsWith(u8, trimmed, "for ") and
                (containsWord(trimmed, "done") or containsWord(trimmed, "fi"))) or
                (std.mem.startsWith(u8, trimmed, "while ") and containsWord(trimmed, "done")) or
                (std.mem.startsWith(u8, trimmed, "until ") and containsWord(trimmed, "done")) or
                (std.mem.startsWith(u8, trimmed, "if ") and containsWord(trimmed, "fi")) or
                (std.mem.startsWith(u8, trimmed, "case ") and containsWord(trimmed, "esac"));

            if (!is_oneliner) {
                if (std.mem.startsWith(u8, trimmed, "if ") or std.mem.eql(u8, trimmed, "if")) {
                    if (cf_parser.parseIf(func.body, line_num)) |result| {
                        var stmt = result.stmt;
                        exit_code = cf_executor.executeIf(&stmt) catch 1;
                        line_num = result.end + 1;

                        if (self.currentFrame()) |frame| {
                            if (frame.return_requested) {
                                return frame.return_code;
                            }
                        }
                        continue;
                    } else |_| {}
                } else if (std.mem.startsWith(u8, trimmed, "while ") or std.mem.eql(u8, trimmed, "while")) {
                    if (cf_parser.parseWhile(func.body, line_num, false)) |result| {
                        var loop = result.loop;
                        exit_code = cf_executor.executeWhile(&loop) catch 1;
                        line_num = result.end + 1;

                        if (self.currentFrame()) |frame| {
                            if (frame.return_requested) {
                                return frame.return_code;
                            }
                        }
                        continue;
                    } else |_| {}
                } else if (std.mem.startsWith(u8, trimmed, "until ") or std.mem.eql(u8, trimmed, "until")) {
                    if (cf_parser.parseWhile(func.body, line_num, true)) |result| {
                        var loop = result.loop;
                        exit_code = cf_executor.executeWhile(&loop) catch 1;
                        line_num = result.end + 1;

                        if (self.currentFrame()) |frame| {
                            if (frame.return_requested) {
                                return frame.return_code;
                            }
                        }
                        continue;
                    } else |_| {}
                } else if (std.mem.startsWith(u8, trimmed, "for ") or std.mem.eql(u8, trimmed, "for")) {
                    if (cf_parser.parseFor(func.body, line_num)) |result| {
                        var loop = result.loop;
                        exit_code = cf_executor.executeFor(&loop) catch 1;
                        line_num = result.end + 1;

                        if (self.currentFrame()) |frame| {
                            if (frame.return_requested) {
                                return frame.return_code;
                            }
                        }
                        continue;
                    } else |_| {}
                } else if (std.mem.startsWith(u8, trimmed, "case ")) {
                    if (cf_parser.parseCase(func.body, line_num)) |result| {
                        var stmt = result.stmt;
                        exit_code = cf_executor.executeCase(&stmt) catch 1;
                        line_num = result.end + 1;

                        if (self.currentFrame()) |frame| {
                            if (frame.return_requested) {
                                return frame.return_code;
                            }
                        }
                        continue;
                    } else |_| {}
                }
            }

            // Execute as regular command
            shell.executeCommand(trimmed) catch {};
            exit_code = shell.last_exit_code;
            line_num += 1;

            // Check for return
            if (self.currentFrame()) |frame| {
                if (frame.return_requested) {
                    return frame.return_code;
                }
            }

            // Check errexit
            if (shell.option_errexit and exit_code != 0) {
                return exit_code;
            }
        }

        return exit_code;
    }

    /// Set a local variable in the current function
    pub fn setLocal(self: *FunctionManager, name: []const u8, value: []const u8) !void {
        const frame = self.currentFrame() orelse return error.NotInFunction;

        // Remove old value if exists
        if (frame.local_vars.get(name)) |old_value| {
            self.allocator.free(old_value);
        }

        const key = try self.allocator.dupe(u8, name);
        const val = try self.allocator.dupe(u8, value);
        try frame.local_vars.put(key, val);
    }

    /// Get a local variable from the current function
    pub fn getLocal(self: *FunctionManager, name: []const u8) ?[]const u8 {
        const frame = self.currentFrame() orelse return null;
        return frame.local_vars.get(name);
    }

    /// Get a positional parameter from the current function
    pub fn getPositionalParam(self: *FunctionManager, index: usize) ?[]const u8 {
        const frame = self.currentFrame() orelse return null;
        if (index >= frame.positional_params_count) return null;
        return frame.positional_params[index];
    }

    /// Request a return from the current function
    pub fn requestReturn(self: *FunctionManager, code: i32) !void {
        const frame = self.currentFrame() orelse return error.NotInFunction;
        frame.return_requested = true;
        frame.return_code = code;
    }

    /// Helper: Copy function body
    fn copyBody(self: *FunctionManager, body: [][]const u8) ![][]const u8 {
        const new_body = try self.allocator.alloc([]const u8, body.len);
        for (body, 0..) |line, i| {
            new_body[i] = try self.allocator.dupe(u8, line);
        }
        return new_body;
    }

    /// List all functions
    pub fn listFunctions(self: *FunctionManager) ![][]const u8 {
        var names_buffer: [256][]const u8 = undefined;
        var count: usize = 0;

        var iter = self.functions.iterator();
        while (iter.next()) |entry| {
            if (count >= names_buffer.len) break;
            names_buffer[count] = entry.key_ptr.*;
            count += 1;
        }

        const names = try self.allocator.alloc([]const u8, count);
        @memcpy(names, names_buffer[0..count]);
        return names;
    }
};

/// Function parser - parses function definitions from script lines
pub const FunctionParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FunctionParser {
        return .{ .allocator = allocator };
    }

    /// Parse function definition: function name { ... } or name() { ... }
    pub fn parseFunction(self: *FunctionParser, lines: [][]const u8, start: usize) !struct { name: []const u8, body: [][]const u8, end: usize } {
        const first_line = std.mem.trim(u8, lines[start], &std.ascii.whitespace);

        var name: []const u8 = undefined;
        var start_line = start;

        // Check for "function name {" syntax
        if (std.mem.startsWith(u8, first_line, "function ")) {
            const after_keyword = std.mem.trim(u8, first_line[9..], &std.ascii.whitespace);

            // Extract function name (everything before { or whitespace)
            const name_end = std.mem.indexOfAny(u8, after_keyword, " \t{") orelse after_keyword.len;
            name = try self.allocator.dupe(u8, after_keyword[0..name_end]);

            // Check if { is on the same line
            if (std.mem.indexOf(u8, first_line, "{")) |_| {
                start_line = start;
            } else {
                start_line = start + 1;
            }
        }
        // Check for "name() {" syntax
        else if (std.mem.indexOf(u8, first_line, "()")) |paren_pos| {
            const name_part = std.mem.trim(u8, first_line[0..paren_pos], &std.ascii.whitespace);
            name = try self.allocator.dupe(u8, name_part);

            // Check if { is on the same line
            if (std.mem.indexOf(u8, first_line, "{")) |_| {
                start_line = start;
            } else {
                start_line = start + 1;
            }
        } else {
            return error.InvalidFunctionSyntax;
        }

        // Find matching closing brace
        var body_buffer: [1000][]const u8 = undefined;
        var body_count: usize = 0;
        var brace_count: i32 = 0;
        var found_opening = false;
        var i = start_line;

        while (i < lines.len) : (i += 1) {
            const line = lines[i];

            // Count braces
            for (line) |c| {
                if (c == '{') {
                    brace_count += 1;
                    found_opening = true;
                } else if (c == '}') {
                    brace_count -= 1;
                }
            }

            // Don't include the opening { line or closing } line in body
            if (i > start_line or (i == start_line and std.mem.indexOf(u8, line, "{") == null)) {
                if (brace_count > 0) {
                    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
                    if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "{")) {
                        if (body_count >= body_buffer.len) return error.FunctionTooLarge;
                        body_buffer[body_count] = try self.allocator.dupe(u8, trimmed);
                        body_count += 1;
                    }
                }
            }

            // Check if we've found the closing brace
            if (found_opening and brace_count == 0) {
                const body = try self.allocator.alloc([]const u8, body_count);
                @memcpy(body, body_buffer[0..body_count]);

                return .{
                    .name = name,
                    .body = body,
                    .end = i,
                };
            }
        }

        return error.UnmatchedBraces;
    }
};
