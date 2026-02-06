const std = @import("std");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;

fn getenv(key: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

/// File operations builtins: tree, grep, find, ft, ls, json, calc
/// Extracted from executor/mod.zig for better modularity

pub fn tree(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    const path = if (command.args.len > 0) command.args[0] else ".";
    try IO.print("{s}\n", .{path});
    try printTree(allocator, path, "");
    return 0;
}

fn printTree(allocator: std.mem.Allocator, dir_path: []const u8, prefix: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io,dir_path, .{ .iterate = true }) catch |err| {
        try IO.eprint("den: tree: cannot open {s}: {}\n", .{ dir_path, err });
        return;
    };
    defer dir.close(std.Options.debug_io);

    var iter = dir.iterate();
    var entries: std.ArrayList(std.Io.Dir.Entry) = .{};
    defer entries.deinit(allocator);

    while (try iter.next(std.Options.debug_io)) |entry| {
        try entries.append(allocator, entry);
    }

    for (entries.items, 0..) |entry, i| {
        const is_last_entry = i == entries.items.len - 1;
        const connector = if (is_last_entry) "└── " else "├── ";

        try IO.print("{s}{s}{s}\n", .{ prefix, connector, entry.name });

        if (entry.kind == .directory) {
            const new_prefix_buf = try std.fmt.allocPrint(
                allocator,
                "{s}{s}",
                .{ prefix, if (is_last_entry) "    " else "│   " },
            );
            defer allocator.free(new_prefix_buf);

            const sub_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            defer allocator.free(sub_path);

            try printTree(allocator, sub_path, new_prefix_buf);
        }
    }
}

