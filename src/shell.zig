const std = @import("std");
const types = @import("types/mod.zig");
const parser_mod = @import("parser/mod.zig");
const executor_mod = @import("executor/mod.zig");
const IO = @import("utils/io.zig").IO;
const Expansion = @import("utils/expansion.zig").Expansion;
const Glob = @import("utils/glob.zig").Glob;
const Completion = @import("utils/completion.zig").Completion;

/// Job status
const JobStatus = enum {
    running,
    stopped,
    done,
};

/// Background job information
const BackgroundJob = struct {
    pid: std.posix.pid_t,
    job_id: usize,
    command: []const u8,
    status: JobStatus,
};

pub const Shell = struct {
    allocator: std.mem.Allocator,
    running: bool,
    config: types.DenConfig,
    environment: std.StringHashMap([]const u8),
    aliases: std.StringHashMap([]const u8),
    last_exit_code: i32,
    background_jobs: [16]?BackgroundJob,
    background_jobs_count: usize,
    next_job_id: usize,
    history: [1000]?[]const u8,
    history_count: usize,
    history_file_path: []const u8,

    pub fn init(allocator: std.mem.Allocator) !Shell {
        const config = types.DenConfig{};

        // Initialize environment from system
        var env = std.StringHashMap([]const u8).init(allocator);

        // Add some basic environment variables
        const home = std.posix.getenv("HOME") orelse "/";
        try env.put("HOME", try allocator.dupe(u8, home));

        const path = std.posix.getenv("PATH") orelse "/usr/bin:/bin";
        try env.put("PATH", try allocator.dupe(u8, path));

        // Build history file path: ~/.den_history
        var history_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const history_path = try std.fmt.bufPrint(&history_path_buf, "{s}/.den_history", .{home});
        const history_path_owned = try allocator.dupe(u8, history_path);

        var shell = Shell{
            .allocator = allocator,
            .running = false,
            .config = config,
            .environment = env,
            .aliases = std.StringHashMap([]const u8).init(allocator),
            .last_exit_code = 0,
            .background_jobs = [_]?BackgroundJob{null} ** 16,
            .background_jobs_count = 0,
            .next_job_id = 1,
            .history = [_]?[]const u8{null} ** 1000,
            .history_count = 0,
            .history_file_path = history_path_owned,
        };

        // Load history from file
        shell.loadHistory() catch {
            // Ignore errors loading history (file might not exist yet)
        };

        return shell;
    }

    pub fn deinit(self: *Shell) void {
        // Save history before cleanup
        self.saveHistory() catch {
            // Ignore errors saving history
        };

        // Clean up background jobs
        for (self.background_jobs) |maybe_job| {
            if (maybe_job) |job| {
                self.allocator.free(job.command);
            }
        }

        // Clean up history
        for (self.history) |maybe_entry| {
            if (maybe_entry) |entry| {
                self.allocator.free(entry);
            }
        }
        self.allocator.free(self.history_file_path);

        self.environment.deinit();
        self.aliases.deinit();
    }

    pub fn run(self: *Shell) !void {
        self.running = true;

        try IO.print("Den shell initialized!\n", .{});
        try IO.print("Type 'exit' to quit or Ctrl+D to exit.\n\n", .{});

        while (self.running) {
            // Check for completed background jobs
            try self.checkBackgroundJobs();

            // Render prompt
            try self.renderPrompt();

            // Read line from stdin
            const line = try IO.readLine(self.allocator);

            if (line == null) {
                // EOF (Ctrl+D)
                try IO.print("\nGoodbye from Den!\n", .{});
                break;
            }

            defer self.allocator.free(line.?);

            const trimmed = std.mem.trim(u8, line.?, &std.ascii.whitespace);

            if (trimmed.len == 0) continue;

            // Add to history (before execution)
            try self.addToHistory(trimmed);

            // Handle exit command
            if (std.mem.eql(u8, trimmed, "exit")) {
                self.running = false;
                try IO.print("Goodbye from Den!\n", .{});
                break;
            }

            // Execute command
            try self.executeCommand(trimmed);
        }
    }

    fn renderPrompt(self: *Shell) !void {
        _ = self;
        try IO.print("den> ", .{});
    }

    fn executeCommand(self: *Shell, input: []const u8) !void {
        // Tokenize
        var tokenizer = parser_mod.Tokenizer.init(self.allocator, input);
        const tokens = tokenizer.tokenize() catch |err| {
            try IO.eprint("den: parse error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };
        defer self.allocator.free(tokens);

        if (tokens.len == 0) return;

        // Parse
        var parser = parser_mod.Parser.init(self.allocator, tokens);
        var chain = parser.parse() catch |err| {
            try IO.eprint("den: parse error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };
        defer chain.deinit(self.allocator);

        // Expand variables in all commands
        try self.expandCommandChain(&chain);

        // Expand aliases in command names
        try self.expandAliases(&chain);

        // Check for shell-context builtins (jobs, history, etc.)
        if (chain.commands.len == 1 and chain.operators.len == 0) {
            const cmd = &chain.commands[0];
            if (std.mem.eql(u8, cmd.name, "jobs")) {
                try self.builtinJobs();
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "fg")) {
                try self.builtinFg(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "bg")) {
                try self.builtinBg(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "history")) {
                try self.builtinHistory(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "complete")) {
                try self.builtinComplete(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "alias")) {
                try self.builtinAlias(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "unalias")) {
                try self.builtinUnalias(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "type")) {
                try self.builtinType(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "which")) {
                try self.builtinWhich(cmd);
                self.last_exit_code = 0;
                return;
            }
        }

        // Check if this is a background job (last operator is &)
        const is_background = chain.operators.len > 0 and
            chain.operators[chain.operators.len - 1] == .background;

        if (is_background) {
            // Execute in background
            try self.executeInBackground(&chain, input);
            self.last_exit_code = 0;
        } else {
            // Execute normally
            var executor = executor_mod.Executor.init(self.allocator, &self.environment);
            const exit_code = executor.executeChain(&chain) catch |err| {
                try IO.eprint("den: execution error: {}\n", .{err});
                self.last_exit_code = 1;
                return;
            };

            self.last_exit_code = exit_code;
        }
    }

    fn executeInBackground(self: *Shell, chain: *types.CommandChain, original_input: []const u8) !void {
        // Fork the process
        const pid = try std.posix.fork();

        if (pid == 0) {
            // Child process - execute the chain
            var executor = executor_mod.Executor.init(self.allocator, &self.environment);
            const exit_code = executor.executeChain(chain) catch 1;
            std.posix.exit(@intCast(exit_code));
        } else {
            // Parent process - add to background jobs
            try self.addBackgroundJob(pid, original_input);
        }
    }

    fn expandCommandChain(self: *Shell, chain: *types.CommandChain) !void {
        var expander = Expansion.init(self.allocator, &self.environment, self.last_exit_code);
        var glob = Glob.init(self.allocator);

        // Get current working directory for glob expansion
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try std.posix.getcwd(&cwd_buf);

        for (chain.commands) |*cmd| {
            // Expand command name (variables only, no globs for command names)
            const expanded_name = try expander.expand(cmd.name);
            self.allocator.free(cmd.name);
            cmd.name = expanded_name;

            // Expand arguments (variables + globs)
            var expanded_args_buffer: [128][]const u8 = undefined;
            var expanded_args_count: usize = 0;

            for (cmd.args) |arg| {
                // First expand variables
                const var_expanded = try expander.expand(arg);
                defer self.allocator.free(var_expanded);

                // Then expand globs
                const glob_expanded = try glob.expand(var_expanded, cwd);
                defer {
                    for (glob_expanded) |path| {
                        self.allocator.free(path);
                    }
                    self.allocator.free(glob_expanded);
                }

                // Add all glob matches to args
                for (glob_expanded) |path| {
                    if (expanded_args_count >= expanded_args_buffer.len) {
                        return error.TooManyArguments;
                    }
                    expanded_args_buffer[expanded_args_count] = try self.allocator.dupe(u8, path);
                    expanded_args_count += 1;
                }

                // Free original arg
                self.allocator.free(arg);
            }

            // Replace args with expanded version
            self.allocator.free(cmd.args);
            const new_args = try self.allocator.alloc([]const u8, expanded_args_count);
            @memcpy(new_args, expanded_args_buffer[0..expanded_args_count]);
            cmd.args = new_args;

            // Expand redirection targets (variables only, no globs)
            for (cmd.redirections, 0..) |*redir, i| {
                const expanded_target = try expander.expand(redir.target);
                self.allocator.free(cmd.redirections[i].target);
                cmd.redirections[i].target = expanded_target;
            }
        }
    }

    fn checkBackgroundJobs(self: *Shell) !void {
        var i: usize = 0;
        while (i < self.background_jobs.len) {
            if (self.background_jobs[i]) |job| {
                // Check if job has completed (non-blocking waitpid)
                const result = std.posix.waitpid(job.pid, std.posix.W.NOHANG);

                if (result.pid == job.pid) {
                    // Job completed
                    const exit_status = std.posix.W.EXITSTATUS(result.status);
                    try IO.print("[{d}]  Done ({d})    {s}\n", .{ job.job_id, exit_status, job.command });

                    // Free command string and remove from array
                    self.allocator.free(job.command);
                    self.background_jobs[i] = null;
                    self.background_jobs_count -= 1;
                    // Don't increment i, check this slot again
                } else {
                    // Job still running
                    i += 1;
                }
            } else {
                // Empty slot
                i += 1;
            }
        }
    }

    pub fn addBackgroundJob(self: *Shell, pid: std.posix.pid_t, command: []const u8) !void {
        // Find first empty slot
        var slot_index: ?usize = null;
        for (self.background_jobs, 0..) |maybe_job, i| {
            if (maybe_job == null) {
                slot_index = i;
                break;
            }
        }

        if (slot_index == null) {
            return error.TooManyBackgroundJobs;
        }

        const job_id = self.next_job_id;
        self.next_job_id += 1;

        const command_copy = try self.allocator.dupe(u8, command);

        self.background_jobs[slot_index.?] = BackgroundJob{
            .pid = pid,
            .job_id = job_id,
            .command = command_copy,
            .status = .running,
        };
        self.background_jobs_count += 1;

        try IO.print("[{d}] {d}\n", .{ job_id, pid });
    }

    /// Builtin: jobs - list background jobs
    fn builtinJobs(self: *Shell) !void {
        for (self.background_jobs) |maybe_job| {
            if (maybe_job) |job| {
                const status_str = switch (job.status) {
                    .running => "Running",
                    .stopped => "Stopped",
                    .done => "Done",
                };
                try IO.print("[{d}]  {s: <10} {s}\n", .{ job.job_id, status_str, job.command });
            }
        }
    }

    /// Builtin: fg - bring background job to foreground
    fn builtinFg(self: *Shell, cmd: *types.ParsedCommand) !void {
        // Get job ID from argument (default to most recent)
        var job_id: ?usize = null;
        if (cmd.args.len > 0) {
            job_id = std.fmt.parseInt(usize, cmd.args[0], 10) catch {
                try IO.eprint("den: fg: {s}: no such job\n", .{cmd.args[0]});
                self.last_exit_code = 1;
                return;
            };
        } else {
            // Find most recent job
            var max_id: usize = 0;
            for (self.background_jobs) |maybe_job| {
                if (maybe_job) |job| {
                    if (job.job_id > max_id) {
                        max_id = job.job_id;
                    }
                }
            }
            if (max_id > 0) {
                job_id = max_id;
            }
        }

        if (job_id == null) {
            try IO.eprint("den: fg: current: no such job\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Find job in array
        var job_slot: ?usize = null;
        for (self.background_jobs, 0..) |maybe_job, i| {
            if (maybe_job) |job| {
                if (job.job_id == job_id.?) {
                    job_slot = i;
                    break;
                }
            }
        }

        if (job_slot == null) {
            try IO.eprint("den: fg: {d}: no such job\n", .{job_id.?});
            self.last_exit_code = 1;
            return;
        }

        const job = self.background_jobs[job_slot.?].?;
        try IO.print("{s}\n", .{job.command});

        // Wait for the job to complete
        const result = std.posix.waitpid(job.pid, 0);
        const exit_status = std.posix.W.EXITSTATUS(result.status);

        // Remove from background jobs
        self.allocator.free(job.command);
        self.background_jobs[job_slot.?] = null;
        self.background_jobs_count -= 1;

        self.last_exit_code = @intCast(exit_status);
    }

    /// Builtin: bg - continue stopped job in background
    fn builtinBg(self: *Shell, cmd: *types.ParsedCommand) !void {
        // Get job ID from argument (default to most recent stopped job)
        var job_id: ?usize = null;
        if (cmd.args.len > 0) {
            job_id = std.fmt.parseInt(usize, cmd.args[0], 10) catch {
                try IO.eprint("den: bg: {s}: no such job\n", .{cmd.args[0]});
                self.last_exit_code = 1;
                return;
            };
        } else {
            // Find most recent stopped job
            var max_id: usize = 0;
            for (self.background_jobs) |maybe_job| {
                if (maybe_job) |job| {
                    if (job.status == .stopped and job.job_id > max_id) {
                        max_id = job.job_id;
                    }
                }
            }
            if (max_id > 0) {
                job_id = max_id;
            }
        }

        if (job_id == null) {
            try IO.eprint("den: bg: current: no such job\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Find job in array
        var job_slot: ?usize = null;
        for (self.background_jobs, 0..) |maybe_job, i| {
            if (maybe_job) |job| {
                if (job.job_id == job_id.?) {
                    job_slot = i;
                    break;
                }
            }
        }

        if (job_slot == null) {
            try IO.eprint("den: bg: {d}: no such job\n", .{job_id.?});
            self.last_exit_code = 1;
            return;
        }

        const job = self.background_jobs[job_slot.?].?;
        if (job.status != .stopped) {
            try IO.eprint("den: bg: job {d} already in background\n", .{job_id.?});
            self.last_exit_code = 1;
            return;
        }

        // Send SIGCONT to continue the job
        // Note: In a real implementation, we'd use kill(pid, SIGCONT)
        // For now, just mark as running
        self.background_jobs[job_slot.?].?.status = .running;
        try IO.print("[{d}]+ {s} &\n", .{ job.job_id, job.command });
        self.last_exit_code = 0;
    }

    /// Add command to history
    fn addToHistory(self: *Shell, command: []const u8) !void {
        // Don't add empty commands or duplicate of last command
        if (command.len == 0) return;

        if (self.history_count > 0) {
            if (self.history[self.history_count - 1]) |last_cmd| {
                if (std.mem.eql(u8, last_cmd, command)) {
                    return; // Skip duplicate
                }
            }
        }

        // If history is full, shift everything left
        if (self.history_count >= self.history.len) {
            // Free oldest entry
            if (self.history[0]) |oldest| {
                self.allocator.free(oldest);
            }

            // Shift all entries left
            var i: usize = 0;
            while (i < self.history.len - 1) : (i += 1) {
                self.history[i] = self.history[i + 1];
            }
            self.history[self.history.len - 1] = null;
            self.history_count -= 1;
        }

        // Add new entry
        const cmd_copy = try self.allocator.dupe(u8, command);
        self.history[self.history_count] = cmd_copy;
        self.history_count += 1;
    }

    /// Load history from file
    fn loadHistory(self: *Shell) !void {
        const file = std.fs.cwd().openFile(self.history_file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return; // File doesn't exist yet
            return err;
        };
        defer file.close();

        // Read entire file
        const max_size = 1024 * 1024; // 1MB max
        const content = try file.readToEndAlloc(self.allocator, max_size);
        defer self.allocator.free(content);

        // Split by newlines and add to history
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len > 0 and self.history_count < self.history.len) {
                const cmd_copy = try self.allocator.dupe(u8, trimmed);
                self.history[self.history_count] = cmd_copy;
                self.history_count += 1;
            }
        }
    }

    /// Save history to file
    fn saveHistory(self: *Shell) !void {
        const file = try std.fs.cwd().createFile(self.history_file_path, .{});
        defer file.close();

        for (self.history) |maybe_entry| {
            if (maybe_entry) |entry| {
                _ = try file.writeAll(entry);
                _ = try file.write("\n");
            }
        }
    }

    /// Builtin: history - show command history
    fn builtinHistory(self: *Shell, cmd: *types.ParsedCommand) !void {
        // Parse optional argument for number of entries to show
        var num_entries: usize = self.history_count;
        if (cmd.args.len > 0) {
            num_entries = std.fmt.parseInt(usize, cmd.args[0], 10) catch {
                try IO.eprint("den: history: {s}: numeric argument required\n", .{cmd.args[0]});
                return;
            };
            if (num_entries > self.history_count) {
                num_entries = self.history_count;
            }
        }

        // Calculate starting index
        const start_idx = if (num_entries >= self.history_count) 0 else self.history_count - num_entries;

        // Print history with line numbers
        var idx = start_idx;
        while (idx < self.history_count) : (idx += 1) {
            if (self.history[idx]) |entry| {
                try IO.print("{d:5}  {s}\n", .{ idx + 1, entry });
            }
        }
    }

    /// Builtin: complete - show completions for a prefix
    fn builtinComplete(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: complete: usage: complete [-c|-f] <prefix>\n", .{});
            return;
        }

        var completion = Completion.init(self.allocator);
        var prefix: []const u8 = undefined;
        var is_command = false;
        var is_file = false;

        // Parse flags
        var arg_idx: usize = 0;
        if (cmd.args.len >= 2) {
            if (std.mem.eql(u8, cmd.args[0], "-c")) {
                is_command = true;
                prefix = cmd.args[1];
                arg_idx = 2;
            } else if (std.mem.eql(u8, cmd.args[0], "-f")) {
                is_file = true;
                prefix = cmd.args[1];
                arg_idx = 2;
            } else {
                prefix = cmd.args[0];
            }
        } else {
            prefix = cmd.args[0];
        }

        // If no flag specified, try both
        if (!is_command and !is_file) {
            // Try command completion first
            const cmd_matches = try completion.completeCommand(prefix);
            defer {
                for (cmd_matches) |match| {
                    self.allocator.free(match);
                }
                self.allocator.free(cmd_matches);
            }

            if (cmd_matches.len > 0) {
                try IO.print("Commands:\n", .{});
                for (cmd_matches) |match| {
                    try IO.print("  {s}\n", .{match});
                }
            }

            // Try file completion
            const file_matches = try completion.completeFile(prefix);
            defer {
                for (file_matches) |match| {
                    self.allocator.free(match);
                }
                self.allocator.free(file_matches);
            }

            if (file_matches.len > 0) {
                if (cmd_matches.len > 0) {
                    try IO.print("\n", .{});
                }
                try IO.print("Files:\n", .{});
                for (file_matches) |match| {
                    try IO.print("  {s}\n", .{match});
                }
            }

            if (cmd_matches.len == 0 and file_matches.len == 0) {
                try IO.print("No completions found.\n", .{});
            }
        } else if (is_command) {
            const matches = try completion.completeCommand(prefix);
            defer {
                for (matches) |match| {
                    self.allocator.free(match);
                }
                self.allocator.free(matches);
            }

            if (matches.len == 0) {
                try IO.print("No command completions found.\n", .{});
            } else {
                for (matches) |match| {
                    try IO.print("{s}\n", .{match});
                }
            }
        } else if (is_file) {
            const matches = try completion.completeFile(prefix);
            defer {
                for (matches) |match| {
                    self.allocator.free(match);
                }
                self.allocator.free(matches);
            }

            if (matches.len == 0) {
                try IO.print("No file completions found.\n", .{});
            } else {
                for (matches) |match| {
                    try IO.print("{s}\n", .{match});
                }
            }
        }
    }

    /// Expand aliases in command chain
    fn expandAliases(self: *Shell, chain: *types.CommandChain) !void {
        for (chain.commands) |*cmd| {
            if (self.aliases.get(cmd.name)) |alias_value| {
                // Replace command name with alias value
                const expanded = try self.allocator.dupe(u8, alias_value);
                self.allocator.free(cmd.name);
                cmd.name = expanded;
            }
        }
    }

    /// Builtin: alias - define or list aliases
    fn builtinAlias(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            // List all aliases
            var iter = self.aliases.iterator();
            while (iter.next()) |entry| {
                try IO.print("alias {s}='{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        } else {
            // Parse alias definition: name=value
            for (cmd.args) |arg| {
                if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                    const name = arg[0..eq_pos];
                    const value = arg[eq_pos + 1 ..];

                    // Remove quotes if present
                    const clean_value = if (value.len >= 2 and
                        ((value[0] == '\'' and value[value.len - 1] == '\'') or
                        (value[0] == '"' and value[value.len - 1] == '"')))
                        value[1 .. value.len - 1]
                    else
                        value;

                    // Store alias
                    const name_copy = try self.allocator.dupe(u8, name);
                    const value_copy = try self.allocator.dupe(u8, clean_value);

                    // Free old value if exists
                    if (self.aliases.get(name)) |old_value| {
                        self.allocator.free(old_value);
                    }

                    try self.aliases.put(name_copy, value_copy);
                } else {
                    // Show specific alias
                    if (self.aliases.get(arg)) |value| {
                        try IO.print("alias {s}='{s}'\n", .{ arg, value });
                    } else {
                        try IO.eprint("den: alias: {s}: not found\n", .{arg});
                    }
                }
            }
        }
    }

    /// Builtin: unalias - remove alias
    fn builtinUnalias(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: unalias: usage: unalias name [name ...]\n", .{});
            return;
        }

        for (cmd.args) |name| {
            if (self.aliases.fetchRemove(name)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            } else {
                try IO.eprint("den: unalias: {s}: not found\n", .{name});
            }
        }
    }

    /// Builtin: type - identify command type
    fn builtinType(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: type: usage: type name [name ...]\n", .{});
            return;
        }

        const builtins = [_][]const u8{
            "cd",      "pwd",      "echo",    "exit",  "env",
            "export",  "set",      "unset",   "jobs",  "fg",
            "bg",      "history",  "complete", "alias", "unalias",
            "type",    "which",
        };

        for (cmd.args) |name| {
            // Check if it's an alias
            if (self.aliases.get(name)) |alias_value| {
                try IO.print("{s} is aliased to `{s}'\n", .{ name, alias_value });
                continue;
            }

            // Check if it's a builtin
            var is_builtin = false;
            for (builtins) |builtin| {
                if (std.mem.eql(u8, name, builtin)) {
                    try IO.print("{s} is a shell builtin\n", .{name});
                    is_builtin = true;
                    break;
                }
            }
            if (is_builtin) continue;

            // Check if it's in PATH
            var completion = Completion.init(self.allocator);
            const matches = try completion.completeCommand(name);
            defer {
                for (matches) |match| {
                    self.allocator.free(match);
                }
                self.allocator.free(matches);
            }

            if (matches.len > 0) {
                // Find exact match
                for (matches) |match| {
                    if (std.mem.eql(u8, match, name)) {
                        // Find full path
                        const path = std.posix.getenv("PATH") orelse "";
                        var path_iter = std.mem.splitScalar(u8, path, ':');
                        while (path_iter.next()) |dir_path| {
                            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;

                            // Check if file exists
                            std.fs.cwd().access(full_path, .{}) catch continue;
                            try IO.print("{s} is {s}\n", .{ name, full_path });
                            break;
                        }
                        break;
                    }
                }
            } else {
                try IO.eprint("den: type: {s}: not found\n", .{name});
            }
        }
    }

    /// Builtin: which - locate command in PATH
    fn builtinWhich(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = self;
        if (cmd.args.len == 0) {
            try IO.eprint("den: which: usage: which name [name ...]\n", .{});
            return;
        }

        for (cmd.args) |name| {
            const path = std.posix.getenv("PATH") orelse "";
            var path_iter = std.mem.splitScalar(u8, path, ':');
            var found = false;

            while (path_iter.next()) |dir_path| {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;

                // Check if file exists and is executable
                const stat = std.fs.cwd().statFile(full_path) catch continue;
                const is_executable = (stat.mode & 0o111) != 0;

                if (is_executable) {
                    try IO.print("{s}\n", .{full_path});
                    found = true;
                    break;
                }
            }

            if (!found) {
                try IO.eprint("den: which: {s}: not found\n", .{name});
            }
        }
    }
};


test "shell initialization" {
    const allocator = std.testing.allocator;
    var sh = try Shell.init(allocator);
    defer sh.deinit();

    try std.testing.expect(!sh.running);
}
