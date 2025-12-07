const std = @import("std");

/// Completion callback function type
/// Takes the current input and returns a list of completions
pub const CompletionFn = *const fn (input: []const u8, allocator: std.mem.Allocator) anyerror![][]const u8;

/// Editing mode (Emacs or Vi)
pub const EditingMode = enum {
    emacs,
    vi,
};

/// Vi mode state (for vi editing mode)
pub const ViMode = enum {
    insert, // Insert mode - characters are inserted
    normal, // Normal mode - navigation and commands
    replace, // Replace mode - characters replace existing
};

/// Undo state for undo/redo functionality
pub const UndoState = struct {
    buffer: [4096]u8,
    length: usize,
    cursor: usize,
};