pub fn grep(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("den: grep: missing pattern\n", .{});
        try IO.eprint("den: grep: usage: grep [-i] [-n] [-v] [-c] [--color] [--no-color] pattern [file...]\n", .{});
        return 1;
    }

    var case_insensitive = false;
    var show_line_numbers = false;
    var invert_match = false;
    var count_only = false;
    var use_color = true;
    var show_filename = false;
    var pattern_idx: usize = 0;

    for (command.args, 0..) |arg, i| {
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--color") or std.mem.eql(u8, arg, "--colour")) {
                use_color = true;
                pattern_idx = i + 1;
            } else if (std.mem.eql(u8, arg, "--no-color") or std.mem.eql(u8, arg, "--no-colour")) {
                use_color = false;
                pattern_idx = i + 1;
            } else if (std.mem.eql(u8, arg, "-H")) {
                show_filename = true;
                pattern_idx = i + 1;
            } else if (std.mem.eql(u8, arg, "--help")) {
                try IO.print("grep - search for patterns in files\n", .{});
                try IO.print("Usage: grep [options] pattern [file...]\n", .{});
                try IO.print("Options:\n", .{});
                try IO.print("  -i          Case insensitive search\n", .{});
                try IO.print("  -n          Show line numbers\n", .{});
                try IO.print("  -v          Invert match (show non-matching lines)\n", .{});
                try IO.print("  -c          Count matches only\n", .{});
                try IO.print("  -H          Show filename for each match\n", .{});
                try IO.print("  --color     Highlight matches (default)\n", .{});
                try IO.print("  --no-color  Disable highlighting\n", .{});
                return 0;
            } else {
                for (arg[1..]) |c| {
                    if (c == 'i') case_insensitive = true else if (c == 'n') show_line_numbers = true else if (c == 'v') invert_match = true else if (c == 'c') count_only = true else if (c == 'H') show_filename = true else {
                        try IO.eprint("den: grep: invalid option: -{c}\n", .{c});
                        return 1;
                    }
                }
                pattern_idx = i + 1;
            }
        } else {
            break;
        }
    }

    if (pattern_idx >= command.args.len) {
        try IO.eprint("den: grep: missing pattern\n", .{});
        return 1;
    }

    const pattern = command.args[pattern_idx];
    const files = if (pattern_idx + 1 < command.args.len) command.args[pattern_idx + 1 ..] else &[_][]const u8{};

    if (files.len == 0) {
        try IO.print("den: grep: reading from stdin not yet implemented\n", .{});
        return 1;
    }

    const display_filename = show_filename or files.len > 1;
    const color_match = "\x1b[1;31m";
    const color_linenum = "\x1b[32m";
    const color_filename = "\x1b[35m";
    const color_reset = "\x1b[0m";

    var total_matches: usize = 0;

    for (files) |file_path| {
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io,file_path, .{}) catch |err| {
            try IO.eprint("den: grep: {s}: {}\n", .{ file_path, err });
            continue;
        };
        defer file.close(std.Options.debug_io);

        const max_size: usize = 10 * 1024 * 1024;
        const file_size = (file.stat(std.Options.debug_io) catch {
            try IO.eprint("den: grep: error reading {s}\n", .{file_path});
            continue;
        }).size;
        const read_size: usize = @min(file_size, max_size);
        const buffer = allocator.alloc(u8, read_size) catch {
            try IO.eprint("den: grep: out of memory\n", .{});
            continue;
        };
        defer allocator.free(buffer);
        var total_read: usize = 0;
        while (total_read < read_size) {
            const n = file.readStreaming(std.Options.debug_io, &.{buffer[total_read..]}) catch break;
            if (n == 0) break;
            total_read += n;
        }
        const content = buffer[0..total_read];

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        var line_num: usize = 1;
        var file_matches: usize = 0;

        while (line_iter.next()) |line| {
            var matches = false;
            var match_pos: ?usize = null;

            if (case_insensitive) {
                var idx: usize = 0;
                while (idx + pattern.len <= line.len) : (idx += 1) {
                    if (std.ascii.eqlIgnoreCase(line[idx .. idx + pattern.len], pattern)) {
                        matches = true;
                        match_pos = idx;
                        break;
                    }
                }
            } else {
                match_pos = std.mem.indexOf(u8, line, pattern);
                matches = match_pos != null;
            }

            if (invert_match) matches = !matches;

            if (matches) {
                file_matches += 1;
                total_matches += 1;

                if (!count_only) {
                    if (display_filename) {
                        if (use_color) {
                            try IO.print("{s}{s}{s}:", .{ color_filename, file_path, color_reset });
                        } else {
                            try IO.print("{s}:", .{file_path});
                        }
                    }

                    if (show_line_numbers) {
                        if (use_color) {
                            try IO.print("{s}{d}{s}:", .{ color_linenum, line_num, color_reset });
                        } else {
                            try IO.print("{d}:", .{line_num});
                        }
                    }

                    if (use_color and !invert_match and match_pos != null) {
                        try printHighlightedLine(line, pattern, case_insensitive, color_match, color_reset);
                    } else {
                        try IO.print("{s}\n", .{line});
                    }
                }
            }

            line_num += 1;
        }

        if (count_only) {
            if (display_filename) {
                try IO.print("{s}:{d}\n", .{ file_path, file_matches });
            } else {
                try IO.print("{d}\n", .{file_matches});
            }
        }
    }

    return if (total_matches > 0) 0 else 1;
}

fn printHighlightedLine(line: []const u8, pattern: []const u8, case_insensitive: bool, color_on: []const u8, color_off: []const u8) !void {
    if (pattern.len == 0) {
        try IO.print("{s}\n", .{line});
        return;
    }

    var pos: usize = 0;
    while (pos < line.len) {
        var match_start: ?usize = null;

        if (case_insensitive) {
            var idx = pos;
            while (idx + pattern.len <= line.len) : (idx += 1) {
                if (std.ascii.eqlIgnoreCase(line[idx .. idx + pattern.len], pattern)) {
                    match_start = idx;
                    break;
                }
            }
        } else {
            match_start = std.mem.indexOfPos(u8, line, pos, pattern);
        }

        if (match_start) |start| {
            if (start > pos) {
                try IO.print("{s}", .{line[pos..start]});
            }
            try IO.print("{s}{s}{s}", .{ color_on, line[start .. start + pattern.len], color_off });
            pos = start + pattern.len;
        } else {
            try IO.print("{s}", .{line[pos..]});
            break;
        }
    }
    try IO.print("\n", .{});
}

