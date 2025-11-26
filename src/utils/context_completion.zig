const std = @import("std");

/// Context-Aware Completion
/// Provides intelligent completions based on the command being typed
pub const ContextCompletion = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ContextCompletion {
        return .{ .allocator = allocator };
    }

    /// Detect the context and return appropriate completions
    pub fn complete(self: *ContextCompletion, line: []const u8, cursor_pos: usize) ![]CompletionItem {
        // Parse the line to understand context
        const context = self.parseContext(line, cursor_pos);

        return switch (context.kind) {
            .git_branch => try self.completeGitBranches(context.prefix),
            .git_remote => try self.completeGitRemotes(context.prefix),
            .git_file => try self.completeGitFiles(context.prefix),
            .git_tag => try self.completeGitTags(context.prefix),
            .git_subcommand => try self.completeGitSubcommands(context.prefix),
            .npm_script => try self.completeNpmScripts(context.prefix),
            .npm_subcommand => try self.completeNpmSubcommands(context.prefix),
            .docker_container => try self.completeDockerContainers(context.prefix),
            .docker_image => try self.completeDockerImages(context.prefix),
            .docker_subcommand => try self.completeDockerSubcommands(context.prefix),
            .environment_variable => try self.completeEnvVars(context.prefix),
            .option_flag => try self.completeOptions(context.command, context.prefix),
            .unknown => &[_]CompletionItem{},
        };
    }

    const Context = struct {
        kind: ContextKind,
        command: []const u8,
        prefix: []const u8,
    };

    const ContextKind = enum {
        git_branch,
        git_remote,
        git_file,
        git_tag,
        git_subcommand,
        npm_script,
        npm_subcommand,
        docker_container,
        docker_image,
        docker_subcommand,
        environment_variable,
        option_flag,
        unknown,
    };

    /// Parse command line to determine completion context
    fn parseContext(self: *ContextCompletion, line: []const u8, cursor_pos: usize) Context {
        _ = self;
        const trimmed = std.mem.trim(u8, line[0..@min(cursor_pos, line.len)], " \t");
        if (trimmed.len == 0) {
            return .{ .kind = .unknown, .command = "", .prefix = "" };
        }

        // Split into words
        var words_buf: [32][]const u8 = undefined;
        var word_count: usize = 0;
        var iter = std.mem.tokenizeAny(u8, trimmed, " \t");
        while (iter.next()) |word| {
            if (word_count < words_buf.len) {
                words_buf[word_count] = word;
                word_count += 1;
            }
        }

        if (word_count == 0) {
            return .{ .kind = .unknown, .command = "", .prefix = "" };
        }

        const words = words_buf[0..word_count];
        const cmd = words[0];
        const current_word = if (word_count > 1) words[word_count - 1] else "";

        // Check for environment variable completion ($)
        if (current_word.len > 0 and current_word[0] == '$') {
            return .{
                .kind = .environment_variable,
                .command = cmd,
                .prefix = if (current_word.len > 1) current_word[1..] else "",
            };
        }

        // Check for option flag completion (-)
        if (current_word.len > 0 and current_word[0] == '-') {
            return .{
                .kind = .option_flag,
                .command = cmd,
                .prefix = current_word,
            };
        }

        // Git context
        if (std.mem.eql(u8, cmd, "git")) {
            if (word_count == 1 or (word_count == 2 and !std.mem.endsWith(u8, trimmed, " "))) {
                return .{
                    .kind = .git_subcommand,
                    .command = "git",
                    .prefix = if (word_count > 1) words[1] else "",
                };
            }

            if (word_count >= 2) {
                const subcmd = words[1];

                // Branch operations
                if (std.mem.eql(u8, subcmd, "checkout") or
                    std.mem.eql(u8, subcmd, "switch") or
                    std.mem.eql(u8, subcmd, "merge") or
                    std.mem.eql(u8, subcmd, "rebase") or
                    std.mem.eql(u8, subcmd, "branch"))
                {
                    return .{
                        .kind = .git_branch,
                        .command = "git",
                        .prefix = current_word,
                    };
                }

                // Remote operations
                if (std.mem.eql(u8, subcmd, "push") or
                    std.mem.eql(u8, subcmd, "pull") or
                    std.mem.eql(u8, subcmd, "fetch"))
                {
                    if (word_count == 2 or (word_count == 3 and !std.mem.endsWith(u8, trimmed, " "))) {
                        return .{
                            .kind = .git_remote,
                            .command = "git",
                            .prefix = if (word_count > 2) words[2] else "",
                        };
                    }
                    return .{
                        .kind = .git_branch,
                        .command = "git",
                        .prefix = current_word,
                    };
                }

                // Tag operations
                if (std.mem.eql(u8, subcmd, "tag")) {
                    return .{
                        .kind = .git_tag,
                        .command = "git",
                        .prefix = current_word,
                    };
                }

                // File operations
                if (std.mem.eql(u8, subcmd, "add") or
                    std.mem.eql(u8, subcmd, "diff") or
                    std.mem.eql(u8, subcmd, "restore") or
                    std.mem.eql(u8, subcmd, "rm"))
                {
                    return .{
                        .kind = .git_file,
                        .command = "git",
                        .prefix = current_word,
                    };
                }
            }
        }

        // npm context
        if (std.mem.eql(u8, cmd, "npm") or std.mem.eql(u8, cmd, "bun") or std.mem.eql(u8, cmd, "yarn") or std.mem.eql(u8, cmd, "pnpm")) {
            if (word_count == 1 or (word_count == 2 and !std.mem.endsWith(u8, trimmed, " "))) {
                return .{
                    .kind = .npm_subcommand,
                    .command = cmd,
                    .prefix = if (word_count > 1) words[1] else "",
                };
            }

            if (word_count >= 2) {
                const subcmd = words[1];
                if (std.mem.eql(u8, subcmd, "run") or std.mem.eql(u8, subcmd, "run-script")) {
                    return .{
                        .kind = .npm_script,
                        .command = cmd,
                        .prefix = if (word_count > 2) current_word else "",
                    };
                }
            }
        }

        // Docker context
        if (std.mem.eql(u8, cmd, "docker")) {
            if (word_count == 1 or (word_count == 2 and !std.mem.endsWith(u8, trimmed, " "))) {
                return .{
                    .kind = .docker_subcommand,
                    .command = "docker",
                    .prefix = if (word_count > 1) words[1] else "",
                };
            }

            if (word_count >= 2) {
                const subcmd = words[1];

                // Container operations
                if (std.mem.eql(u8, subcmd, "start") or
                    std.mem.eql(u8, subcmd, "stop") or
                    std.mem.eql(u8, subcmd, "restart") or
                    std.mem.eql(u8, subcmd, "rm") or
                    std.mem.eql(u8, subcmd, "logs") or
                    std.mem.eql(u8, subcmd, "exec") or
                    std.mem.eql(u8, subcmd, "attach"))
                {
                    return .{
                        .kind = .docker_container,
                        .command = "docker",
                        .prefix = current_word,
                    };
                }

                // Image operations
                if (std.mem.eql(u8, subcmd, "run") or
                    std.mem.eql(u8, subcmd, "pull") or
                    std.mem.eql(u8, subcmd, "push") or
                    std.mem.eql(u8, subcmd, "rmi") or
                    std.mem.eql(u8, subcmd, "tag"))
                {
                    return .{
                        .kind = .docker_image,
                        .command = "docker",
                        .prefix = current_word,
                    };
                }
            }
        }

        return .{ .kind = .unknown, .command = cmd, .prefix = current_word };
    }

    // ========================================================================
    // Git Completions
    // ========================================================================

    fn completeGitBranches(self: *ContextCompletion, prefix: []const u8) ![]CompletionItem {
        var items_buf: [128]CompletionItem = undefined;
        var count: usize = 0;

        // Run: git branch --format='%(refname:short)'
        const result = self.runCommand(&[_][]const u8{ "git", "branch", "--format=%(refname:short)" }) catch return &[_]CompletionItem{};
        defer self.allocator.free(result);

        var line_iter = std.mem.splitScalar(u8, result, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t*");
            if (trimmed.len > 0 and std.mem.startsWith(u8, trimmed, prefix)) {
                if (count >= items_buf.len) break;
                items_buf[count] = .{
                    .text = try self.allocator.dupe(u8, trimmed),
                    .description = "branch",
                    .kind = .git_branch,
                };
                count += 1;
            }
        }

        // Also add remote branches
        const remote_result = self.runCommand(&[_][]const u8{ "git", "branch", "-r", "--format=%(refname:short)" }) catch "";
        defer if (remote_result.len > 0) self.allocator.free(remote_result);

        if (remote_result.len > 0) {
            var remote_iter = std.mem.splitScalar(u8, remote_result, '\n');
            while (remote_iter.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t");
                if (trimmed.len > 0 and std.mem.startsWith(u8, trimmed, prefix)) {
                    if (count >= items_buf.len) break;
                    items_buf[count] = .{
                        .text = try self.allocator.dupe(u8, trimmed),
                        .description = "remote",
                        .kind = .git_remote,
                    };
                    count += 1;
                }
            }
        }

        const items = try self.allocator.alloc(CompletionItem, count);
        @memcpy(items, items_buf[0..count]);
        return items;
    }

    fn completeGitRemotes(self: *ContextCompletion, prefix: []const u8) ![]CompletionItem {
        var items_buf: [32]CompletionItem = undefined;
        var count: usize = 0;

        const result = self.runCommand(&[_][]const u8{ "git", "remote" }) catch return &[_]CompletionItem{};
        defer self.allocator.free(result);

        var line_iter = std.mem.splitScalar(u8, result, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len > 0 and std.mem.startsWith(u8, trimmed, prefix)) {
                if (count >= items_buf.len) break;
                items_buf[count] = .{
                    .text = try self.allocator.dupe(u8, trimmed),
                    .description = "remote",
                    .kind = .git_remote,
                };
                count += 1;
            }
        }

        const items = try self.allocator.alloc(CompletionItem, count);
        @memcpy(items, items_buf[0..count]);
        return items;
    }

    fn completeGitTags(self: *ContextCompletion, prefix: []const u8) ![]CompletionItem {
        var items_buf: [128]CompletionItem = undefined;
        var count: usize = 0;

        const result = self.runCommand(&[_][]const u8{ "git", "tag" }) catch return &[_]CompletionItem{};
        defer self.allocator.free(result);

        var line_iter = std.mem.splitScalar(u8, result, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len > 0 and std.mem.startsWith(u8, trimmed, prefix)) {
                if (count >= items_buf.len) break;
                items_buf[count] = .{
                    .text = try self.allocator.dupe(u8, trimmed),
                    .description = "tag",
                    .kind = .git_tag,
                };
                count += 1;
            }
        }

        const items = try self.allocator.alloc(CompletionItem, count);
        @memcpy(items, items_buf[0..count]);
        return items;
    }

    fn completeGitFiles(self: *ContextCompletion, prefix: []const u8) ![]CompletionItem {
        var items_buf: [128]CompletionItem = undefined;
        var count: usize = 0;

        // Get modified files
        const status_result = self.runCommand(&[_][]const u8{ "git", "status", "--porcelain" }) catch "";
        defer if (status_result.len > 0) self.allocator.free(status_result);

        if (status_result.len > 0) {
            var line_iter = std.mem.splitScalar(u8, status_result, '\n');
            while (line_iter.next()) |line| {
                if (line.len < 4) continue;
                const file = std.mem.trim(u8, line[3..], " \t");
                if (file.len > 0 and std.mem.startsWith(u8, file, prefix)) {
                    if (count >= items_buf.len) break;
                    const status = line[0..2];
                    const desc = if (std.mem.eql(u8, status, "M ") or std.mem.eql(u8, status, " M"))
                        "modified"
                    else if (std.mem.eql(u8, status, "A ") or std.mem.eql(u8, status, "AM"))
                        "staged"
                    else if (std.mem.eql(u8, status, "??"))
                        "untracked"
                    else if (std.mem.eql(u8, status, "D ") or std.mem.eql(u8, status, " D"))
                        "deleted"
                    else
                        "changed";

                    items_buf[count] = .{
                        .text = try self.allocator.dupe(u8, file),
                        .description = desc,
                        .kind = .git_file,
                    };
                    count += 1;
                }
            }
        }

        const items = try self.allocator.alloc(CompletionItem, count);
        @memcpy(items, items_buf[0..count]);
        return items;
    }

    fn completeGitSubcommands(self: *ContextCompletion, prefix: []const u8) ![]CompletionItem {
        const subcommands = [_]struct { name: []const u8, desc: []const u8 }{
            .{ .name = "add", .desc = "Add file contents to index" },
            .{ .name = "bisect", .desc = "Binary search for bad commit" },
            .{ .name = "branch", .desc = "List, create, or delete branches" },
            .{ .name = "checkout", .desc = "Switch branches or restore files" },
            .{ .name = "cherry-pick", .desc = "Apply changes from commits" },
            .{ .name = "clone", .desc = "Clone a repository" },
            .{ .name = "commit", .desc = "Record changes to repository" },
            .{ .name = "diff", .desc = "Show changes between commits" },
            .{ .name = "fetch", .desc = "Download from remote" },
            .{ .name = "init", .desc = "Create empty repository" },
            .{ .name = "log", .desc = "Show commit logs" },
            .{ .name = "merge", .desc = "Join branches together" },
            .{ .name = "pull", .desc = "Fetch and merge remote" },
            .{ .name = "push", .desc = "Update remote refs" },
            .{ .name = "rebase", .desc = "Reapply commits on top" },
            .{ .name = "remote", .desc = "Manage remotes" },
            .{ .name = "reset", .desc = "Reset current HEAD" },
            .{ .name = "restore", .desc = "Restore working tree files" },
            .{ .name = "revert", .desc = "Revert commits" },
            .{ .name = "show", .desc = "Show objects" },
            .{ .name = "stash", .desc = "Stash changes" },
            .{ .name = "status", .desc = "Show working tree status" },
            .{ .name = "switch", .desc = "Switch branches" },
            .{ .name = "tag", .desc = "Create, list, or delete tags" },
        };

        var items_buf: [32]CompletionItem = undefined;
        var count: usize = 0;

        for (subcommands) |cmd| {
            if (std.mem.startsWith(u8, cmd.name, prefix)) {
                if (count >= items_buf.len) break;
                items_buf[count] = .{
                    .text = try self.allocator.dupe(u8, cmd.name),
                    .description = cmd.desc,
                    .kind = .command,
                };
                count += 1;
            }
        }

        const items = try self.allocator.alloc(CompletionItem, count);
        @memcpy(items, items_buf[0..count]);
        return items;
    }

    // ========================================================================
    // npm Completions
    // ========================================================================

    pub fn completeNpmScripts(self: *ContextCompletion, prefix: []const u8) ![]CompletionItem {
        var items_buf: [64]CompletionItem = undefined;
        var count: usize = 0;

        // Try to read package.json
        const file = std.fs.cwd().openFile("package.json", .{}) catch return &[_]CompletionItem{};
        defer file.close();

        var buf: [16384]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < buf.len) {
            const bytes_read = file.read(buf[total_read..]) catch break;
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }
        const content = buf[0..total_read];

        // Find "scripts" section
        if (std.mem.indexOf(u8, content, "\"scripts\"")) |scripts_start| {
            if (std.mem.indexOfPos(u8, content, scripts_start, "{")) |brace_start| {
                if (std.mem.indexOfPos(u8, content, brace_start, "}")) |brace_end| {
                    const scripts_content = content[brace_start + 1 .. brace_end];

                    // Parse script names (simple parsing)
                    var iter = std.mem.splitScalar(u8, scripts_content, '\n');
                    while (iter.next()) |line| {
                        const trimmed = std.mem.trim(u8, line, " \t\",");
                        if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
                            const name = std.mem.trim(u8, trimmed[0..colon_pos], " \t\"");
                            if (name.len > 0 and std.mem.startsWith(u8, name, prefix)) {
                                if (count >= items_buf.len) break;
                                items_buf[count] = .{
                                    .text = try self.allocator.dupe(u8, name),
                                    .description = "script",
                                    .kind = .npm_script,
                                };
                                count += 1;
                            }
                        }
                    }
                }
            }
        }

        const items = try self.allocator.alloc(CompletionItem, count);
        @memcpy(items, items_buf[0..count]);
        return items;
    }

    fn completeNpmSubcommands(self: *ContextCompletion, prefix: []const u8) ![]CompletionItem {
        const subcommands = [_]struct { name: []const u8, desc: []const u8 }{
            .{ .name = "add", .desc = "Add a package" },
            .{ .name = "audit", .desc = "Security audit" },
            .{ .name = "build", .desc = "Build a package" },
            .{ .name = "ci", .desc = "Install from lock file" },
            .{ .name = "clean", .desc = "Clean cache" },
            .{ .name = "config", .desc = "Manage config" },
            .{ .name = "create", .desc = "Create a package" },
            .{ .name = "dedupe", .desc = "Reduce duplication" },
            .{ .name = "dev", .desc = "Development mode" },
            .{ .name = "exec", .desc = "Run a command" },
            .{ .name = "init", .desc = "Create package.json" },
            .{ .name = "install", .desc = "Install dependencies" },
            .{ .name = "link", .desc = "Symlink a package" },
            .{ .name = "list", .desc = "List installed packages" },
            .{ .name = "outdated", .desc = "Check for outdated" },
            .{ .name = "pack", .desc = "Create tarball" },
            .{ .name = "prune", .desc = "Remove unused" },
            .{ .name = "publish", .desc = "Publish package" },
            .{ .name = "remove", .desc = "Remove a package" },
            .{ .name = "run", .desc = "Run a script" },
            .{ .name = "search", .desc = "Search packages" },
            .{ .name = "start", .desc = "Start the app" },
            .{ .name = "test", .desc = "Run tests" },
            .{ .name = "uninstall", .desc = "Remove a package" },
            .{ .name = "update", .desc = "Update packages" },
            .{ .name = "version", .desc = "Bump version" },
        };

        var items_buf: [32]CompletionItem = undefined;
        var count: usize = 0;

        for (subcommands) |cmd| {
            if (std.mem.startsWith(u8, cmd.name, prefix)) {
                if (count >= items_buf.len) break;
                items_buf[count] = .{
                    .text = try self.allocator.dupe(u8, cmd.name),
                    .description = cmd.desc,
                    .kind = .command,
                };
                count += 1;
            }
        }

        const items = try self.allocator.alloc(CompletionItem, count);
        @memcpy(items, items_buf[0..count]);
        return items;
    }

    // ========================================================================
    // Docker Completions
    // ========================================================================

    pub fn completeDockerContainers(self: *ContextCompletion, prefix: []const u8) ![]CompletionItem {
        var items_buf: [64]CompletionItem = undefined;
        var count: usize = 0;

        const result = self.runCommand(&[_][]const u8{ "docker", "ps", "-a", "--format", "{{.Names}}" }) catch return &[_]CompletionItem{};
        defer self.allocator.free(result);

        var line_iter = std.mem.splitScalar(u8, result, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len > 0 and std.mem.startsWith(u8, trimmed, prefix)) {
                if (count >= items_buf.len) break;
                items_buf[count] = .{
                    .text = try self.allocator.dupe(u8, trimmed),
                    .description = "container",
                    .kind = .docker_container,
                };
                count += 1;
            }
        }

        const items = try self.allocator.alloc(CompletionItem, count);
        @memcpy(items, items_buf[0..count]);
        return items;
    }

    pub fn completeDockerImages(self: *ContextCompletion, prefix: []const u8) ![]CompletionItem {
        var items_buf: [64]CompletionItem = undefined;
        var count: usize = 0;

        const result = self.runCommand(&[_][]const u8{ "docker", "images", "--format", "{{.Repository}}:{{.Tag}}" }) catch return &[_]CompletionItem{};
        defer self.allocator.free(result);

        var line_iter = std.mem.splitScalar(u8, result, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "<none>:<none>") and std.mem.startsWith(u8, trimmed, prefix)) {
                if (count >= items_buf.len) break;
                items_buf[count] = .{
                    .text = try self.allocator.dupe(u8, trimmed),
                    .description = "image",
                    .kind = .docker_image,
                };
                count += 1;
            }
        }

        const items = try self.allocator.alloc(CompletionItem, count);
        @memcpy(items, items_buf[0..count]);
        return items;
    }

    fn completeDockerSubcommands(self: *ContextCompletion, prefix: []const u8) ![]CompletionItem {
        const subcommands = [_]struct { name: []const u8, desc: []const u8 }{
            .{ .name = "attach", .desc = "Attach to container" },
            .{ .name = "build", .desc = "Build an image" },
            .{ .name = "commit", .desc = "Create image from container" },
            .{ .name = "compose", .desc = "Docker Compose" },
            .{ .name = "cp", .desc = "Copy files" },
            .{ .name = "create", .desc = "Create container" },
            .{ .name = "exec", .desc = "Run command in container" },
            .{ .name = "images", .desc = "List images" },
            .{ .name = "info", .desc = "System info" },
            .{ .name = "inspect", .desc = "Return low-level info" },
            .{ .name = "kill", .desc = "Kill container" },
            .{ .name = "logs", .desc = "Fetch logs" },
            .{ .name = "network", .desc = "Manage networks" },
            .{ .name = "ps", .desc = "List containers" },
            .{ .name = "pull", .desc = "Pull image" },
            .{ .name = "push", .desc = "Push image" },
            .{ .name = "restart", .desc = "Restart container" },
            .{ .name = "rm", .desc = "Remove container" },
            .{ .name = "rmi", .desc = "Remove image" },
            .{ .name = "run", .desc = "Run a container" },
            .{ .name = "start", .desc = "Start container" },
            .{ .name = "stats", .desc = "Container stats" },
            .{ .name = "stop", .desc = "Stop container" },
            .{ .name = "system", .desc = "Manage Docker" },
            .{ .name = "tag", .desc = "Tag an image" },
            .{ .name = "top", .desc = "Display processes" },
            .{ .name = "volume", .desc = "Manage volumes" },
        };

        var items_buf: [32]CompletionItem = undefined;
        var count: usize = 0;

        for (subcommands) |cmd| {
            if (std.mem.startsWith(u8, cmd.name, prefix)) {
                if (count >= items_buf.len) break;
                items_buf[count] = .{
                    .text = try self.allocator.dupe(u8, cmd.name),
                    .description = cmd.desc,
                    .kind = .command,
                };
                count += 1;
            }
        }

        const items = try self.allocator.alloc(CompletionItem, count);
        @memcpy(items, items_buf[0..count]);
        return items;
    }

    // ========================================================================
    // Environment Variable Completions
    // ========================================================================

    pub fn completeEnvVars(self: *ContextCompletion, prefix: []const u8) ![]CompletionItem {
        var items_buf: [128]CompletionItem = undefined;
        var count: usize = 0;

        // Common environment variables
        const common_vars = [_]struct { name: []const u8, desc: []const u8 }{
            .{ .name = "HOME", .desc = "Home directory" },
            .{ .name = "PATH", .desc = "Command search path" },
            .{ .name = "USER", .desc = "Current user" },
            .{ .name = "SHELL", .desc = "Current shell" },
            .{ .name = "PWD", .desc = "Current directory" },
            .{ .name = "OLDPWD", .desc = "Previous directory" },
            .{ .name = "TERM", .desc = "Terminal type" },
            .{ .name = "EDITOR", .desc = "Default editor" },
            .{ .name = "VISUAL", .desc = "Visual editor" },
            .{ .name = "LANG", .desc = "Language setting" },
            .{ .name = "LC_ALL", .desc = "Locale override" },
            .{ .name = "DISPLAY", .desc = "X display" },
            .{ .name = "SSH_AUTH_SOCK", .desc = "SSH agent socket" },
            .{ .name = "HOSTNAME", .desc = "Machine hostname" },
            .{ .name = "LOGNAME", .desc = "Login name" },
            .{ .name = "UID", .desc = "User ID" },
            .{ .name = "GID", .desc = "Group ID" },
            .{ .name = "TMPDIR", .desc = "Temp directory" },
            .{ .name = "XDG_CONFIG_HOME", .desc = "Config directory" },
            .{ .name = "XDG_DATA_HOME", .desc = "Data directory" },
            .{ .name = "XDG_CACHE_HOME", .desc = "Cache directory" },
        };

        for (common_vars) |v| {
            if (std.mem.startsWith(u8, v.name, prefix)) {
                if (count >= items_buf.len) break;
                items_buf[count] = .{
                    .text = try self.allocator.dupe(u8, v.name),
                    .description = v.desc,
                    .kind = .env_variable,
                };
                count += 1;
            }
        }

        const items = try self.allocator.alloc(CompletionItem, count);
        @memcpy(items, items_buf[0..count]);
        return items;
    }

    // ========================================================================
    // Option/Flag Completions
    // ========================================================================

    /// Type for option definitions used by completion
    const OptionDef = struct { name: []const u8, desc: []const u8 };

    pub fn completeOptions(self: *ContextCompletion, command: []const u8, prefix: []const u8) ![]CompletionItem {
        var items_buf: [32]CompletionItem = undefined;
        var count: usize = 0;

        // Get the appropriate options array based on command
        const options: []const OptionDef = if (std.mem.eql(u8, command, "ls"))
            &ls_options
        else if (std.mem.eql(u8, command, "grep"))
            &grep_options
        else if (std.mem.eql(u8, command, "find"))
            &find_options
        else if (std.mem.eql(u8, command, "curl"))
            &curl_options
        else
            return &[_]CompletionItem{};

        for (options) |opt| {
            if (std.mem.startsWith(u8, opt.name, prefix)) {
                if (count >= items_buf.len) break;
                items_buf[count] = .{
                    .text = try self.allocator.dupe(u8, opt.name),
                    .description = opt.desc,
                    .kind = .option_flag,
                };
                count += 1;
            }
        }

        const items = try self.allocator.alloc(CompletionItem, count);
        @memcpy(items, items_buf[0..count]);
        return items;
    }

    const ls_options = [_]OptionDef{
        .{ .name = "-a", .desc = "Include hidden files" },
        .{ .name = "-l", .desc = "Long format" },
        .{ .name = "-h", .desc = "Human readable sizes" },
        .{ .name = "-R", .desc = "Recursive listing" },
        .{ .name = "-t", .desc = "Sort by time" },
        .{ .name = "-S", .desc = "Sort by size" },
        .{ .name = "-r", .desc = "Reverse order" },
        .{ .name = "-1", .desc = "One file per line" },
        .{ .name = "--color", .desc = "Colorized output" },
        .{ .name = "--all", .desc = "Include hidden files" },
        .{ .name = "--human-readable", .desc = "Human readable sizes" },
    };

    const grep_options = [_]OptionDef{
        .{ .name = "-i", .desc = "Case insensitive" },
        .{ .name = "-r", .desc = "Recursive search" },
        .{ .name = "-n", .desc = "Show line numbers" },
        .{ .name = "-v", .desc = "Invert match" },
        .{ .name = "-c", .desc = "Count matches" },
        .{ .name = "-l", .desc = "List files only" },
        .{ .name = "-E", .desc = "Extended regex" },
        .{ .name = "-o", .desc = "Show only matching" },
        .{ .name = "--color", .desc = "Colorized output" },
        .{ .name = "--include", .desc = "Include pattern" },
        .{ .name = "--exclude", .desc = "Exclude pattern" },
    };

    const find_options = [_]OptionDef{
        .{ .name = "-name", .desc = "Name pattern" },
        .{ .name = "-type", .desc = "File type" },
        .{ .name = "-size", .desc = "File size" },
        .{ .name = "-mtime", .desc = "Modified time" },
        .{ .name = "-exec", .desc = "Execute command" },
        .{ .name = "-print", .desc = "Print path" },
        .{ .name = "-delete", .desc = "Delete files" },
        .{ .name = "-maxdepth", .desc = "Max depth" },
        .{ .name = "-mindepth", .desc = "Min depth" },
    };

    const curl_options = [_]OptionDef{
        .{ .name = "-X", .desc = "HTTP method" },
        .{ .name = "-H", .desc = "Header" },
        .{ .name = "-d", .desc = "Data" },
        .{ .name = "-o", .desc = "Output file" },
        .{ .name = "-O", .desc = "Save as remote name" },
        .{ .name = "-L", .desc = "Follow redirects" },
        .{ .name = "-s", .desc = "Silent mode" },
        .{ .name = "-v", .desc = "Verbose" },
        .{ .name = "-i", .desc = "Include headers" },
        .{ .name = "--json", .desc = "JSON content type" },
    };

    // ========================================================================
    // Helper Functions
    // ========================================================================

    fn runCommand(self: *ContextCompletion, args: []const []const u8) ![]const u8 {
        var child = std.process.Child.init(args, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        const stdout = child.stdout orelse return error.NoStdout;

        // Read output using loop instead of reader API
        var output_buf = std.ArrayList(u8).empty;
        errdefer output_buf.deinit(self.allocator);

        var read_buf: [4096]u8 = undefined;
        while (true) {
            const bytes_read = stdout.read(&read_buf) catch break;
            if (bytes_read == 0) break;
            try output_buf.appendSlice(self.allocator, read_buf[0..bytes_read]);
        }

        _ = child.wait() catch {};

        return try output_buf.toOwnedSlice(self.allocator);
    }
};

