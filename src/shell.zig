const std = @import("std");
const types = @import("types/mod.zig");
const parser_mod = @import("parser/mod.zig");
const executor_mod = @import("executor/mod.zig");
const IO = @import("utils/io.zig").IO;
const Expansion = @import("utils/expansion.zig").Expansion;
const Glob = @import("utils/glob.zig").Glob;

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

    pub fn init(allocator: std.mem.Allocator) !Shell {
        const config = types.DenConfig{};

        // Initialize environment from system
        var env = std.StringHashMap([]const u8).init(allocator);

        // Add some basic environment variables
        const home = std.posix.getenv("HOME") orelse "/";
        try env.put("HOME", try allocator.dupe(u8, home));

        const path = std.posix.getenv("PATH") orelse "/usr/bin:/bin";
        try env.put("PATH", try allocator.dupe(u8, path));

        return Shell{
            .allocator = allocator,
            .running = false,
            .config = config,
            .environment = env,
            .aliases = std.StringHashMap([]const u8).init(allocator),
            .last_exit_code = 0,
            .background_jobs = [_]?BackgroundJob{null} ** 16,
            .background_jobs_count = 0,
            .next_job_id = 1,
        };
    }

    pub fn deinit(self: *Shell) void {
        // Clean up background jobs
        for (self.background_jobs) |maybe_job| {
            if (maybe_job) |job| {
                self.allocator.free(job.command);
            }
        }

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

        // Check for job control builtins (need shell context)
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
};


test "shell initialization" {
    const allocator = std.testing.allocator;
    var sh = try Shell.init(allocator);
    defer sh.deinit();

    try std.testing.expect(!sh.running);
}