pub fn find(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    const start_path = if (command.args.len > 0 and command.args[0][0] != '-') command.args[0] else ".";

    var name_pattern: ?[]const u8 = null;
    var type_filter: ?u8 = null;

    var i: usize = if (std.mem.eql(u8, start_path, ".")) 0 else 1;
    while (i < command.args.len) : (i += 1) {
        const arg = command.args[i];
        if (std.mem.eql(u8, arg, "-name") and i + 1 < command.args.len) {
            name_pattern = command.args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "-type") and i + 1 < command.args.len) {
            const type_str = command.args[i + 1];
            if (type_str.len == 1) {
                type_filter = type_str[0];
            }
            i += 1;
        }
    }

    try findRecursive(allocator, start_path, name_pattern, type_filter);
    return 0;
}

fn findRecursive(allocator: std.mem.Allocator, dir_path: []const u8, name_pattern: ?[]const u8, type_filter: ?u8) !void {
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io,dir_path, .{ .iterate = true }) catch |err| {
        try IO.eprint("den: find: cannot open {s}: {}\n", .{ dir_path, err });
        return;
    };
    defer dir.close(std.Options.debug_io);

    var iter = dir.iterate();

    while (try iter.next(std.Options.debug_io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
            continue;
        }

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(full_path);

        if (type_filter) |filter| {
            if (filter == 'f' and entry.kind != .file) continue;
            if (filter == 'd' and entry.kind != .directory) continue;
        }

        if (name_pattern) |pattern| {
            if (!matchPattern(entry.name, pattern)) {
                if (entry.kind == .directory) {
                    try findRecursive(allocator, full_path, name_pattern, type_filter);
                }
                continue;
            }
        }

        try IO.print("{s}\n", .{full_path});

        if (entry.kind == .directory) {
            try findRecursive(allocator, full_path, name_pattern, type_filter);
        }
    }
}

fn matchPattern(name: []const u8, pattern: []const u8) bool {
    if (std.mem.indexOf(u8, pattern, "*")) |star_pos| {
        const prefix = pattern[0..star_pos];
        const suffix = pattern[star_pos + 1 ..];

        if (prefix.len > 0 and !std.mem.startsWith(u8, name, prefix)) {
            return false;
        }

        if (suffix.len > 0 and !std.mem.endsWith(u8, name, suffix)) {
            return false;
        }

        return true;
    } else {
        return std.mem.eql(u8, name, pattern);
    }
}

const FuzzyResult = struct {
    path: []const u8,
    score: u32,
};

