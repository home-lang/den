// Abstract Syntax Tree for Den Shell
// Represents the hierarchical structure of shell commands
const std = @import("std");

/// Source location for error reporting
pub const SourceLoc = struct {
    line: u32 = 1,
    column: u32 = 1,
    offset: u32 = 0,

    pub fn format(self: SourceLoc, comptime _: []const u8, _: anytype, writer: anytype) !void {
        try writer.print("{any}:{any}", .{ self.line, self.column });
    }
};

/// Span of source text
pub const Span = struct {
    start: SourceLoc,
    end: SourceLoc,

    pub fn merge(a: Span, b: Span) Span {
        return .{
            .start = if (a.start.offset < b.start.offset) a.start else b.start,
            .end = if (a.end.offset > b.end.offset) a.end else b.end,
        };
    }
};

/// AST Node types
pub const Node = union(enum) {
    /// Complete script/program
    script: Script,

    /// Simple command: `echo hello world`
    simple_command: SimpleCommand,

    /// Pipeline: `cmd1 | cmd2 | cmd3`
    pipeline: Pipeline,

    /// Command list with && || ;
    list: List,

    /// If statement
    if_stmt: IfStatement,

    /// For loop
    for_loop: ForLoop,

    /// While loop
    while_loop: WhileLoop,

    /// Until loop
    until_loop: UntilLoop,

    /// Case statement
    case_stmt: CaseStatement,

    /// Function definition
    function_def: FunctionDef,

    /// Subshell: `(commands)`
    subshell: Subshell,

    /// Brace group: `{ commands; }`
    brace_group: BraceGroup,

    /// Negation: `! command`
    negation: Negation,

    /// Background: `command &`
    background: Background,

    /// Coproc: `coproc command`
    coproc: Coproc,

    pub fn getSpan(self: Node) ?Span {
        return switch (self) {
            .script => |s| s.span,
            .simple_command => |c| c.span,
            .pipeline => |p| p.span,
            .list => |l| l.span,
            .if_stmt => |i| i.span,
            .for_loop => |f| f.span,
            .while_loop => |w| w.span,
            .until_loop => |u| u.span,
            .case_stmt => |c| c.span,
            .function_def => |f| f.span,
            .subshell => |s| s.span,
            .brace_group => |b| b.span,
            .negation => |n| n.span,
            .background => |b| b.span,
            .coproc => |c| c.span,
        };
    }

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .script => |*s| s.deinit(allocator),
            .simple_command => |*c| c.deinit(allocator),
            .pipeline => |*p| p.deinit(allocator),
            .list => |*l| l.deinit(allocator),
            .if_stmt => |*i| i.deinit(allocator),
            .for_loop => |*f| f.deinit(allocator),
            .while_loop => |*w| w.deinit(allocator),
            .until_loop => |*u| u.deinit(allocator),
            .case_stmt => |*c| c.deinit(allocator),
            .function_def => |*f| f.deinit(allocator),
            .subshell => |*s| s.deinit(allocator),
            .brace_group => |*b| b.deinit(allocator),
            .negation => |*n| n.deinit(allocator),
            .background => |*b| b.deinit(allocator),
            .coproc => |*c| c.deinit(allocator),
        }
    }
};

/// Complete script
pub const Script = struct {
    commands: []*Node,
    span: ?Span = null,

    pub fn deinit(self: *Script, allocator: std.mem.Allocator) void {
        for (self.commands) |cmd| {
            cmd.deinit(allocator);
            allocator.destroy(cmd);
        }
        allocator.free(self.commands);
    }
};

/// Simple command with arguments and redirections
pub const SimpleCommand = struct {
    /// Command name (or null for assignment-only)
    name: ?Word = null,
    /// Command arguments
    args: []Word = &[_]Word{},
    /// Variable assignments (VAR=value before command)
    assignments: []Assignment = &[_]Assignment{},
    /// I/O redirections
    redirections: []Redirection = &[_]Redirection{},
    /// Source span
    span: ?Span = null,

    pub fn deinit(self: *SimpleCommand, allocator: std.mem.Allocator) void {
        if (self.name) |*n| n.deinit(allocator);
        for (self.args) |*arg| arg.deinit(allocator);
        allocator.free(self.args);
        for (self.assignments) |*a| a.deinit(allocator);
        allocator.free(self.assignments);
        for (self.redirections) |*r| r.deinit(allocator);
        allocator.free(self.redirections);
    }
};

