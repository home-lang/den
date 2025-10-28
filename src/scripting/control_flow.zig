const std = @import("std");
const Shell = @import("../shell.zig").Shell;

/// Control flow statement type
pub const ControlFlowType = enum {
    if_statement,
    while_loop,
    for_loop,
    case_statement,
    until_loop,
    select_menu,
    c_style_for_loop,
};

/// If statement structure
pub const IfStatement = struct {
    condition: []const u8,
    then_body: [][]const u8,
    elif_clauses: []ElifClause,
    else_body: ?[][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *IfStatement) void {
        self.allocator.free(self.condition);
        for (self.then_body) |line| {
            self.allocator.free(line);
        }
        self.allocator.free(self.then_body);

        for (self.elif_clauses) |*clause| {
            self.allocator.free(clause.condition);
            for (clause.body) |line| {
                self.allocator.free(line);
            }
            self.allocator.free(clause.body);
        }
        self.allocator.free(self.elif_clauses);

        if (self.else_body) |body| {
            for (body) |line| {
                self.allocator.free(line);
            }
            self.allocator.free(body);
        }
    }
};

pub const ElifClause = struct {
    condition: []const u8,
    body: [][]const u8,
};

/// While/Until loop structure
pub const WhileLoop = struct {
    condition: []const u8,
    body: [][]const u8,
    is_until: bool, // true for until, false for while
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WhileLoop) void {
        self.allocator.free(self.condition);
        for (self.body) |line| {
            self.allocator.free(line);
        }
        self.allocator.free(self.body);
    }
};

/// For loop structure (traditional: for var in items)
pub const ForLoop = struct {
    variable: []const u8,
    items: [][]const u8,
    body: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ForLoop) void {
        self.allocator.free(self.variable);
        for (self.items) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(self.items);
        for (self.body) |line| {
            self.allocator.free(line);
        }
        self.allocator.free(self.body);
    }
};

/// C-style for loop structure (for (init; condition; update))
pub const CStyleForLoop = struct {
    init: ?[]const u8, // Initial statement (e.g., i=0)
    condition: ?[]const u8, // Condition to check (e.g., i<10)
    update: ?[]const u8, // Update statement (e.g., i++)
    body: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CStyleForLoop) void {
        if (self.init) |init| {
            self.allocator.free(init);
        }
        if (self.condition) |condition| {
            self.allocator.free(condition);
        }
        if (self.update) |update| {
            self.allocator.free(update);
        }
        for (self.body) |line| {
            self.allocator.free(line);
        }
        self.allocator.free(self.body);
    }
};

/// Select menu structure for interactive selection
pub const SelectMenu = struct {
    variable: []const u8, // Variable to store selected item
    items: [][]const u8, // Menu items
    body: [][]const u8, // Body to execute for each selection
    prompt: []const u8, // PS3 prompt (default: "#? ")
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SelectMenu) void {
        self.allocator.free(self.variable);
        for (self.items) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(self.items);
        for (self.body) |line| {
            self.allocator.free(line);
        }
        self.allocator.free(self.body);
        self.allocator.free(self.prompt);
    }
};

/// Case statement structure
pub const CaseStatement = struct {
    value: []const u8,
    cases: []CaseClause,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CaseStatement) void {
        self.allocator.free(self.value);
        for (self.cases) |*case_clause| {
            for (case_clause.patterns) |pattern| {
                self.allocator.free(pattern);
            }
            self.allocator.free(case_clause.patterns);
            for (case_clause.body) |line| {
                self.allocator.free(line);
            }
            self.allocator.free(case_clause.body);
        }
        self.allocator.free(self.cases);
    }
};

pub const CaseClause = struct {
    patterns: [][]const u8,
    body: [][]const u8,
};

