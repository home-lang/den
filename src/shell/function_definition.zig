//! Function Definition Module
//! Handles multiline function definition parsing and registration

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const Shell = @import("../shell.zig").Shell;
const FunctionParser = @import("../scripting/functions.zig").FunctionParser;

/// Check if input starts a function definition
pub fn checkFunctionDefinitionStart(self: *Shell, trimmed: []const u8) !bool {
    // Check for "function name" or "name()" syntax
    const is_function_keyword = std.mem.startsWith(u8, trimmed, "function ");

    // For name() syntax, check if line contains ()
    var is_paren_syntax = false;
    if (std.mem.indexOf(u8, trimmed, "()")) |_| {
        // Make sure it's not just () by itself and there's a name before
        const paren_pos = std.mem.indexOf(u8, trimmed, "()") orelse 0;
        if (paren_pos > 0) {
            is_paren_syntax = true;
        }
    }

    if (!is_function_keyword and !is_paren_syntax) {
        return false;
    }

    // This is a function definition - start collecting
    // Count braces in this line
    var brace_count: i32 = 0;
    for (trimmed) |c| {
        if (c == '{') brace_count += 1;
        if (c == '}') brace_count -= 1;
    }

    // Store the first line
    if (self.multiline_count >= self.multiline_buffer.len) {
        try IO.eprint("Function definition too long\n", .{});
        return true;
    }
    self.multiline_buffer[self.multiline_count] = try self.allocator.dupe(u8, trimmed);
    self.multiline_count += 1;
    self.multiline_brace_count = brace_count;

    if (brace_count > 0) {
        // Incomplete - need more lines
        self.multiline_mode = .function_def;
        return true;
    } else if (brace_count == 0) {
        // Check if we have an opening brace at all
        if (std.mem.indexOf(u8, trimmed, "{")) |open_brace| {
            // Complete single-line function like: function foo { echo hi; }
            // Handle single-line function directly without parser
            const close_brace = std.mem.lastIndexOf(u8, trimmed, "}") orelse {
                try IO.eprint("Syntax error: missing closing brace\n", .{});
                resetMultilineState(self);
                return true;
            };

            // Extract function name
            var func_name: []const u8 = undefined;
            if (is_function_keyword) {
                const after_keyword = std.mem.trim(u8, trimmed[9..], &std.ascii.whitespace);
                const name_end = std.mem.indexOfAny(u8, after_keyword, " \t{") orelse after_keyword.len;
                func_name = after_keyword[0..name_end];
            } else {
                // name() syntax
                const paren_pos = std.mem.indexOf(u8, trimmed, "()") orelse 0;
                func_name = std.mem.trim(u8, trimmed[0..paren_pos], &std.ascii.whitespace);
            }

            // Extract body (content between { and })
            const body_content = std.mem.trim(u8, trimmed[open_brace + 1 .. close_brace], &std.ascii.whitespace);

            // Create body as array of lines (split by semicolons for single-line)
            var body_lines: [32][]const u8 = undefined;
            var body_count: usize = 0;
            var line_iter = std.mem.splitScalar(u8, body_content, ';');
            while (line_iter.next()) |part| {
                const part_trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
                if (part_trimmed.len > 0) {
                    if (body_count >= body_lines.len) break;
                    body_lines[body_count] = try self.allocator.dupe(u8, part_trimmed);
                    body_count += 1;
                }
            }

            // Define the function
            self.function_manager.defineFunction(func_name, body_lines[0..body_count], false) catch |err| {
                try IO.eprint("Function definition error: {}\n", .{err});
                // Free the body lines we allocated
                for (body_lines[0..body_count]) |line_content| {
                    self.allocator.free(line_content);
                }
                resetMultilineState(self);
                return true;
            };

            // Free the body lines (function_manager made its own copy)
            for (body_lines[0..body_count]) |line_content| {
                self.allocator.free(line_content);
            }

            resetMultilineState(self);
            return true;
        } else {
            // No brace yet - might be "function foo" and { on next line
            self.multiline_mode = .function_def;
            return true;
        }
    }

    return true;
}

/// Handle continuation of multiline input
pub fn handleMultilineContinuation(self: *Shell, trimmed: []const u8) !void {
    // Store the line
    if (self.multiline_count >= self.multiline_buffer.len) {
        try IO.eprint("Function definition too long\n", .{});
        resetMultilineState(self);
        return;
    }
    self.multiline_buffer[self.multiline_count] = try self.allocator.dupe(u8, trimmed);
    self.multiline_count += 1;

    // Update brace count
    for (trimmed) |c| {
        if (c == '{') self.multiline_brace_count += 1;
        if (c == '}') self.multiline_brace_count -= 1;
    }

    // Check if function is complete
    if (self.multiline_brace_count == 0 and self.multiline_count > 0) {
        // Check if we ever had an opening brace
        var had_opening_brace = false;
        for (self.multiline_buffer[0..self.multiline_count]) |maybe_line| {
            if (maybe_line) |line_content| {
                if (std.mem.indexOf(u8, line_content, "{") != null) {
                    had_opening_brace = true;
                    break;
                }
            }
        }

        if (had_opening_brace) {
            try finishFunctionDefinition(self);
        }
    }
}

/// Complete function definition parsing and register the function
pub fn finishFunctionDefinition(self: *Shell) !void {
    // Collect lines into array for parser
    var lines: [100][]const u8 = undefined;
    var line_count: usize = 0;
    for (self.multiline_buffer[0..self.multiline_count]) |maybe_line| {
        if (maybe_line) |line_content| {
            lines[line_count] = line_content;
            line_count += 1;
        }
    }

    // Parse the function definition
    var parser = FunctionParser.init(self.allocator);

    const result = parser.parseFunction(lines[0..line_count], 0) catch |err| {
        try IO.eprint("Function parse error: {}\n", .{err});
        resetMultilineState(self);
        return;
    };

    // Define the function
    self.function_manager.defineFunction(result.name, result.body, false) catch |err| {
        try IO.eprint("Function definition error: {}\n", .{err});
        resetMultilineState(self);
        return;
    };

    // Free the name that was duped by parser (function_manager made its own copy)
    self.allocator.free(result.name);
    for (result.body) |body_line| {
        self.allocator.free(body_line);
    }
    self.allocator.free(result.body);

    resetMultilineState(self);
}

/// Reset multiline state and free buffered lines
pub fn resetMultilineState(self: *Shell) void {
    for (self.multiline_buffer[0..self.multiline_count]) |maybe_line| {
        if (maybe_line) |line_content| {
            self.allocator.free(line_content);
        }
    }
    self.multiline_buffer = [_]?[]const u8{null} ** 100;
    self.multiline_count = 0;
    self.multiline_brace_count = 0;
    self.multiline_mode = .none;
}