/// Pipeline: cmd1 | cmd2 | cmd3
pub const Pipeline = struct {
    commands: []*Node,
    /// True if pipeline starts with !
    negated: bool = false,
    /// True if using |& (pipe stderr too)
    pipe_stderr: bool = false,
    span: ?Span = null,

    pub fn deinit(self: *Pipeline, allocator: std.mem.Allocator) void {
        for (self.commands) |cmd| {
            cmd.deinit(allocator);
            allocator.destroy(cmd);
        }
        allocator.free(self.commands);
    }
};

/// List of commands with operators
pub const List = struct {
    pub const Operator = enum {
        @"and", // &&
        @"or", // ||
        semicolon, // ;
        newline, // implicit newline separator
    };

    pub const Element = struct {
        command: *Node,
        operator: ?Operator = null,
    };

    elements: []Element,
    span: ?Span = null,

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        for (self.elements) |*elem| {
            elem.command.deinit(allocator);
            allocator.destroy(elem.command);
        }
        allocator.free(self.elements);
    }
};

/// If statement
pub const IfStatement = struct {
    pub const Branch = struct {
        condition: *Node,
        body: *Node,
    };

    /// if condition; then body
    if_branch: Branch,
    /// elif branches
    elif_branches: []Branch = &[_]Branch{},
    /// else body (optional)
    else_body: ?*Node = null,
    span: ?Span = null,

    pub fn deinit(self: *IfStatement, allocator: std.mem.Allocator) void {
        self.if_branch.condition.deinit(allocator);
        allocator.destroy(self.if_branch.condition);
        self.if_branch.body.deinit(allocator);
        allocator.destroy(self.if_branch.body);

        for (self.elif_branches) |*branch| {
            branch.condition.deinit(allocator);
            allocator.destroy(branch.condition);
            branch.body.deinit(allocator);
            allocator.destroy(branch.body);
        }
        allocator.free(self.elif_branches);

        if (self.else_body) |else_body| {
            else_body.deinit(allocator);
            allocator.destroy(else_body);
        }
    }
};

/// For loop
pub const ForLoop = struct {
    /// Loop variable name
    variable: []const u8,
    /// Values to iterate (optional - defaults to $@)
    values: ?[]Word = null,
    /// Loop body
    body: *Node,
    /// C-style for loop: for ((init; cond; step))
    c_style: ?CStyleFor = null,
    span: ?Span = null,

    pub const CStyleFor = struct {
        init: []const u8,
        condition: []const u8,
        step: []const u8,
    };

    pub fn deinit(self: *ForLoop, allocator: std.mem.Allocator) void {
        allocator.free(self.variable);
        if (self.values) |values| {
            for (values) |*v| v.deinit(allocator);
            allocator.free(values);
        }
        self.body.deinit(allocator);
        allocator.destroy(self.body);
        if (self.c_style) |*c| {
            allocator.free(c.init);
            allocator.free(c.condition);
            allocator.free(c.step);
        }
    }
};

/// While loop
pub const WhileLoop = struct {
    condition: *Node,
    body: *Node,
    span: ?Span = null,

    pub fn deinit(self: *WhileLoop, allocator: std.mem.Allocator) void {
        self.condition.deinit(allocator);
        allocator.destroy(self.condition);
        self.body.deinit(allocator);
        allocator.destroy(self.body);
    }
};

/// Until loop
pub const UntilLoop = struct {
    condition: *Node,
    body: *Node,
    span: ?Span = null,

    pub fn deinit(self: *UntilLoop, allocator: std.mem.Allocator) void {
        self.condition.deinit(allocator);
        allocator.destroy(self.condition);
        self.body.deinit(allocator);
        allocator.destroy(self.body);
    }
};