pub fn ft(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    var pattern: ?[]const u8 = null;
    var type_filter: ?u8 = null;
    var max_depth: usize = 10;
    var max_results: usize = 50;
    var start_path: []const u8 = ".";

    var i: usize = 0;
    while (i < command.args.len) : (i += 1) {
        const arg = command.args[i];
        if (std.mem.eql(u8, arg, "-t") and i + 1 < command.args.len) {
            const type_str = command.args[i + 1];
            if (type_str.len >= 1) {
                type_filter = type_str[0];
            }
            i += 1;
        } else if (std.mem.eql(u8, arg, "-d") and i + 1 < command.args.len) {
            max_depth = std.fmt.parseInt(usize, command.args[i + 1], 10) catch 10;
            i += 1;
        } else if (std.mem.eql(u8, arg, "-n") and i + 1 < command.args.len) {
            max_results = std.fmt.parseInt(usize, command.args[i + 1], 10) catch 50;
            i += 1;
        } else if (std.mem.eql(u8, arg, "-p") and i + 1 < command.args.len) {
            start_path = command.args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try IO.print("ft - fuzzy file finder\n", .{});
            try IO.print("Usage: ft [pattern] [-t f|d] [-d depth] [-n limit] [-p path]\n", .{});
            try IO.print("Options:\n", .{});
            try IO.print("  -t f|d    Filter by type (f=file, d=directory)\n", .{});
            try IO.print("  -d N      Maximum depth (default: 10)\n", .{});
            try IO.print("  -n N      Maximum results (default: 50)\n", .{});
            try IO.print("  -p PATH   Start path (default: .)\n", .{});
            try IO.print("Examples:\n", .{});
            try IO.print("  ft main       Find files matching 'main'\n", .{});
            try IO.print("  ft .zig -t f  Find .zig files only\n", .{});
            try IO.print("  ft src -t d   Find directories matching 'src'\n", .{});
            return 0;
        } else if (arg[0] != '-') {
            pattern = arg;
        }
    }

    if (pattern == null) {
        try IO.eprint("den: ft: missing pattern\n", .{});
        try IO.eprint("den: ft: usage: ft [pattern] [-t f|d] [-d depth] [-n limit]\n", .{});
        return 1;
    }

    var results = std.ArrayList(FuzzyResult).empty;
    defer {
        for (results.items) |*item| {
            allocator.free(item.path);
        }
        results.deinit(allocator);
    }

    try fuzzyFindRecursive(allocator, start_path, pattern.?, type_filter, max_depth, 0, &results, max_results * 2);

    std.mem.sort(FuzzyResult, results.items, {}, struct {
        fn lessThan(_: void, a: FuzzyResult, b: FuzzyResult) bool {
            return a.score > b.score;
        }
    }.lessThan);

    const count = @min(results.items.len, max_results);
    for (results.items[0..count]) |result| {
        try IO.print("{s}\n", .{result.path});
    }

    if (results.items.len == 0) {
        try IO.eprint("den: ft: no matches found for '{s}'\n", .{pattern.?});
        return 1;
    }

    return 0;
}

fn fuzzyFindRecursive(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    pattern: []const u8,
    type_filter: ?u8,
    max_depth: usize,
    current_depth: usize,
    results: *std.ArrayList(FuzzyResult),
    max_collect: usize,
) !void {
    if (current_depth >= max_depth) return;
    if (results.items.len >= max_collect) return;

    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io,dir_path, .{ .iterate = true }) catch {
        return;
    };
    defer dir.close(std.Options.debug_io);

    var iter = dir.iterate();

    while (try iter.next(std.Options.debug_io)) |entry| {
        if (results.items.len >= max_collect) break;

        if (entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        if (std.mem.eql(u8, entry.name, "target")) continue;
        if (std.mem.eql(u8, entry.name, "zig-cache")) continue;
        if (std.mem.eql(u8, entry.name, ".zig-cache")) continue;
        if (std.mem.eql(u8, entry.name, "zig-out")) continue;
        if (std.mem.eql(u8, entry.name, "__pycache__")) continue;
        if (std.mem.eql(u8, entry.name, ".git")) continue;

        if (type_filter) |filter| {
            if (filter == 'f' and entry.kind != .file) {
                if (entry.kind == .directory) {
                    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
                    defer allocator.free(full_path);
                    try fuzzyFindRecursive(allocator, full_path, pattern, type_filter, max_depth, current_depth + 1, results, max_collect);
                }
                continue;
            }
            if (filter == 'd' and entry.kind != .directory) continue;
        }

        const score = fuzzyMatchScore(entry.name, pattern);
        if (score > 0) {
            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            try results.append(allocator, .{ .path = full_path, .score = score });
        }

        if (entry.kind == .directory) {
            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            defer allocator.free(full_path);
            try fuzzyFindRecursive(allocator, full_path, pattern, type_filter, max_depth, current_depth + 1, results, max_collect);
        }
    }
}