/// Control flow executor
pub const ControlFlowExecutor = struct {
    shell: *Shell,
    allocator: std.mem.Allocator,
    break_requested: bool,
    continue_requested: bool,

    pub fn init(shell: *Shell) ControlFlowExecutor {
        return .{
            .shell = shell,
            .allocator = shell.allocator,
            .break_requested = false,
            .continue_requested = false,
        };
    }

    /// Execute if statement
    pub fn executeIf(self: *ControlFlowExecutor, stmt: *IfStatement) !i32 {
        // Evaluate main condition
        const condition_result = self.evaluateCondition(stmt.condition);

        if (condition_result) {
            // Execute then body
            return self.executeBody(stmt.then_body);
        }

        // Check elif clauses
        for (stmt.elif_clauses) |elif| {
            const elif_result = self.evaluateCondition(elif.condition);
            if (elif_result) {
                return self.executeBody(elif.body);
            }
        }

        // Execute else body if present
        if (stmt.else_body) |else_body| {
            return self.executeBody(else_body);
        }

        return 0;
    }

    /// Execute while loop
    pub fn executeWhile(self: *ControlFlowExecutor, loop: *WhileLoop) !i32 {
        var last_exit: i32 = 0;

        while (true) {
            const condition_result = self.evaluateCondition(loop.condition);

            // For while: continue if true, for until: continue if false
            const should_continue = if (loop.is_until) !condition_result else condition_result;

            if (!should_continue) break;

            last_exit = self.executeBody(loop.body);

            // Check for break
            if (self.break_requested) {
                self.break_requested = false;
                break;
            }

            // Reset continue flag
            if (self.continue_requested) {
                self.continue_requested = false;
                continue;
            }

            // Check errexit
            if (self.shell.option_errexit and last_exit != 0) {
                break;
            }
        }

        return last_exit;
    }

    /// Execute for loop
    pub fn executeFor(self: *ControlFlowExecutor, loop: *ForLoop) !i32 {
        var last_exit: i32 = 0;

        for (loop.items) |item| {
            // Set loop variable
            const value = try self.allocator.dupe(u8, item);

            // Get or put entry to avoid memory leak
            const gop = try self.shell.environment.getOrPut(loop.variable);
            if (gop.found_existing) {
                // Free old value and update
                self.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = value;
            } else {
                // New key - duplicate it
                const key = try self.allocator.dupe(u8, loop.variable);
                gop.key_ptr.* = key;
                gop.value_ptr.* = value;
            }

            last_exit = self.executeBody(loop.body);

            // Check for break
            if (self.break_requested) {
                self.break_requested = false;
                break;
            }

            // Reset continue flag
            if (self.continue_requested) {
                self.continue_requested = false;
                continue;
            }

            // Check errexit
            if (self.shell.option_errexit and last_exit != 0) {
                break;
            }
        }

        return last_exit;
    }

    /// Execute C-style for loop: for ((init; condition; update))
    pub fn executeCStyleFor(self: *ControlFlowExecutor, loop: *CStyleForLoop) !i32 {
        var last_exit: i32 = 0;

        // Execute initialization (if present)
        if (loop.init) |init_stmt| {
            _ = try self.executeStatement(init_stmt);
        }

        // Loop while condition is true
        while (true) {
            // Check condition (if present, default to true if omitted)
            if (loop.condition) |condition| {
                const condition_result = try self.evaluateArithmeticCondition(condition);
                if (!condition_result) break;
            }

            // Execute body
            last_exit = self.executeBody(loop.body);

            // Check for break
            if (self.break_requested) {
                self.break_requested = false;
                break;
            }

            // Execute update (before checking continue, to match C semantics)
            if (loop.update) |update| {
                _ = try self.executeStatement(update);
            }

            // Reset continue flag (after update)
            if (self.continue_requested) {
                self.continue_requested = false;
                continue;
            }

            // Check errexit
            if (self.shell.option_errexit and last_exit != 0) {
                break;
            }
        }

        return last_exit;
    }

    /// Execute select menu for interactive selection
    pub fn executeSelect(self: *ControlFlowExecutor, menu: *SelectMenu) !i32 {
        var last_exit: i32 = 0;
        const stdin = std.io.getStdIn();
        const stdout = std.io.getStdOut();
        var buf_reader = std.io.bufferedReader(stdin.reader());
        var reader = buf_reader.reader();

        // Display menu items once
        try stdout.writeAll("\n");
        for (menu.items, 1..) |item, idx| {
            try stdout.writer().print("{d}) {s}\n", .{ idx, item });
        }

        // Loop until break
        while (true) {
            // Display prompt
            try stdout.writeAll(menu.prompt);
            try stdout.writer().context.sync(); // Flush output

            // Read user input
            var input_buf: [1024]u8 = undefined;
            const input_line = (try reader.readUntilDelimiterOrEof(&input_buf, '\n')) orelse {
                // EOF reached, exit the select
                break;
            };

            const trimmed = std.mem.trim(u8, input_line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;

            // Parse selection number
            const selection = std.fmt.parseInt(usize, trimmed, 10) catch {
                // Invalid number, ask again
                try stdout.writeAll("Invalid selection\n");
                continue;
            };

            if (selection == 0 or selection > menu.items.len) {
                try stdout.writeAll("Invalid selection\n");
                continue;
            }

            // Set the variable to the selected item
            const selected_item = menu.items[selection - 1];
            const value = try self.allocator.dupe(u8, selected_item);

            const gop = try self.shell.environment.getOrPut(menu.variable);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = value;
            } else {
                const key = try self.allocator.dupe(u8, menu.variable);
                gop.key_ptr.* = key;
                gop.value_ptr.* = value;
            }

            // Also set REPLY variable with the selection number
            const reply_value = try std.fmt.allocPrint(self.allocator, "{d}", .{selection});
            const reply_gop = try self.shell.environment.getOrPut("REPLY");
            if (reply_gop.found_existing) {
                self.allocator.free(reply_gop.value_ptr.*);
                reply_gop.value_ptr.* = reply_value;
            } else {
                const reply_key = try self.allocator.dupe(u8, "REPLY");
                reply_gop.key_ptr.* = reply_key;
                reply_gop.value_ptr.* = reply_value;
            }

            // Execute body
            last_exit = self.executeBody(menu.body);

            // Check for break
            if (self.break_requested) {
                self.break_requested = false;
                break;
            }

            // Reset continue flag
            if (self.continue_requested) {
                self.continue_requested = false;
                continue;
            }

            // Check errexit
            if (self.shell.option_errexit and last_exit != 0) {
                break;
            }
        }

        return last_exit;
    }

    /// Execute case statement
    pub fn executeCase(self: *ControlFlowExecutor, stmt: *CaseStatement) !i32 {
        // Expand the value first
        const expanded_value = try self.expandValue(stmt.value);
        defer self.allocator.free(expanded_value);

        for (stmt.cases) |case_clause| {
            for (case_clause.patterns) |pattern| {
                if (try self.matchPattern(expanded_value, pattern)) {
                    return self.executeBody(case_clause.body);
                }
            }
        }

        return 0;
    }

    /// Evaluate a condition (runs command and checks exit code)
    fn evaluateCondition(self: *ControlFlowExecutor, condition: []const u8) bool {
        // Execute condition command
        self.shell.executeCommand(condition) catch {
            return false;
        };

        // Condition is true if exit code is 0
        return self.shell.last_exit_code == 0;
    }

    /// Execute a body of commands
    fn executeBody(self: *ControlFlowExecutor, body: [][]const u8) i32 {
        var last_exit: i32 = 0;

        for (body) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Check for break
            if (std.mem.eql(u8, trimmed, "break")) {
                self.break_requested = true;
                return 0;
            }

            // Check for continue
            if (std.mem.eql(u8, trimmed, "continue")) {
                self.continue_requested = true;
                return 0;
            }

            // Execute command
            self.shell.executeCommand(trimmed) catch {
                last_exit = 1;
            };

            last_exit = self.shell.last_exit_code;

            // Check for break/continue request
            if (self.break_requested or self.continue_requested) {
                return last_exit;
            }

            // Check errexit
            if (self.shell.option_errexit and last_exit != 0) {
                return last_exit;
            }
        }

        return last_exit;
    }

    /// Expand a value (variables, command substitution, etc.)
    fn expandValue(self: *ControlFlowExecutor, value: []const u8) ![]const u8 {
        // Simple implementation - just dupe for now
        // In full implementation, this would use the expansion engine
        return try self.allocator.dupe(u8, value);
    }

    /// Match a pattern (supports literals and simple globs)
    fn matchPattern(self: *ControlFlowExecutor, value: []const u8, pattern: []const u8) !bool {
        _ = self;

        // Exact match
        if (std.mem.eql(u8, value, pattern)) return true;

        // Simple wildcard support: * matches anything
        if (std.mem.eql(u8, pattern, "*")) return true;

        // Pattern with * at end: prefix match
        if (pattern.len > 0 and pattern[pattern.len - 1] == '*') {
            const prefix = pattern[0 .. pattern.len - 1];
            if (std.mem.startsWith(u8, value, prefix)) return true;
        }

        // Pattern with * at start: suffix match
        if (pattern.len > 0 and pattern[0] == '*') {
            const suffix = pattern[1..];
            if (std.mem.endsWith(u8, value, suffix)) return true;
        }

        return false;
    }

    /// Execute a statement (for init/update in C-style for loops)
    fn executeStatement(self: *ControlFlowExecutor, statement: []const u8) !i32 {
        const trimmed = std.mem.trim(u8, statement, &std.ascii.whitespace);
        if (trimmed.len == 0) return 0;

        // Execute as a command
        self.shell.executeCommand(trimmed) catch |err| {
            std.debug.print("Error executing statement: {}\n", .{err});
            return 1;
        };

        return self.shell.last_exit_code;
    }

    /// Evaluate arithmetic condition for C-style for loops
    fn evaluateArithmeticCondition(self: *ControlFlowExecutor, condition: []const u8) !bool {
        const trimmed = std.mem.trim(u8, condition, &std.ascii.whitespace);
        if (trimmed.len == 0) return true; // Empty condition is true

        // Build a test command: test condition
        const test_cmd = try std.fmt.allocPrint(self.allocator, "test {s}", .{trimmed});
        defer self.allocator.free(test_cmd);

        // Execute and check result
        self.shell.executeCommand(test_cmd) catch {
            return false;
        };

        return self.shell.last_exit_code == 0;
    }
};