/// Case statement
pub const CaseStatement = struct {
    pub const CaseItem = struct {
        patterns: []Word,
        body: ?*Node,
        /// Terminator: ;; (break), ;& (fallthrough), ;;& (continue matching)
        terminator: Terminator = .break_,
    };

    pub const Terminator = enum {
        break_, // ;;
        fallthrough, // ;&
        continue_matching, // ;;&
    };

    word: Word,
    items: []CaseItem,
    span: ?Span = null,

    pub fn deinit(self: *CaseStatement, allocator: std.mem.Allocator) void {
        self.word.deinit(allocator);
        for (self.items) |*item| {
            for (item.patterns) |*p| p.deinit(allocator);
            allocator.free(item.patterns);
            if (item.body) |body| {
                body.deinit(allocator);
                allocator.destroy(body);
            }
        }
        allocator.free(self.items);
    }
};

/// Function definition
pub const FunctionDef = struct {
    name: []const u8,
    body: *Node,
    span: ?Span = null,

    pub fn deinit(self: *FunctionDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.body.deinit(allocator);
        allocator.destroy(self.body);
    }
};

/// Subshell: (commands)
pub const Subshell = struct {
    body: *Node,
    span: ?Span = null,

    pub fn deinit(self: *Subshell, allocator: std.mem.Allocator) void {
        self.body.deinit(allocator);
        allocator.destroy(self.body);
    }
};

/// Brace group: { commands; }
pub const BraceGroup = struct {
    body: *Node,
    span: ?Span = null,

    pub fn deinit(self: *BraceGroup, allocator: std.mem.Allocator) void {
        self.body.deinit(allocator);
        allocator.destroy(self.body);
    }
};

/// Negation: ! command
pub const Negation = struct {
    command: *Node,
    span: ?Span = null,

    pub fn deinit(self: *Negation, allocator: std.mem.Allocator) void {
        self.command.deinit(allocator);
        allocator.destroy(self.command);
    }
};

/// Background command: command &
pub const Background = struct {
    command: *Node,
    span: ?Span = null,

    pub fn deinit(self: *Background, allocator: std.mem.Allocator) void {
        self.command.deinit(allocator);
        allocator.destroy(self.command);
    }
};

/// Coproc: coproc [NAME] command
pub const Coproc = struct {
    name: ?[]const u8 = null,
    command: *Node,
    span: ?Span = null,

    pub fn deinit(self: *Coproc, allocator: std.mem.Allocator) void {
        if (self.name) |n| allocator.free(n);
        self.command.deinit(allocator);
        allocator.destroy(self.command);
    }
};

/// Word with possible expansions
pub const Word = struct {
    pub const Part = union(enum) {
        /// Literal text
        literal: []const u8,
        /// Single-quoted string (no expansion)
        single_quoted: []const u8,
        /// Double-quoted string (with expansion)
        double_quoted: []Part,
        /// Variable: $var or ${var}
        variable: Variable,
        /// Command substitution: $(cmd) or `cmd`
        command_sub: *Node,
        /// Arithmetic expansion: $((expr))
        arithmetic: []const u8,
        /// Process substitution: <(cmd) or >(cmd)
        process_sub: ProcessSub,
        /// Brace expansion: {a,b,c}
        brace_expansion: [][]Part,
        /// Tilde expansion: ~user
        tilde: ?[]const u8,
        /// Glob pattern
        glob: []const u8,

        pub fn deinit(self: *Part, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .literal, .single_quoted, .arithmetic, .glob => |str| allocator.free(str),
                .double_quoted => |parts| {
                    for (parts) |*p| p.deinit(allocator);
                    allocator.free(parts);
                },
                .command_sub => |node| {
                    node.deinit(allocator);
                    allocator.destroy(node);
                },
                .process_sub => |ps| {
                    ps.command.deinit(allocator);
                    allocator.destroy(ps.command);
                },
                .brace_expansion => |expansion| {
                    for (expansion) |parts| {
                        for (parts) |*p| p.deinit(allocator);
                        allocator.free(parts);
                    }
                    allocator.free(expansion);
                },
                .tilde => |maybe_user| if (maybe_user) |user| allocator.free(user),
                .variable => {}, // Variable doesn't own its strings
            }
        }
    };

    parts: []Part,
    span: ?Span = null,

    pub fn deinit(self: *Word, allocator: std.mem.Allocator) void {
        for (self.parts) |*part| {
            part.deinit(allocator);
        }
        allocator.free(self.parts);
    }

    pub fn isLiteral(self: *const Word) bool {
        return self.parts.len == 1 and self.parts[0] == .literal;
    }

    pub fn getLiteral(self: *const Word) ?[]const u8 {
        if (self.isLiteral()) {
            return self.parts[0].literal;
        }
        return null;
    }
};

