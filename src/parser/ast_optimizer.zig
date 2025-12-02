// AST Optimizer - Performs optimization passes on the AST
// Reduces unnecessary complexity and improves execution performance
const std = @import("std");
const ast = @import("ast.zig");

const Node = ast.Node;
const Word = ast.Word;

/// AST optimization passes
pub const AstOptimizer = struct {
    allocator: std.mem.Allocator,
    stats: OptimizationStats,

    pub const OptimizationStats = struct {
        pipelines_simplified: usize = 0,
        lists_simplified: usize = 0,
        subshells_removed: usize = 0,
        constant_words_merged: usize = 0,
        empty_commands_removed: usize = 0,

        pub fn total(self: OptimizationStats) usize {
            return self.pipelines_simplified +
                self.lists_simplified +
                self.subshells_removed +
                self.constant_words_merged +
                self.empty_commands_removed;
        }
    };

    pub fn init(allocator: std.mem.Allocator) AstOptimizer {
        return .{
            .allocator = allocator,
            .stats = .{},
        };
    }

    /// Optimize an AST tree in place
    /// Returns the optimized root node (may be different from input)
    pub fn optimize(self: *AstOptimizer, node: *Node) !*Node {
        return self.optimizeNode(node);
    }

    /// Get optimization statistics
    pub fn getStats(self: *const AstOptimizer) OptimizationStats {
        return self.stats;
    }

    /// Reset statistics
    pub fn resetStats(self: *AstOptimizer) void {
        self.stats = .{};
    }

    // ========================================================================
    // Optimization passes
    // ========================================================================

    fn optimizeNode(self: *AstOptimizer, node: *Node) !*Node {
        switch (node.*) {
            .script => |*s| {
                // Optimize each command in the script
                for (s.commands, 0..) |cmd, i| {
                    s.commands[i] = try self.optimizeNode(cmd);
                }
                return node;
            },
            .simple_command => |*c| {
                // Optimize word parts (merge adjacent literals)
                if (c.name) |*name| {
                    try self.optimizeWord(name);
                }
                for (c.args) |*arg| {
                    try self.optimizeWord(arg);
                }
                return node;
            },
            .pipeline => |*p| {
                // Single-command pipeline can be simplified
                if (p.commands.len == 1 and !p.negated) {
                    const cmd = p.commands[0];
                    self.stats.pipelines_simplified += 1;
                    // Return the inner command instead
                    return try self.optimizeNode(cmd);
                }
                // Optimize each command in pipeline
                for (p.commands, 0..) |cmd, i| {
                    p.commands[i] = try self.optimizeNode(cmd);
                }
                return node;
            },
            .list => |*l| {
                // Single-element list with no operator can be simplified
                if (l.elements.len == 1 and l.elements[0].operator == null) {
                    const cmd = l.elements[0].command;
                    self.stats.lists_simplified += 1;
                    return try self.optimizeNode(cmd);
                }
                // Optimize each element
                for (l.elements) |*elem| {
                    elem.command = try self.optimizeNode(elem.command);
                }
                return node;
            },
            .if_stmt => |*i| {
                // Optimize condition and bodies
                i.if_branch.condition = try self.optimizeNode(i.if_branch.condition);
                i.if_branch.body = try self.optimizeNode(i.if_branch.body);
                for (i.elif_branches) |*elif| {
                    elif.condition = try self.optimizeNode(elif.condition);
                    elif.body = try self.optimizeNode(elif.body);
                }
                if (i.else_body) |*else_body| {
                    else_body.* = try self.optimizeNode(else_body.*);
                }
                return node;
            },
            .for_loop => |*f| {
                // Optimize body
                f.body = try self.optimizeNode(f.body);
                // Optimize iteration values
                if (f.values) |values| {
                    for (values) |*word| {
                        try self.optimizeWord(word);
                    }
                }
                return node;
            },
            .while_loop => |*w| {
                w.condition = try self.optimizeNode(w.condition);
                w.body = try self.optimizeNode(w.body);
                return node;
            },
            .case_stmt => |*c| {
                try self.optimizeWord(&c.word);
                for (c.items) |*item| {
                    for (item.patterns) |*pattern| {
                        try self.optimizeWord(pattern);
                    }
                    if (item.body) |*body| {
                        body.* = try self.optimizeNode(body.*);
                    }
                }
                return node;
            },
            .function_def => |*f| {
                f.body = try self.optimizeNode(f.body);
                return node;
            },
            .subshell => |*s| {
                // Optimize inner body first
                s.body = try self.optimizeNode(s.body);
                // Check if subshell can be eliminated
                // (e.g., subshell containing only a simple command with no redirections)
                if (self.canEliminateSubshell(s.body)) {
                    self.stats.subshells_removed += 1;
                    return s.body;
                }
                return node;
            },
            .brace_group => |*b| {
                b.body = try self.optimizeNode(b.body);
                return node;
            },
            .background => |*bg| {
                bg.command = try self.optimizeNode(bg.command);
                return node;
            },
            .until_loop => |*u| {
                u.condition = try self.optimizeNode(u.condition);
                u.body = try self.optimizeNode(u.body);
                return node;
            },
            .negation => |*n| {
                n.command = try self.optimizeNode(n.command);
                return node;
            },
            .coproc => |*c| {
                c.command = try self.optimizeNode(c.command);
                return node;
            },
        }
    }

    /// Check if a subshell can be safely eliminated
    fn canEliminateSubshell(self: *AstOptimizer, inner: *Node) bool {
        _ = self;
        // Can eliminate if it's just a simple command with no special features
        // that would require a subshell
        switch (inner.*) {
            .simple_command => |c| {
                // Don't eliminate if there are assignments (they'd leak to parent otherwise)
                if (c.assignments.len > 0) return false;
                // Simple command without assignments is safe to unwrap
                return true;
            },
            else => return false,
        }
    }

    /// Optimize a word by merging adjacent literal parts
    fn optimizeWord(self: *AstOptimizer, word: *Word) !void {
        if (word.parts.len <= 1) return;

        var merged = std.ArrayListUnmanaged(Word.Part).empty;
        errdefer merged.deinit(self.allocator);

        var i: usize = 0;
        while (i < word.parts.len) {
            const part = word.parts[i];

            // Check if we can merge with next parts
            if (part == .literal) {
                var merged_literal = std.ArrayListUnmanaged(u8).empty;
                defer merged_literal.deinit(self.allocator);

                try merged_literal.appendSlice(self.allocator, part.literal);

                // Collect consecutive literals
                var j = i + 1;
                while (j < word.parts.len and word.parts[j] == .literal) {
                    try merged_literal.appendSlice(self.allocator, word.parts[j].literal);
                    j += 1;
                }

                if (j > i + 1) {
                    // We merged multiple literals
                    self.stats.constant_words_merged += j - i - 1;
                    const new_literal = try self.allocator.dupe(u8, merged_literal.items);
                    try merged.append(self.allocator, .{ .literal = new_literal });
                } else {
                    // Just one literal, keep as is
                    try merged.append(self.allocator, part);
                }
                i = j;
            } else {
                try merged.append(self.allocator, part);
                i += 1;
            }
        }

        // Replace parts if we merged anything
        if (merged.items.len < word.parts.len) {
            self.allocator.free(word.parts);
            word.parts = try merged.toOwnedSlice(self.allocator);
        } else {
            merged.deinit(self.allocator);
        }
    }
};