fn fuzzyMatchScore(name: []const u8, pattern: []const u8) u32 {
    if (pattern.len == 0) return 0;
    if (name.len == 0) return 0;

    var name_lower: [256]u8 = undefined;
    var pattern_lower: [256]u8 = undefined;

    const name_len = @min(name.len, 255);
    const pattern_len = @min(pattern.len, 255);

    for (name[0..name_len], 0..) |c, idx| {
        name_lower[idx] = std.ascii.toLower(c);
    }
    for (pattern[0..pattern_len], 0..) |c, idx| {
        pattern_lower[idx] = std.ascii.toLower(c);
    }

    const name_lc = name_lower[0..name_len];
    const pattern_lc = pattern_lower[0..pattern_len];

    if (std.mem.eql(u8, name_lc, pattern_lc)) {
        return 1000;
    }

    if (std.mem.startsWith(u8, name_lc, pattern_lc)) {
        return 800;
    }

    if (std.mem.indexOf(u8, name_lc, pattern_lc) != null) {
        return 600;
    }

    if (std.mem.endsWith(u8, name_lc, pattern_lc)) {
        return 500;
    }

    var score: u32 = 0;
    var name_idx: usize = 0;
    var consecutive: u32 = 0;
    var first_match: bool = true;

    for (pattern_lc) |pc| {
        var found = false;
        while (name_idx < name_len) : (name_idx += 1) {
            if (name_lc[name_idx] == pc) {
                found = true;
                score += 10;

                if (consecutive > 0) {
                    score += consecutive * 5;
                }
                consecutive += 1;

                if (first_match and name_idx == 0) {
                    score += 50;
                }

                if (name_idx > 0) {
                    const prev = name_lc[name_idx - 1];
                    if (prev == '.' or prev == '-' or prev == '_' or prev == '/') {
                        score += 30;
                    }
                }

                first_match = false;
                name_idx += 1;
                break;
            } else {
                consecutive = 0;
            }
        }
        if (!found) return 0;
    }

    return score;
}

pub fn calc(command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("den: calc: missing expression\n", .{});
        try IO.eprint("den: calc: usage: calc <expression>\n", .{});
        try IO.eprint("den: calc: examples: calc 2 + 2, calc 10 * 5, calc 100 / 4\n", .{});
        return 1;
    }

    var expr_buf: [1024]u8 = undefined;
    var expr_len: usize = 0;

    for (command.args, 0..) |arg, i| {
        if (i > 0 and expr_len < expr_buf.len) {
            expr_buf[expr_len] = ' ';
            expr_len += 1;
        }

        const copy_len = @min(arg.len, expr_buf.len - expr_len);
        @memcpy(expr_buf[expr_len .. expr_len + copy_len], arg[0..copy_len]);
        expr_len += copy_len;
    }

    const expr = expr_buf[0..expr_len];

    const result = evaluateExpression(expr) catch |err| {
        try IO.eprint("den: calc: invalid expression: {}\n", .{err});
        return 1;
    };

    try IO.print("{d}\n", .{result});
    return 0;
}

fn evaluateExpression(expr: []const u8) !f64 {
    const trimmed = std.mem.trim(u8, expr, " \t");

    var i: usize = trimmed.len;
    while (i > 0) {
        i -= 1;
        const c = trimmed[i];
        if (c == '+' or c == '-') {
            if (i == 0) continue;
            const left = try evaluateExpression(trimmed[0..i]);
            const right = try evaluateExpression(trimmed[i + 1 ..]);
            return if (c == '+') left + right else left - right;
        }
    }

    i = trimmed.len;
    while (i > 0) {
        i -= 1;
        const c = trimmed[i];
        if (c == '*' or c == '/') {
            const left = try evaluateExpression(trimmed[0..i]);
            const right = try evaluateExpression(trimmed[i + 1 ..]);
            return if (c == '*') left * right else left / right;
        }
    }

    return std.fmt.parseFloat(f64, trimmed);
}

pub fn json(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("den: json: missing file argument\n", .{});
        try IO.eprint("den: json: usage: json <file>\n", .{});
        return 1;
    }

    const file_path = command.args[0];
    const file = std.Io.Dir.cwd().openFile(std.Options.debug_io,file_path, .{}) catch |err| {
        try IO.eprint("den: json: cannot open {s}: {}\n", .{ file_path, err });
        return 1;
    };
    defer file.close(std.Options.debug_io);

    const max_size: usize = 10 * 1024 * 1024;
    const file_size = (file.stat(std.Options.debug_io) catch |err| {
        try IO.eprint("den: json: error reading {s}: {}\n", .{ file_path, err });
        return 1;
    }).size;
    const read_size: usize = @min(file_size, max_size);
    const buffer = allocator.alloc(u8, read_size) catch |err| {
        try IO.eprint("den: json: out of memory: {}\n", .{err});
        return 1;
    };
    defer allocator.free(buffer);
    var total_read: usize = 0;
    while (total_read < read_size) {
        const n = file.readStreaming(std.Options.debug_io, &.{buffer[total_read..]}) catch |err| {
            try IO.eprint("den: json: error reading {s}: {}\n", .{ file_path, err });
            return 1;
        };
        if (n == 0) break;
        total_read += n;
    }
    const content = buffer[0..total_read];

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| {
        try IO.eprint("den: json: invalid JSON: {}\n", .{err});
        return 1;
    };
    defer parsed.deinit();

    try IO.print("{s}\n", .{content});

    return 0;
}