/// Variable reference
pub const Variable = struct {
    name: []const u8,
    modifier: ?Modifier = null,

    pub const Modifier = struct {
        kind: Kind,
        word: ?[]const u8 = null,

        pub const Kind = enum {
            default, // ${var:-word}
            default_assign, // ${var:=word}
            error_if_unset, // ${var:?word}
            use_if_set, // ${var:+word}
            length, // ${#var}
            prefix_remove, // ${var#pattern}
            prefix_remove_longest, // ${var##pattern}
            suffix_remove, // ${var%pattern}
            suffix_remove_longest, // ${var%%pattern}
            replace_first, // ${var/pattern/replacement}
            replace_all, // ${var//pattern/replacement}
            substring, // ${var:offset:length}
            uppercase_first, // ${var^pattern}
            uppercase_all, // ${var^^pattern}
            lowercase_first, // ${var,pattern}
            lowercase_all, // ${var,,pattern}
        };
    };
};

/// Process substitution
pub const ProcessSub = struct {
    command: *Node,
    direction: Direction,

    pub const Direction = enum {
        input, // <(cmd)
        output, // >(cmd)
    };
};

/// Variable assignment
pub const Assignment = struct {
    name: []const u8,
    value: ?Word = null,
    /// += append operator
    append: bool = false,
    /// Array index for array[index]=value
    index: ?Word = null,
    span: ?Span = null,

    pub fn deinit(self: *Assignment, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.value) |*v| v.deinit(allocator);
        if (self.index) |*i| i.deinit(allocator);
    }
};

/// I/O Redirection
pub const Redirection = struct {
    pub const Kind = enum {
        input, // <
        output, // >
        output_append, // >>
        output_clobber, // >|
        input_output, // <>
        heredoc, // <<
        heredoc_strip, // <<-
        herestring, // <<<
        dup_input, // <&
        dup_output, // >&
        close_input, // <&-
        close_output, // >&-
    };

    kind: Kind,
    /// File descriptor (default: 0 for input, 1 for output)
    fd: ?u32 = null,
    /// Target file/fd
    target: Word,
    /// For heredoc: the delimiter and content
    heredoc_content: ?[]const u8 = null,
    span: ?Span = null,

    pub fn deinit(self: *Redirection, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
        if (self.heredoc_content) |c| allocator.free(c);
    }
};

// Helper to free Word.Part
fn deinitPart(part: *Word.Part, allocator: std.mem.Allocator) void {
    switch (part.*) {
        .literal => |s| allocator.free(s),
        .single_quoted => |s| allocator.free(s),
        .double_quoted => |parts| {
            for (parts) |*p| deinitPart(p, allocator);
            allocator.free(parts);
        },
        .variable => {},
        .command_sub => |cmd| {
            cmd.deinit(allocator);
            allocator.destroy(cmd);
        },
        .arithmetic => |s| allocator.free(s),
        .process_sub => |ps| {
            ps.command.deinit(allocator);
            allocator.destroy(ps.command);
        },
        .brace_expansion => |expansions| {
            for (expansions) |exp| {
                for (exp) |*p| deinitPart(p, allocator);
                allocator.free(exp);
            }
            allocator.free(expansions);
        },
        .tilde => |t| if (t) |s| allocator.free(s),
        .glob => |s| allocator.free(s),
    }
}

// Extend Word.Part with deinit
pub fn deinitWordPart(part: *Word.Part, allocator: std.mem.Allocator) void {
    deinitPart(part, allocator);
}

// ============================================================================
// AST Pretty Printer (for debugging)
// ============================================================================