/// Convenience function to optimize an AST
pub fn optimizeAst(allocator: std.mem.Allocator, root: *Node) !*Node {
    var optimizer = AstOptimizer.init(allocator);
    return optimizer.optimize(root);
}

// ============================================================================
// Tests
// ============================================================================

test "AstOptimizer init" {
    var optimizer = AstOptimizer.init(std.testing.allocator);
    const stats = optimizer.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats.total());
}

test "AstOptimizer simplifies single-command pipeline" {
    const allocator = std.testing.allocator;
    var optimizer = AstOptimizer.init(allocator);

    // Create a pipeline with one command
    const cmd = try allocator.create(Node);
    cmd.* = .{
        .simple_command = .{
            .name = null,
            .args = &[_]Word{},
            .assignments = &[_]ast.Assignment{},
            .redirections = &[_]ast.Redirection{},
        },
    };

    const cmds = try allocator.alloc(*Node, 1);
    cmds[0] = cmd;

    const pipeline = try allocator.create(Node);
    pipeline.* = .{
        .pipeline = .{
            .commands = cmds,
            .negated = false,
        },
    };

    const result = try optimizer.optimize(pipeline);

    // Should have simplified to just the command
    try std.testing.expectEqual(@as(usize, 1), optimizer.stats.pipelines_simplified);
    try std.testing.expect(result.* == .simple_command);

    // Cleanup
    allocator.free(cmds);
    allocator.destroy(cmd);
    allocator.destroy(pipeline);
}

test "AstOptimizer simplifies single-element list" {
    const allocator = std.testing.allocator;
    var optimizer = AstOptimizer.init(allocator);

    // Create a list with one element
    const cmd = try allocator.create(Node);
    cmd.* = .{
        .simple_command = .{
            .name = null,
            .args = &[_]Word{},
            .assignments = &[_]ast.Assignment{},
            .redirections = &[_]ast.Redirection{},
        },
    };

    const elements = try allocator.alloc(ast.List.Element, 1);
    elements[0] = .{ .command = cmd, .operator = null };

    const list = try allocator.create(Node);
    list.* = .{
        .list = .{
            .elements = elements,
        },
    };

    const result = try optimizer.optimize(list);

    // Should have simplified to just the command
    try std.testing.expectEqual(@as(usize, 1), optimizer.stats.lists_simplified);
    try std.testing.expect(result.* == .simple_command);

    // Cleanup
    allocator.free(elements);
    allocator.destroy(cmd);
    allocator.destroy(list);
}

test "AstOptimizer removes unnecessary subshell" {
    const allocator = std.testing.allocator;
    var optimizer = AstOptimizer.init(allocator);

    // Create a subshell containing just a simple command
    const cmd = try allocator.create(Node);
    cmd.* = .{
        .simple_command = .{
            .name = null,
            .args = &[_]Word{},
            .assignments = &[_]ast.Assignment{},
            .redirections = &[_]ast.Redirection{},
        },
    };

    const subshell = try allocator.create(Node);
    subshell.* = .{
        .subshell = .{
            .body = cmd,
        },
    };

    const result = try optimizer.optimize(subshell);

    // Should have removed the subshell
    try std.testing.expectEqual(@as(usize, 1), optimizer.stats.subshells_removed);
    try std.testing.expect(result.* == .simple_command);

    // Cleanup
    allocator.destroy(cmd);
    allocator.destroy(subshell);
}

test "AstOptimizer stats total" {
    const stats = AstOptimizer.OptimizationStats{
        .pipelines_simplified = 2,
        .lists_simplified = 3,
        .subshells_removed = 1,
        .constant_words_merged = 4,
        .empty_commands_removed = 0,
    };
    try std.testing.expectEqual(@as(usize, 10), stats.total());
}