pub fn ls(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    var show_all = false;
    var long_format = false;
    var reverse = false;
    var sort_by_time = false;
    var sort_by_size = false;
    var human_readable = false;
    var recursive = false;
    var one_per_line = false;
    var directory_only = false;
    var target_path: []const u8 = ".";

    for (command.args) |arg| {
        if (arg.len > 0 and arg[0] == '-') {
            for (arg[1..]) |c| {
                switch (c) {
                    'a' => show_all = true,
                    'l' => long_format = true,
                    'r' => reverse = true,
                    't' => sort_by_time = true,
                    'S' => sort_by_size = true,
                    'h' => human_readable = true,
                    'R' => recursive = true,
                    '1' => one_per_line = true,
                    'd' => directory_only = true,
                    else => {
                        try IO.eprint("den: ls: invalid option -- '{c}'\n", .{c});
                        return 1;
                    },
                }
            }
        } else {
            target_path = arg;
        }
    }

    if (directory_only) {
        try IO.print("{s}\n", .{target_path});
        return 0;
    }

    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io,target_path, .{ .iterate = true }) catch |err| {
        try IO.eprint("den: ls: cannot access '{s}': {}\n", .{ target_path, err });
        return 1;
    };
    defer dir.close(std.Options.debug_io);

    const EntryInfo = struct {
        name: []const u8,
        kind: std.Io.File.Kind,
        size: u64,
        mtime_ns: i96,
    };

    var entries: [512]EntryInfo = undefined;
    var count: usize = 0;

    var iter = dir.iterate();
    while (try iter.next(std.Options.debug_io)) |entry| {
        if (!show_all and entry.name.len > 0 and entry.name[0] == '.') continue;
        if (count >= 512) break;

        const stat = dir.statFile(std.Options.debug_io, entry.name, .{}) catch |err| {
            if (err == error.IsDir) {
                const dir_stat = dir.stat(std.Options.debug_io) catch {
                    entries[count] = .{
                        .name = try allocator.dupe(u8, entry.name),
                        .kind = entry.kind,
                        .size = 0,
                        .mtime_ns = 0,
                    };
                    count += 1;
                    continue;
                };
                entries[count] = .{
                    .name = try allocator.dupe(u8, entry.name),
                    .kind = entry.kind,
                    .size = dir_stat.size,
                    .mtime_ns = dir_stat.mtime.nanoseconds,
                };
            } else {
                entries[count] = .{
                    .name = try allocator.dupe(u8, entry.name),
                    .kind = entry.kind,
                    .size = 0,
                    .mtime_ns = 0,
                };
            }
            count += 1;
            continue;
        };

        entries[count] = .{
            .name = try allocator.dupe(u8, entry.name),
            .kind = entry.kind,
            .size = stat.size,
            .mtime_ns = stat.mtime.nanoseconds,
        };
        count += 1;
    }

    // Sort entries
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var j: usize = i + 1;
        while (j < count) : (j += 1) {
            const should_swap = if (sort_by_size)
                if (reverse)
                    entries[i].size < entries[j].size
                else
                    entries[i].size > entries[j].size
            else if (sort_by_time)
                if (reverse)
                    entries[i].mtime_ns < entries[j].mtime_ns
                else
                    entries[i].mtime_ns > entries[j].mtime_ns
            else if (reverse)
                std.mem.order(u8, entries[i].name, entries[j].name) == .lt
            else
                std.mem.order(u8, entries[i].name, entries[j].name) == .gt;

            if (should_swap) {
                const temp = entries[i];
                entries[i] = entries[j];
                entries[j] = temp;
            }
        }
    }

    if (long_format) {
        var total_blocks: u64 = 0;
        i = 0;
        while (i < count) : (i += 1) {
            // Approximate blocks from size (512-byte blocks)
            total_blocks += (entries[i].size + 511) / 512;
        }
        try IO.print("total {d}\n", .{total_blocks});

        i = 0;
        while (i < count) : (i += 1) {
            const entry = entries[i];

            const path_buf = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ target_path, entry.name });
            defer allocator.free(path_buf);

            const path_z = try std.posix.toPosixPath(path_buf);
            const maybe_st = dir.statFile(std.Options.debug_io, entry.name, .{}) catch null;

            const kind_char: u8 = switch (entry.kind) {
                .directory => 'd',
                .sym_link => 'l',
                else => '-',
            };

            var perms_buf: [9]u8 = undefined;
            if (maybe_st) |st| {
                const mode = st.permissions.toMode();
                perms_buf[0] = if (mode & 0o400 != 0) 'r' else '-';
                perms_buf[1] = if (mode & 0o200 != 0) 'w' else '-';
                perms_buf[2] = if (mode & 0o100 != 0) 'x' else '-';
                perms_buf[3] = if (mode & 0o040 != 0) 'r' else '-';
                perms_buf[4] = if (mode & 0o020 != 0) 'w' else '-';
                perms_buf[5] = if (mode & 0o010 != 0) 'x' else '-';
                perms_buf[6] = if (mode & 0o004 != 0) 'r' else '-';
                perms_buf[7] = if (mode & 0o002 != 0) 'w' else '-';
                perms_buf[8] = if (mode & 0o001 != 0) 'x' else '-';
            } else {
                @memcpy(&perms_buf, "rw-r--r--");
            }
            const perms = perms_buf[0..];

            var has_xattr = false;
            {
                const listxattr = struct {
                    extern "c" fn listxattr(path: [*:0]const u8, namebuf: ?[*]u8, size: usize, options: c_int) isize;
                }.listxattr;
                const xattr_list_size = listxattr(&path_z, null, 0, 0);
                has_xattr = xattr_list_size > 0;
            }

            const nlink: u64 = if (maybe_st) |st| @intCast(st.nlink) else 1;

            const username = getenv("USER") orelse "user";
            const groupname = "staff";

            const size_str = if (human_readable) blk: {
                if (entry.size < 1024) {
                    break :blk try std.fmt.allocPrint(allocator, "{d}", .{entry.size});
                } else if (entry.size < 1024 * 1024) {
                    break :blk try std.fmt.allocPrint(allocator, "{d}K", .{entry.size / 1024});
                } else if (entry.size < 1024 * 1024 * 1024) {
                    break :blk try std.fmt.allocPrint(allocator, "{d}M", .{entry.size / (1024 * 1024)});
                } else {
                    break :blk try std.fmt.allocPrint(allocator, "{d}G", .{entry.size / (1024 * 1024 * 1024)});
                }
            } else try std.fmt.allocPrint(allocator, "{d}", .{entry.size});
            defer allocator.free(size_str);

            const time_ns: u64 = @intCast(@max(0, entry.mtime_ns));
            const time_s = time_ns / std.time.ns_per_s;

            const seconds_per_day = 86400;
            const days_since_epoch = time_s / seconds_per_day;
            const seconds_today = time_s % seconds_per_day;
            const hours = seconds_today / 3600;
            const minutes = (seconds_today % 3600) / 60;

            const day_of_year = @mod(days_since_epoch, 365);
            const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
            const month_idx = @min((day_of_year / 30), 11);
            const day = @mod(day_of_year, 30) + 1;

            const time_str = try std.fmt.allocPrint(
                allocator,
                "{s} {d:>2} {d:0>2}:{d:0>2}",
                .{ month_names[month_idx], day, hours, minutes },
            );
            defer allocator.free(time_str);

            const xattr_char = if (has_xattr) "@" else " ";
            if (entry.kind == .directory) {
                try IO.print("{c}{s}{s} {d:>3} {s:<20} {s:<10} {d:>8} {s} \x1b[1;36m{s}\x1b[0m\n", .{
                    kind_char,
                    perms,
                    xattr_char,
                    nlink,
                    username,
                    groupname,
                    entry.size,
                    time_str,
                    entry.name,
                });
            } else {
                try IO.print("{c}{s}{s} {d:>3} {s:<20} {s:<10} {d:>8} {s} {s}\n", .{
                    kind_char,
                    perms,
                    xattr_char,
                    nlink,
                    username,
                    groupname,
                    entry.size,
                    time_str,
                    entry.name,
                });
            }
        }
    } else {
        if (one_per_line) {
            i = 0;
            while (i < count) : (i += 1) {
                if (entries[i].kind == .directory) {
                    try IO.print("\x1b[1;36m{s}\x1b[0m\n", .{entries[i].name});
                } else {
                    try IO.print("{s}\n", .{entries[i].name});
                }
            }
        } else {
            var max_len: usize = 0;
            i = 0;
            while (i < count) : (i += 1) {
                if (entries[i].name.len > max_len) {
                    max_len = entries[i].name.len;
                }
            }

            const signals = @import("../../utils/signals.zig");
            const term_width = if (signals.getWindowSize()) |ws| ws.cols else |_| 80;

            const col_width = max_len + 2;
            const num_cols = @max(1, term_width / col_width);
            const num_rows = (count + num_cols - 1) / num_cols;

            var row: usize = 0;
            while (row < num_rows) : (row += 1) {
                var col: usize = 0;
                while (col < num_cols) : (col += 1) {
                    const idx = col * num_rows + row;
                    if (idx >= count) break;

                    const entry = entries[idx];
                    const padding = col_width - entry.name.len;

                    if (entry.kind == .directory) {
                        try IO.print("\x1b[1;36m{s}\x1b[0m", .{entry.name});
                    } else {
                        try IO.print("{s}", .{entry.name});
                    }

                    if (col < num_cols - 1 and idx + num_rows < count) {
                        var p: usize = 0;
                        while (p < padding) : (p += 1) {
                            try IO.print(" ", .{});
                        }
                    }
                }
                try IO.print("\n", .{});
            }
        }
    }

    if (recursive) {
        i = 0;
        while (i < count) : (i += 1) {
            if (entries[i].kind == .directory) {
                if (std.mem.eql(u8, entries[i].name, ".") or std.mem.eql(u8, entries[i].name, "..")) {
                    continue;
                }

                try IO.print("\n{s}/{s}:\n", .{ target_path, entries[i].name });

                const new_path = try std.fmt.allocPrint(
                    allocator,
                    "{s}/{s}",
                    .{ target_path, entries[i].name },
                );
                defer allocator.free(new_path);

                var recursive_args_buf: [2][]const u8 = undefined;
                var recursive_args_len: usize = 0;

                var flag_buf: [32]u8 = undefined;
                var flag_len: usize = 0;
                flag_buf[flag_len] = '-';
                flag_len += 1;
                if (show_all) {
                    flag_buf[flag_len] = 'a';
                    flag_len += 1;
                }
                if (long_format) {
                    flag_buf[flag_len] = 'l';
                    flag_len += 1;
                }
                if (flag_len > 1) {
                    recursive_args_buf[recursive_args_len] = flag_buf[0..flag_len];
                    recursive_args_len += 1;
                }

                recursive_args_buf[recursive_args_len] = new_path;
                recursive_args_len += 1;

                var recursive_cmd = types.ParsedCommand{
                    .name = "ls",
                    .args = recursive_args_buf[0..recursive_args_len],
                    .redirections = &[_]types.Redirection{},
                };

                _ = ls(allocator, &recursive_cmd) catch {};
            }
        }
    }

    // Free copied names
    i = 0;
    while (i < count) : (i += 1) {
        allocator.free(entries[i].name);
    }

    return 0;
}