/// Parse control flow statements from script lines
pub const ControlFlowParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ControlFlowParser {
        return .{ .allocator = allocator };
    }

    /// Parse if statement from lines starting at index
    pub fn parseIf(self: *ControlFlowParser, lines: [][]const u8, start: usize) !struct { stmt: IfStatement, end: usize } {
        var then_body_buffer: [1000][]const u8 = undefined;
        var then_body_count: usize = 0;
        var elif_buffer: [10]ElifClause = undefined;
        var elif_count: usize = 0;
        var else_body_buffer: [1000][]const u8 = undefined;
        var else_body_count: usize = 0;
        var has_else = false;

        // Extract condition from "if <condition>; then" or "if <condition>"
        const first_line = std.mem.trim(u8, lines[start], &std.ascii.whitespace);
        const condition_start = if (std.mem.startsWith(u8, first_line, "if ")) 3 else return error.InvalidIf;
        const condition_end = std.mem.indexOf(u8, first_line[condition_start..], ";") orelse
                             std.mem.indexOf(u8, first_line[condition_start..], "\n") orelse
                             first_line[condition_start..].len;
        const condition = try self.allocator.dupe(u8, std.mem.trim(u8, first_line[condition_start..][0..condition_end], &std.ascii.whitespace));

        var i = start + 1;
        var current_section: enum { then, elif, @"else" } = .then;

        while (i < lines.len) : (i += 1) {
            const line = std.mem.trim(u8, lines[i], &std.ascii.whitespace);

            if (std.mem.eql(u8, line, "then")) {
                current_section = .then;
                continue;
            }

            if (std.mem.startsWith(u8, line, "elif ")) {
                current_section = .elif;
                // Parse elif condition
                const elif_cond_start = 5;
                const elif_cond_end = std.mem.indexOf(u8, line[elif_cond_start..], ";") orelse line[elif_cond_start..].len;
                const elif_condition = try self.allocator.dupe(u8, std.mem.trim(u8, line[elif_cond_start..][0..elif_cond_end], &std.ascii.whitespace));

                if (elif_count >= elif_buffer.len) return error.TooManyElifClauses;
                elif_buffer[elif_count] = ElifClause{
                    .condition = elif_condition,
                    .body = &[_][]const u8{}, // Empty placeholder, will be filled later
                };
                elif_count += 1;
                continue;
            }

            if (std.mem.eql(u8, line, "else")) {
                current_section = .@"else";
                has_else = true;
                continue;
            }

            if (std.mem.eql(u8, line, "fi")) {
                // End of if statement
                break;
            }

            // Add line to appropriate body
            if (line.len > 0 and line[0] != '#') {
                const line_copy = try self.allocator.dupe(u8, line);
                switch (current_section) {
                    .then => {
                        if (then_body_count >= then_body_buffer.len) return error.TooManyLines;
                        then_body_buffer[then_body_count] = line_copy;
                        then_body_count += 1;
                    },
                    .elif => {
                        // We'll need to track elif bodies separately - for now, skip
                        // This is a simplified implementation
                    },
                    .@"else" => {
                        if (else_body_count >= else_body_buffer.len) return error.TooManyLines;
                        else_body_buffer[else_body_count] = line_copy;
                        else_body_count += 1;
                    },
                }
            }
        }

        // Create slices and copy data
        const then_body = try self.allocator.alloc([]const u8, then_body_count);
        @memcpy(then_body, then_body_buffer[0..then_body_count]);

        const elif_clauses = try self.allocator.alloc(ElifClause, elif_count);
        @memcpy(elif_clauses, elif_buffer[0..elif_count]);

        const else_body: ?[][]const u8 = if (has_else) blk: {
            const body = try self.allocator.alloc([]const u8, else_body_count);
            @memcpy(body, else_body_buffer[0..else_body_count]);
            break :blk body;
        } else null;

        return .{
            .stmt = IfStatement{
                .condition = condition,
                .then_body = then_body,
                .elif_clauses = elif_clauses,
                .else_body = else_body,
                .allocator = self.allocator,
            },
            .end = i,
        };
    }

    /// Parse while loop
    pub fn parseWhile(self: *ControlFlowParser, lines: [][]const u8, start: usize, is_until: bool) !struct { loop: WhileLoop, end: usize } {
        const first_line = std.mem.trim(u8, lines[start], &std.ascii.whitespace);
        const keyword = if (is_until) "until " else "while ";
        const keyword_len = keyword.len;

        if (!std.mem.startsWith(u8, first_line, keyword)) return error.InvalidLoop;

        const condition_end = std.mem.indexOf(u8, first_line[keyword_len..], ";") orelse
                             std.mem.indexOf(u8, first_line[keyword_len..], "\n") orelse
                             first_line[keyword_len..].len;
        const condition = try self.allocator.dupe(u8, std.mem.trim(u8, first_line[keyword_len..][0..condition_end], &std.ascii.whitespace));

        var body_buffer: [1000][]const u8 = undefined;
        var body_count: usize = 0;
        var i = start + 1;

        while (i < lines.len) : (i += 1) {
            const line = std.mem.trim(u8, lines[i], &std.ascii.whitespace);

            if (std.mem.eql(u8, line, "do")) continue;
            if (std.mem.eql(u8, line, "done")) break;

            if (line.len > 0 and line[0] != '#') {
                if (body_count >= body_buffer.len) return error.TooManyLines;
                body_buffer[body_count] = try self.allocator.dupe(u8, line);
                body_count += 1;
            }
        }

        const body = try self.allocator.alloc([]const u8, body_count);
        @memcpy(body, body_buffer[0..body_count]);

        return .{
            .loop = WhileLoop{
                .condition = condition,
                .body = body,
                .is_until = is_until,
                .allocator = self.allocator,
            },
            .end = i,
        };
    }

    /// Parse for loop
    pub fn parseFor(self: *ControlFlowParser, lines: [][]const u8, start: usize) !struct { loop: ForLoop, end: usize } {
        const first_line = std.mem.trim(u8, lines[start], &std.ascii.whitespace);

        if (!std.mem.startsWith(u8, first_line, "for ")) return error.InvalidFor;

        // Parse: for VAR in ITEM1 ITEM2 ITEM3
        const parts_start = 4; // After "for "
        const in_pos = std.mem.indexOf(u8, first_line[parts_start..], " in ") orelse return error.InvalidFor;

        const variable = try self.allocator.dupe(u8, std.mem.trim(u8, first_line[parts_start..][0..in_pos], &std.ascii.whitespace));

        const items_start = parts_start + in_pos + 4; // After " in "
        const items_end = std.mem.indexOf(u8, first_line[items_start..], ";") orelse first_line[items_start..].len;
        const items_str = std.mem.trim(u8, first_line[items_start..][0..items_end], &std.ascii.whitespace);

        var items_buffer: [100][]const u8 = undefined;
        var items_count: usize = 0;
        var items_iter = std.mem.tokenizeAny(u8, items_str, " \t");
        while (items_iter.next()) |item| {
            if (items_count >= items_buffer.len) return error.TooManyItems;
            items_buffer[items_count] = try self.allocator.dupe(u8, item);
            items_count += 1;
        }

        var body_buffer: [1000][]const u8 = undefined;
        var body_count: usize = 0;
        var i = start + 1;

        while (i < lines.len) : (i += 1) {
            const line = std.mem.trim(u8, lines[i], &std.ascii.whitespace);

            if (std.mem.eql(u8, line, "do")) continue;
            if (std.mem.eql(u8, line, "done")) break;

            if (line.len > 0 and line[0] != '#') {
                if (body_count >= body_buffer.len) return error.TooManyLines;
                body_buffer[body_count] = try self.allocator.dupe(u8, line);
                body_count += 1;
            }
        }

        const items = try self.allocator.alloc([]const u8, items_count);
        @memcpy(items, items_buffer[0..items_count]);

        const body = try self.allocator.alloc([]const u8, body_count);
        @memcpy(body, body_buffer[0..body_count]);

        return .{
            .loop = ForLoop{
                .variable = variable,
                .items = items,
                .body = body,
                .allocator = self.allocator,
            },
            .end = i,
        };
    }

    /// Parse C-style for loop: for ((init; condition; update))
    pub fn parseCStyleFor(self: *ControlFlowParser, lines: [][]const u8, start: usize) !struct { loop: CStyleForLoop, end: usize } {
        const first_line = std.mem.trim(u8, lines[start], &std.ascii.whitespace);

        if (!std.mem.startsWith(u8, first_line, "for ((")) return error.InvalidCStyleFor;

        // Find the closing ))
        const expr_start = 6; // After "for (("
        const expr_end = std.mem.indexOf(u8, first_line[expr_start..], "))") orelse return error.InvalidCStyleFor;
        const expr = first_line[expr_start..][0..expr_end];

        // Split by semicolons: init; condition; update
        var parts: [3]?[]const u8 = .{ null, null, null };
        var parts_count: usize = 0;
        var part_iter = std.mem.splitSequence(u8, expr, ";");
        while (part_iter.next()) |part| : (parts_count += 1) {
            if (parts_count >= 3) return error.InvalidCStyleFor;
            const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                parts[parts_count] = try self.allocator.dupe(u8, trimmed);
            }
        }

        // Parse body
        var body_buffer: [1000][]const u8 = undefined;
        var body_count: usize = 0;
        var i = start + 1;

        while (i < lines.len) : (i += 1) {
            const line = std.mem.trim(u8, lines[i], &std.ascii.whitespace);

            if (std.mem.eql(u8, line, "do")) continue;
            if (std.mem.eql(u8, line, "done")) break;

            if (line.len > 0 and line[0] != '#') {
                if (body_count >= body_buffer.len) return error.TooManyLines;
                body_buffer[body_count] = try self.allocator.dupe(u8, line);
                body_count += 1;
            }
        }

        const body = try self.allocator.alloc([]const u8, body_count);
        @memcpy(body, body_buffer[0..body_count]);

        return .{
            .loop = CStyleForLoop{
                .init = parts[0],
                .condition = parts[1],
                .update = parts[2],
                .body = body,
                .allocator = self.allocator,
            },
            .end = i,
        };
    }

    /// Parse select menu: select VAR in ITEM1 ITEM2 ITEM3
    pub fn parseSelect(self: *ControlFlowParser, lines: [][]const u8, start: usize) !struct { menu: SelectMenu, end: usize } {
        const first_line = std.mem.trim(u8, lines[start], &std.ascii.whitespace);

        if (!std.mem.startsWith(u8, first_line, "select ")) return error.InvalidSelect;

        // Parse: select VAR in ITEM1 ITEM2 ITEM3
        const parts_start = 7; // After "select "
        const in_pos = std.mem.indexOf(u8, first_line[parts_start..], " in ") orelse return error.InvalidSelect;

        const variable = try self.allocator.dupe(u8, std.mem.trim(u8, first_line[parts_start..][0..in_pos], &std.ascii.whitespace));

        const items_start = parts_start + in_pos + 4; // After " in "
        const items_end = std.mem.indexOf(u8, first_line[items_start..], ";") orelse first_line[items_start..].len;
        const items_str = std.mem.trim(u8, first_line[items_start..][0..items_end], &std.ascii.whitespace);

        var items_buffer: [100][]const u8 = undefined;
        var items_count: usize = 0;
        var items_iter = std.mem.tokenizeAny(u8, items_str, " \t");
        while (items_iter.next()) |item| {
            if (items_count >= items_buffer.len) return error.TooManyItems;
            items_buffer[items_count] = try self.allocator.dupe(u8, item);
            items_count += 1;
        }

        var body_buffer: [1000][]const u8 = undefined;
        var body_count: usize = 0;
        var i = start + 1;

        while (i < lines.len) : (i += 1) {
            const line = std.mem.trim(u8, lines[i], &std.ascii.whitespace);

            if (std.mem.eql(u8, line, "do")) continue;
            if (std.mem.eql(u8, line, "done")) break;

            if (line.len > 0 and line[0] != '#') {
                if (body_count >= body_buffer.len) return error.TooManyLines;
                body_buffer[body_count] = try self.allocator.dupe(u8, line);
                body_count += 1;
            }
        }

        const items = try self.allocator.alloc([]const u8, items_count);
        @memcpy(items, items_buffer[0..items_count]);

        const body = try self.allocator.alloc([]const u8, body_count);
        @memcpy(body, body_buffer[0..body_count]);

        // Default PS3 prompt
        const prompt = try self.allocator.dupe(u8, "#? ");

        return .{
            .menu = SelectMenu{
                .variable = variable,
                .items = items,
                .body = body,
                .prompt = prompt,
                .allocator = self.allocator,
            },
            .end = i,
        };
    }
};
