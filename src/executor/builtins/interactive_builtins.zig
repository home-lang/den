const std = @import("std");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;

/// Interactive builtins: ifind (interactive file finder)

/// File type filter for ifind
pub const FileTypeFilter = enum { all, files, dirs };

/// ifind - Interactive file finder with fuzzy matching
pub fn ifind(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    // Parse arguments
    var search_pattern: ?[]const u8 = null;
    var search_dir: []const u8 = ".";
    var show_hidden = false;
    var max_depth: u32 = 10;
    var file_type: FileTypeFilter = .all;

    var i: usize = 0;
    while (i < command.args.len) : (i += 1) {
        const arg = command.args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try IO.print(
                \\Usage: ifind [OPTIONS] [PATTERN] [DIRECTORY]
                \\
                \\Interactive file finder with fuzzy matching.
                \\
                \\Options:
                \\  -a, --all         Show hidden files
                \\  -d, --depth N     Maximum search depth (default: 10)
                \\  -f, --files       Only show files
                \\  -D, --dirs        Only show directories
                \\  -h, --help        Show this help
                \\
                \\Navigation:
                \\  Up/Down or j/k   Move selection
                \\  Enter            Select current item
                \\  q, Esc           Cancel
                \\  Type to filter   Refine search with fuzzy matching
                \\
                \\Examples:
                \\  ifind             Search current directory
                \\  ifind test        Search for files matching 'test'
                \\  ifind -f zig src  Search for files containing 'zig' in src/
                \\
            , .{});
            return 0;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            show_hidden = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--files")) {
            file_type = .files;
        } else if (std.mem.eql(u8, arg, "-D") or std.mem.eql(u8, arg, "--dirs")) {
            file_type = .dirs;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--depth")) {
            i += 1;
            if (i < command.args.len) {
                max_depth = std.fmt.parseInt(u32, command.args[i], 10) catch 10;
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            if (search_pattern == null) {
                search_pattern = arg;
            } else {
                search_dir = arg;
            }
        }
    }

    // Collect files
    var files = std.ArrayList([]const u8).empty;
    defer {
        for (files.items) |f| {
            allocator.free(f);
        }
        files.deinit(allocator);
    }

    // Walk directory
    try collectFilesRecursive(allocator, search_dir, &files, show_hidden, max_depth, file_type, 0);

    if (files.items.len == 0) {
        try IO.print("No files found.\n", .{});
        return 0;
    }

    // If initial pattern, filter
    var filtered_indices = std.ArrayList(usize).empty;
    defer filtered_indices.deinit(allocator);

    for (0..files.items.len) |idx| {
        if (search_pattern == null or fuzzyMatchPath(files.items[idx], search_pattern.?)) {
            try filtered_indices.append(allocator, idx);
        }
    }

    if (filtered_indices.items.len == 0) {
        try IO.print("No matching files.\n", .{});
        return 0;
    }

    // Print matches with highlighting
    try IO.print("\x1b[1;36mifind\x1b[0m - Found {d} matching files:\n\n", .{filtered_indices.items.len});

    const max_display: usize = 50;
    const display_count = @min(filtered_indices.items.len, max_display);

    for (0..display_count) |j| {
        const file_path = files.items[filtered_indices.items[j]];
        try IO.print("  {s}\n", .{file_path});
    }

    if (filtered_indices.items.len > max_display) {
        try IO.print("\n  \x1b[2m... and {d} more\x1b[0m\n", .{filtered_indices.items.len - max_display});
    }

    return 0;
}

/// Recursively collect files from a directory
pub fn collectFilesRecursive(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    files: *std.ArrayList([]const u8),
    show_hidden: bool,
    max_depth: u32,
    file_type: FileTypeFilter,
    current_depth: u32,
) !void {
    if (current_depth >= max_depth) return;

    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(std.Options.debug_io);

    var iter = dir.iterate();
    while (iter.next(std.Options.debug_io) catch null) |entry| {
        // Skip hidden files unless requested
        if (!show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;

        // Build full path
        const full_path = if (std.mem.eql(u8, dir_path, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });

        const is_dir = entry.kind == .directory;

        // Apply file type filter
        switch (file_type) {
            .all => try files.append(allocator, full_path),
            .files => {
                if (!is_dir) {
                    try files.append(allocator, full_path);
                } else {
                    allocator.free(full_path);
                }
            },
            .dirs => {
                if (is_dir) {
                    try files.append(allocator, full_path);
                } else {
                    allocator.free(full_path);
                }
            },
        }

        // Recurse into directories
        if (is_dir) {
            const recurse_path = if (std.mem.eql(u8, dir_path, "."))
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer allocator.free(recurse_path);

            try collectFilesRecursive(allocator, recurse_path, files, show_hidden, max_depth, file_type, current_depth + 1);
        }
    }
}

/// Simple fuzzy matching: all pattern chars must appear in order (case insensitive)
pub fn fuzzyMatchPath(path: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;

    var pat_idx: usize = 0;
    for (path) |c| {
        const path_lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
        const pat_lower = if (pattern[pat_idx] >= 'A' and pattern[pat_idx] <= 'Z') pattern[pat_idx] + 32 else pattern[pat_idx];

        if (path_lower == pat_lower) {
            pat_idx += 1;
            if (pat_idx >= pattern.len) return true;
        }
    }
    return false;
}