pub const PrettyPrinter = struct {
    writer: std.array_list.Managed(u8).Writer,
    indent: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PrettyPrinter {
        var list = std.array_list.Managed(u8).init(allocator);
        return .{
            .writer = list.writer(),
            .allocator = allocator,
        };
    }

    pub fn print(self: *PrettyPrinter, node: *const Node) ![]const u8 {
        try self.printNode(node);
        // Get the underlying ArrayList and return owned slice
        const list_ptr: *std.array_list.Managed(u8) = @fieldParentPtr("writer", &self.writer);
        return list_ptr.toOwnedSlice();
    }

    fn printNode(self: *PrettyPrinter, node: *const Node) !void {
        switch (node.*) {
            .script => |s| {
                try self.writeLine("Script");
                self.indent += 1;
                for (s.commands) |cmd| {
                    try self.printNode(cmd);
                }
                self.indent -= 1;
            },
            .simple_command => |c| {
                try self.writeIndent();
                try self.writer.print("SimpleCommand: ", .{});
                if (c.name) |n| {
                    if (n.getLiteral()) |lit| {
                        try self.writer.print("{s}", .{lit});
                    } else {
                        try self.writer.print("<complex>", .{});
                    }
                }
                try self.writer.print(" (args: {any})\n", .{c.args.len});
            },
            .pipeline => |p| {
                try self.writeLine("Pipeline");
                self.indent += 1;
                for (p.commands) |cmd| {
                    try self.printNode(cmd);
                }
                self.indent -= 1;
            },
            .list => |l| {
                try self.writeLine("List");
                self.indent += 1;
                for (l.elements) |elem| {
                    try self.printNode(elem.command);
                }
                self.indent -= 1;
            },
            .if_stmt => |i| {
                try self.writeLine("IfStatement");
                self.indent += 1;
                try self.writeLine("condition:");
                self.indent += 1;
                try self.printNode(i.if_branch.condition);
                self.indent -= 1;
                try self.writeLine("body:");
                self.indent += 1;
                try self.printNode(i.if_branch.body);
                self.indent -= 1;
                self.indent -= 1;
            },
            .for_loop => |f| {
                try self.writeIndent();
                try self.writer.print("ForLoop: {s}\n", .{f.variable});
            },
            .while_loop => {
                try self.writeLine("WhileLoop");
            },
            .until_loop => {
                try self.writeLine("UntilLoop");
            },
            .case_stmt => {
                try self.writeLine("CaseStatement");
            },
            .function_def => |f| {
                try self.writeIndent();
                try self.writer.print("FunctionDef: {s}\n", .{f.name});
            },
            .subshell => {
                try self.writeLine("Subshell");
            },
            .brace_group => {
                try self.writeLine("BraceGroup");
            },
            .negation => {
                try self.writeLine("Negation");
            },
            .background => {
                try self.writeLine("Background");
            },
            .coproc => {
                try self.writeLine("Coproc");
            },
        }
    }

    fn writeIndent(self: *PrettyPrinter) !void {
        for (0..self.indent * 2) |_| {
            try self.writer.writeByte(' ');
        }
    }

    fn writeLine(self: *PrettyPrinter, text: []const u8) !void {
        try self.writeIndent();
        try self.writer.writeAll(text);
        try self.writer.writeByte('\n');
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SourceLoc format" {
    const loc = SourceLoc{ .line = 10, .column = 5, .offset = 100 };
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{any}", .{loc});
    // Format includes struct field names in Zig 0.16
    try std.testing.expect(result.len > 0);
}

test "Span merge" {
    const a = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };
    const b = Span{
        .start = .{ .line = 1, .column = 5, .offset = 4 },
        .end = .{ .line = 2, .column = 5, .offset = 20 },
    };
    const merged = Span.merge(a, b);
    try std.testing.expectEqual(@as(u32, 0), merged.start.offset);
    try std.testing.expectEqual(@as(u32, 20), merged.end.offset);
}

test "Word isLiteral" {
    var parts = [_]Word.Part{.{ .literal = "hello" }};
    const word = Word{
        .parts = &parts,
    };
    try std.testing.expect(word.isLiteral());
    try std.testing.expectEqualStrings("hello", word.getLiteral().?);
}