/// Completion item with description and kind
pub const CompletionItem = struct {
    text: []const u8,
    description: []const u8,
    kind: CompletionKind,
};

pub const CompletionKind = enum {
    command,
    file,
    directory,
    git_branch,
    git_remote,
    git_tag,
    git_file,
    npm_script,
    docker_container,
    docker_image,
    env_variable,
    option_flag,
};

// Tests
test "ContextCompletion: parse git branch context" {
    const allocator = std.testing.allocator;
    var completer = ContextCompletion.init(allocator);

    const context = completer.parseContext("git checkout ma", 15);
    try std.testing.expect(context.kind == .git_branch);
    try std.testing.expectEqualStrings("ma", context.prefix);
}

test "ContextCompletion: parse git subcommand context" {
    const allocator = std.testing.allocator;
    var completer = ContextCompletion.init(allocator);

    const context = completer.parseContext("git co", 6);
    try std.testing.expect(context.kind == .git_subcommand);
    try std.testing.expectEqualStrings("co", context.prefix);
}

test "ContextCompletion: parse npm run context" {
    const allocator = std.testing.allocator;
    var completer = ContextCompletion.init(allocator);

    const context = completer.parseContext("npm run te", 10);
    try std.testing.expect(context.kind == .npm_script);
    try std.testing.expectEqualStrings("te", context.prefix);
}

test "ContextCompletion: parse docker container context" {
    const allocator = std.testing.allocator;
    var completer = ContextCompletion.init(allocator);

    const context = completer.parseContext("docker stop web", 15);
    try std.testing.expect(context.kind == .docker_container);
    try std.testing.expectEqualStrings("web", context.prefix);
}

test "ContextCompletion: parse env variable context" {
    const allocator = std.testing.allocator;
    var completer = ContextCompletion.init(allocator);

    const context = completer.parseContext("echo $HO", 8);
    try std.testing.expect(context.kind == .environment_variable);
    try std.testing.expectEqualStrings("HO", context.prefix);
}

test "ContextCompletion: parse option context" {
    const allocator = std.testing.allocator;
    var completer = ContextCompletion.init(allocator);

    const context = completer.parseContext("ls -l", 5);
    try std.testing.expect(context.kind == .option_flag);
    try std.testing.expectEqualStrings("-l", context.prefix);
}
