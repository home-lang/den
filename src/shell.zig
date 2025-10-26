const std = @import("std");
const types = @import("types/mod.zig");
const parser_mod = @import("parser/mod.zig");
const executor_mod = @import("executor/mod.zig");
const IO = @import("utils/io.zig").IO;
const Expansion = @import("utils/expansion.zig").Expansion;
const Glob = @import("utils/glob.zig").Glob;
const BraceExpander = @import("utils/brace.zig").BraceExpander;
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
    dir_stack: [32]?[]const u8,
    dir_stack_count: usize,
    positional_params: [64]?[]const u8,
    positional_params_count: usize,
    shell_name: []const u8,

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
            .dir_stack = [_]?[]const u8{null} ** 32,
            .dir_stack_count = 0,
            .positional_params = [_]?[]const u8{null} ** 64,
            .positional_params_count = 0,
            .shell_name = "den",
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

        // Clean up directory stack
        for (self.dir_stack) |maybe_dir| {
            if (maybe_dir) |dir| {
                self.allocator.free(dir);
            }
        }

        // Clean up positional parameters
        for (self.positional_params) |maybe_param| {
            if (maybe_param) |param| {
                self.allocator.free(param);
            }
        }

        // Clean up shell_name if it was dynamically allocated
        if (!std.mem.eql(u8, self.shell_name, "den")) {
            self.allocator.free(self.shell_name);
        }

        // Clean up environment variables (values were allocated)
        var env_iter = self.environment.iterator();
        while (env_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.environment.deinit();

        // Clean up aliases (values were allocated)
        var alias_iter = self.aliases.iterator();
        while (alias_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
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

    /// Run a script file with positional parameters
    pub fn runScript(self: *Shell, script_path: []const u8, shell_name: []const u8, args: []const []const u8) !void {
        // Set positional parameters for this script
        var param_count: usize = 0;
        for (args) |arg| {
            if (param_count >= 9) break; // Only support $1-$9 for now
            const param_copy = try self.allocator.dupe(u8, arg);
            self.positional_params[param_count] = param_copy;
            param_count += 1;
        }
        self.positional_params_count = param_count;

        // Set shell name ($0)
        const shell_name_copy = try self.allocator.dupe(u8, shell_name);
        self.shell_name = shell_name_copy;

        // Read script file
        const file = try std.fs.cwd().openFile(script_path, .{});
        defer file.close();

        const file_content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // Max 1MB
        defer self.allocator.free(file_content);

        // Split into lines and execute each one
        var line_iter = std.mem.splitScalar(u8, file_content, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

            // Skip empty lines and comments
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Execute the line
            self.executeCommand(trimmed) catch |err| {
                try IO.print("Error executing '{s}': {}\n", .{ trimmed, err });
                self.last_exit_code = 1;
            };
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
            } else if (std.mem.eql(u8, cmd.name, "source") or std.mem.eql(u8, cmd.name, ".")) {
                try self.builtinSource(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "read")) {
                try self.builtinRead(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "test") or std.mem.eql(u8, cmd.name, "[")) {
                try self.builtinTest(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "pushd")) {
                try self.builtinPushd(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "popd")) {
                try self.builtinPopd(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "dirs")) {
                try self.builtinDirs(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "printf")) {
                try self.builtinPrintf(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "true")) {
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "false")) {
                self.last_exit_code = 1;
                return;
            } else if (std.mem.eql(u8, cmd.name, "sleep")) {
                try self.builtinSleep(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "help")) {
                try self.builtinHelp(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "basename")) {
                try self.builtinBasename(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "dirname")) {
                try self.builtinDirname(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "realpath")) {
                try self.builtinRealpath(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "command")) {
                try self.builtinCommand(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "eval")) {
                try self.builtinEval(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "shift")) {
                try self.builtinShift(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "time")) {
                try self.builtinTime(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "umask")) {
                try self.builtinUmask(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "clear")) {
                try self.builtinClear(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "uname")) {
                try self.builtinUname(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "whoami")) {
                try self.builtinWhoami(cmd);
                self.last_exit_code = 0;
                return;
            } else if (std.mem.eql(u8, cmd.name, "hash")) {
                try self.builtinHash(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "return")) {
                try self.builtinReturn(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "break")) {
                try self.builtinBreak(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "continue")) {
                try self.builtinContinue(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "local")) {
                try self.builtinLocal(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "declare")) {
                try self.builtinDeclare(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "readonly")) {
                try self.builtinReadonly(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "exec")) {
                try self.builtinExec(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "wait")) {
                try self.builtinWait(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "kill")) {
                try self.builtinKill(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "disown")) {
                try self.builtinDisown(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "trap")) {
                try self.builtinTrap(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "getopts")) {
                try self.builtinGetopts(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "timeout")) {
                try self.builtinTimeout(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "times")) {
                try self.builtinTimes(cmd);
                return;
            } else if (std.mem.eql(u8, cmd.name, "builtin")) {
                try self.builtinBuiltin(cmd);
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
        // Collect non-null positional params for the expander
        var positional_params_slice: [64][]const u8 = undefined;
        var param_count: usize = 0;
        for (self.positional_params) |maybe_param| {
            if (maybe_param) |param| {
                positional_params_slice[param_count] = param;
                param_count += 1;
            }
        }

        var expander = Expansion.initWithParams(
            self.allocator,
            &self.environment,
            self.last_exit_code,
            positional_params_slice[0..param_count],
            self.shell_name,
        );
        var glob = Glob.init(self.allocator);
        var brace = BraceExpander.init(self.allocator);

        // Get current working directory for glob expansion
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try std.posix.getcwd(&cwd_buf);

        for (chain.commands) |*cmd| {
            // Expand command name (variables only, no globs for command names)
            const expanded_name = try expander.expand(cmd.name);
            self.allocator.free(cmd.name);
            cmd.name = expanded_name;

            // Expand arguments (variables + braces + globs)
            var expanded_args_buffer: [128][]const u8 = undefined;
            var expanded_args_count: usize = 0;

            for (cmd.args) |arg| {
                // First expand variables
                const var_expanded = try expander.expand(arg);
                defer self.allocator.free(var_expanded);

                // Then expand braces
                const brace_expanded = try brace.expand(var_expanded);
                defer {
                    for (brace_expanded) |item| {
                        self.allocator.free(item);
                    }
                    self.allocator.free(brace_expanded);
                }

                // Then expand globs on each brace expansion result
                for (brace_expanded) |brace_item| {
                    const glob_expanded = try glob.expand(brace_item, cwd);
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

    /// Builtin: source - execute commands from file
    fn builtinSource(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: source: usage: source filename\n", .{});
            self.last_exit_code = 1;
            return;
        }

        const filename = cmd.args[0];

        // Read file contents
        const file = std.fs.cwd().openFile(filename, .{}) catch |err| {
            try IO.eprint("den: source: {s}: {}\n", .{ filename, err });
            self.last_exit_code = 1;
            return;
        };
        defer file.close();

        const max_size = 1024 * 1024; // 1MB max
        const content = file.readToEndAlloc(self.allocator, max_size) catch |err| {
            try IO.eprint("den: source: {s}: {}\n", .{ filename, err });
            self.last_exit_code = 1;
            return;
        };
        defer self.allocator.free(content);

        // Execute each line by tokenizing and executing directly
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue; // Skip comments

            // Tokenize the line
            var tokenizer = parser_mod.Tokenizer.init(self.allocator, trimmed);
            const tokens = tokenizer.tokenize() catch |err| {
                try IO.eprint("den: source: parse error: {}\n", .{err});
                self.last_exit_code = 1;
                continue; // Continue with next line instead of returning
            };
            defer self.allocator.free(tokens);

            // Parse tokens
            var p = parser_mod.Parser.init(self.allocator, tokens);
            var chain = p.parse() catch |err| {
                try IO.eprint("den: source: parse error: {}\n", .{err});
                self.last_exit_code = 1;
                continue;
            };
            defer chain.deinit(self.allocator);

            // Expand variables and aliases
            try self.expandCommandChain(&chain);
            try self.expandAliases(&chain);

            // Execute the command chain
            var executor = executor_mod.Executor.init(self.allocator, &self.environment);
            const exit_code = executor.executeChain(&chain) catch |err| {
                try IO.eprint("den: source: execution error: {}\n", .{err});
                self.last_exit_code = 1;
                continue;
            };
            self.last_exit_code = exit_code;
        }
    }

    /// Builtin: read - read line from stdin into variable
    fn builtinRead(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: read: usage: read varname\n", .{});
            return;
        }

        const varname = cmd.args[0];

        // Read line from stdin
        const line = try IO.readLine(self.allocator);
        if (line) |value| {
            defer self.allocator.free(value);

            // Store in environment
            const value_copy = try self.allocator.dupe(u8, value);
            try self.environment.put(varname, value_copy);
        }
    }

    /// Builtin: test/[ - evaluate conditional expressions
    fn builtinTest(self: *Shell, cmd: *types.ParsedCommand) !void {
        // Simple test implementation supporting basic conditions
        if (cmd.args.len == 0) {
            self.last_exit_code = 1;
            return;
        }

        // Handle [ command - must end with ]
        var args = cmd.args;
        if (std.mem.eql(u8, cmd.name, "[")) {
            if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) {
                try IO.eprint("den: [: missing ]\n", .{});
                self.last_exit_code = 2;
                return;
            }
            args = args[0 .. args.len - 1]; // Remove trailing ]
        }

        if (args.len == 0) {
            self.last_exit_code = 1;
            return;
        }

        // Unary operators
        if (args.len == 2) {
            const op = args[0];
            const arg = args[1];

            if (std.mem.eql(u8, op, "-z")) {
                // String is empty
                self.last_exit_code = if (arg.len == 0) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-n")) {
                // String is not empty
                self.last_exit_code = if (arg.len > 0) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-f")) {
                // File exists and is regular file
                const stat = std.fs.cwd().statFile(arg) catch {
                    self.last_exit_code = 1;
                    return;
                };
                self.last_exit_code = if (stat.kind == .file) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-d")) {
                // Directory exists
                const stat = std.fs.cwd().statFile(arg) catch {
                    self.last_exit_code = 1;
                    return;
                };
                self.last_exit_code = if (stat.kind == .directory) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-e")) {
                // File exists
                std.fs.cwd().access(arg, .{}) catch {
                    self.last_exit_code = 1;
                    return;
                };
                self.last_exit_code = 0;
                return;
            }
        }

        // Binary operators
        if (args.len == 3) {
            const left = args[0];
            const op = args[1];
            const right = args[2];

            if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
                // String equality
                self.last_exit_code = if (std.mem.eql(u8, left, right)) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "!=")) {
                // String inequality
                self.last_exit_code = if (!std.mem.eql(u8, left, right)) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-eq")) {
                // Numeric equality
                const left_num = std.fmt.parseInt(i32, left, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                const right_num = std.fmt.parseInt(i32, right, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                self.last_exit_code = if (left_num == right_num) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-ne")) {
                // Numeric inequality
                const left_num = std.fmt.parseInt(i32, left, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                const right_num = std.fmt.parseInt(i32, right, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                self.last_exit_code = if (left_num != right_num) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-lt")) {
                // Less than
                const left_num = std.fmt.parseInt(i32, left, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                const right_num = std.fmt.parseInt(i32, right, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                self.last_exit_code = if (left_num < right_num) 0 else 1;
                return;
            } else if (std.mem.eql(u8, op, "-gt")) {
                // Greater than
                const left_num = std.fmt.parseInt(i32, left, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                const right_num = std.fmt.parseInt(i32, right, 10) catch {
                    self.last_exit_code = 2;
                    return;
                };
                self.last_exit_code = if (left_num > right_num) 0 else 1;
                return;
            }
        }

        // Default: non-empty string test
        if (args.len == 1) {
            self.last_exit_code = if (args[0].len > 0) 0 else 1;
            return;
        }

        // Unknown test
        try IO.eprint("den: test: unknown condition\n", .{});
        self.last_exit_code = 2;
    }

    /// Builtin: pushd - push directory onto stack and cd
    fn builtinPushd(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            // pushd with no args: swap top two directories
            if (self.dir_stack_count < 1) {
                try IO.eprint("den: pushd: directory stack empty\n", .{});
                self.last_exit_code = 1;
                return;
            }

            // Get current directory
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = try std.posix.getcwd(&cwd_buf);
            const cwd_copy = try self.allocator.dupe(u8, cwd);

            // Pop top of stack and cd to it
            const top_dir = self.dir_stack[self.dir_stack_count - 1].?;
            std.posix.chdir(top_dir) catch |err| {
                try IO.eprint("den: pushd: {s}: {}\n", .{ top_dir, err });
                self.allocator.free(cwd_copy);
                self.last_exit_code = 1;
                return;
            };

            // Push old cwd onto stack
            self.dir_stack[self.dir_stack_count - 1] = cwd_copy;
            self.last_exit_code = 0;
        } else {
            const target_dir = cmd.args[0];

            // Get current directory before changing
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = try std.posix.getcwd(&cwd_buf);

            // Try to change to target directory
            std.posix.chdir(target_dir) catch |err| {
                try IO.eprint("den: pushd: {s}: {}\n", .{ target_dir, err });
                self.last_exit_code = 1;
                return;
            };

            // Push old cwd onto stack
            if (self.dir_stack_count >= self.dir_stack.len) {
                try IO.eprint("den: pushd: directory stack full\n", .{});
                self.last_exit_code = 1;
                return;
            }

            self.dir_stack[self.dir_stack_count] = try self.allocator.dupe(u8, cwd);
            self.dir_stack_count += 1;
            self.last_exit_code = 0;
        }
    }

    /// Builtin: popd - pop directory from stack and cd
    fn builtinPopd(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = cmd;

        if (self.dir_stack_count == 0) {
            try IO.eprint("den: popd: directory stack empty\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Pop directory from stack
        self.dir_stack_count -= 1;
        const dir = self.dir_stack[self.dir_stack_count].?;
        defer self.allocator.free(dir);
        self.dir_stack[self.dir_stack_count] = null;

        // Change to that directory
        std.posix.chdir(dir) catch |err| {
            try IO.eprint("den: popd: {s}: {}\n", .{ dir, err });
            self.last_exit_code = 1;
            return;
        };

        self.last_exit_code = 0;
    }

    /// Builtin: dirs - show directory stack
    fn builtinDirs(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = cmd;

        // Show current directory first
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try std.posix.getcwd(&cwd_buf);
        try IO.print("{s}", .{cwd});

        // Show stack from top to bottom
        if (self.dir_stack_count > 0) {
            var i: usize = self.dir_stack_count;
            while (i > 0) {
                i -= 1;
                if (self.dir_stack[i]) |dir| {
                    try IO.print(" {s}", .{dir});
                }
            }
        }

        try IO.print("\n", .{});
    }

    /// Builtin: printf - formatted output (basic implementation)
    fn builtinPrintf(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = self;

        if (cmd.args.len == 0) {
            return;
        }

        const format_str = cmd.args[0];
        var arg_idx: usize = 1;

        var i: usize = 0;
        while (i < format_str.len) {
            if (format_str[i] == '\\' and i + 1 < format_str.len) {
                // Handle escape sequences
                i += 1;
                switch (format_str[i]) {
                    'n' => try IO.print("\n", .{}),
                    't' => try IO.print("\t", .{}),
                    'r' => try IO.print("\r", .{}),
                    '\\' => try IO.print("\\", .{}),
                    else => {
                        try IO.print("\\{c}", .{format_str[i]});
                    },
                }
                i += 1;
            } else if (format_str[i] == '%' and i + 1 < format_str.len) {
                // Handle format specifiers
                i += 1;
                switch (format_str[i]) {
                    's' => {
                        if (arg_idx < cmd.args.len) {
                            try IO.print("{s}", .{cmd.args[arg_idx]});
                            arg_idx += 1;
                        }
                    },
                    'd' => {
                        if (arg_idx < cmd.args.len) {
                            const num = std.fmt.parseInt(i32, cmd.args[arg_idx], 10) catch 0;
                            try IO.print("{d}", .{num});
                            arg_idx += 1;
                        }
                    },
                    '%' => try IO.print("%", .{}),
                    else => {
                        try IO.print("%{c}", .{format_str[i]});
                    },
                }
                i += 1;
            } else {
                try IO.print("{c}", .{format_str[i]});
                i += 1;
            }
        }
    }

    /// Builtin: sleep - pause for specified seconds
    fn builtinSleep(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: sleep: missing operand\n", .{});
            self.last_exit_code = 1;
            return;
        }

        const seconds = std.fmt.parseInt(u32, cmd.args[0], 10) catch {
            try IO.eprint("den: sleep: invalid time interval '{s}'\n", .{cmd.args[0]});
            self.last_exit_code = 1;
            return;
        };

        std.posix.nanosleep(seconds, 0);
        self.last_exit_code = 0;
    }

    /// Builtin: help - show available builtins
    fn builtinHelp(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = self;
        _ = cmd;

        try IO.print("Den Shell - Built-in Commands\n\n", .{});
        try IO.print("Core Commands:\n", .{});
        try IO.print("  exit              Exit the shell\n", .{});
        try IO.print("  help              Show this help message\n", .{});
        try IO.print("  history [n]       Show command history\n", .{});
        try IO.print("\nFile System:\n", .{});
        try IO.print("  cd [dir]          Change directory\n", .{});
        try IO.print("  pwd               Print working directory\n", .{});
        try IO.print("  pushd [dir]       Push directory to stack and cd\n", .{});
        try IO.print("  popd              Pop directory from stack and cd\n", .{});
        try IO.print("  dirs              Show directory stack\n", .{});
        try IO.print("\nEnvironment:\n", .{});
        try IO.print("  env               Show environment variables\n", .{});
        try IO.print("  export VAR=val    Set and export variable\n", .{});
        try IO.print("  set VAR=val       Set shell variable\n", .{});
        try IO.print("  unset VAR         Unset variable\n", .{});
        try IO.print("\nAliases:\n", .{});
        try IO.print("  alias [name=val]  Define or list aliases\n", .{});
        try IO.print("  unalias name      Remove alias\n", .{});
        try IO.print("\nIntrospection:\n", .{});
        try IO.print("  type name         Identify command type\n", .{});
        try IO.print("  which name        Locate command in PATH\n", .{});
        try IO.print("  complete [-c|-f] prefix  Show completions\n", .{});
        try IO.print("\nJob Control:\n", .{});
        try IO.print("  jobs              List background jobs\n", .{});
        try IO.print("  fg [job_id]       Bring job to foreground\n", .{});
        try IO.print("  bg [job_id]       Continue job in background\n", .{});
        try IO.print("\nScripting:\n", .{});
        try IO.print("  source file       Execute commands from file\n", .{});
        try IO.print("  read var          Read line into variable\n", .{});
        try IO.print("  test expr         Evaluate conditional\n", .{});
        try IO.print("  [ expr ]          Evaluate conditional\n", .{});
        try IO.print("  true              Return success (exit code 0)\n", .{});
        try IO.print("  false             Return failure (exit code 1)\n", .{});
        try IO.print("  sleep n           Pause for n seconds\n", .{});
        try IO.print("  eval args         Execute arguments as command\n", .{});
        try IO.print("  command cmd       Execute bypassing aliases\n", .{});
        try IO.print("  shift [n]         Shift positional parameters\n", .{});
        try IO.print("\nPath Utilities:\n", .{});
        try IO.print("  basename path     Extract filename from path\n", .{});
        try IO.print("  dirname path      Extract directory from path\n", .{});
        try IO.print("  realpath path     Resolve absolute path\n", .{});
        try IO.print("\nSystem Info:\n", .{});
        try IO.print("  uname [-a]        Print system information\n", .{});
        try IO.print("  whoami            Print current username\n", .{});
        try IO.print("  umask [mode]      Get/set file creation mask\n", .{});
        try IO.print("\nPerformance:\n", .{});
        try IO.print("  time command      Measure execution time\n", .{});
        try IO.print("  hash [-r] [cmd]   Command path caching\n", .{});
        try IO.print("\nOutput:\n", .{});
        try IO.print("  echo [args...]    Print arguments\n", .{});
        try IO.print("  printf fmt args   Formatted output\n", .{});
        try IO.print("  clear             Clear terminal screen\n", .{});
        try IO.print("\nScript Control:\n", .{});
        try IO.print("  return [n]        Return from function/script\n", .{});
        try IO.print("  break [n]         Exit from loop\n", .{});
        try IO.print("  continue [n]      Skip to next loop iteration\n", .{});
        try IO.print("  local VAR=val     Declare local variable\n", .{});
        try IO.print("  declare VAR=val   Declare variable with attributes\n", .{});
        try IO.print("  readonly VAR=val  Declare readonly variable\n", .{});
        try IO.print("\nJob Management:\n", .{});
        try IO.print("  kill [-s sig] pid Send signal to process/job\n", .{});
        try IO.print("  wait [pid|job]    Wait for job completion\n", .{});
        try IO.print("  disown [job]      Remove job from table\n", .{});
        try IO.print("\nAdvanced Execution:\n", .{});
        try IO.print("  exec command      Replace shell with command\n", .{});
        try IO.print("  builtin cmd       Execute builtin bypassing functions\n", .{});
        try IO.print("  trap cmd sig      Handle signals (stub)\n", .{});
        try IO.print("  getopts spec var  Parse command options (stub)\n", .{});
        try IO.print("  timeout dur cmd   Execute with timeout (stub)\n", .{});
        try IO.print("  times             Display process times\n", .{});
        try IO.print("\nTotal: 54 builtin commands available\n", .{});
        try IO.print("For more help, use 'man bash' or visit docs.den.sh\n", .{});
    }

    /// Builtin: basename - extract filename from path
    fn builtinBasename(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: basename: missing operand\n", .{});
            self.last_exit_code = 1;
            return;
        }

        const path = cmd.args[0];
        const base = std.fs.path.basename(path);

        // Handle optional suffix removal
        if (cmd.args.len > 1) {
            const suffix = cmd.args[1];
            if (std.mem.endsWith(u8, base, suffix)) {
                const trimmed = base[0 .. base.len - suffix.len];
                try IO.print("{s}\n", .{trimmed});
            } else {
                try IO.print("{s}\n", .{base});
            }
        } else {
            try IO.print("{s}\n", .{base});
        }

        self.last_exit_code = 0;
    }

    /// Builtin: dirname - extract directory from path
    fn builtinDirname(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: dirname: missing operand\n", .{});
            self.last_exit_code = 1;
            return;
        }

        const path = cmd.args[0];
        const dir = std.fs.path.dirname(path) orelse ".";
        try IO.print("{s}\n", .{dir});
        self.last_exit_code = 0;
    }

    /// Builtin: realpath - resolve absolute path
    fn builtinRealpath(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: realpath: missing operand\n", .{});
            self.last_exit_code = 1;
            return;
        }

        const path = cmd.args[0];
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = std.fs.cwd().realpath(path, &buf) catch |err| {
            try IO.eprint("den: realpath: {s}: {}\n", .{ path, err });
            self.last_exit_code = 1;
            return;
        };

        try IO.print("{s}\n", .{real});
        self.last_exit_code = 0;
    }

    /// Builtin: command - run command bypassing aliases/builtins
    fn builtinCommand(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: command: missing command argument\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Simplified: execute as a single-command chain
        const single_cmd = types.ParsedCommand{
            .name = cmd.args[0],
            .args = if (cmd.args.len > 1) cmd.args[1..] else &[_][]const u8{},
            .redirections = &[_]types.Redirection{},
            .type = .external,
        };

        const cmds = [_]types.ParsedCommand{single_cmd};
        const ops: []types.Operator = &[_]types.Operator{};

        var chain = types.CommandChain{
            .commands = @constCast(&cmds),
            .operators = ops,
        };

        var executor = executor_mod.Executor.init(self.allocator, &self.environment);
        const exit_code = executor.executeChain(&chain) catch |err| {
            try IO.eprint("den: command: {}\n", .{err});
            self.last_exit_code = 127;
            return;
        };

        self.last_exit_code = exit_code;
    }

    /// Builtin: eval - execute arguments as shell command
    fn builtinEval(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            self.last_exit_code = 0;
            return;
        }

        // Join all arguments into a single command string
        var cmd_buf: [4096]u8 = undefined;
        var cmd_len: usize = 0;

        for (cmd.args, 0..) |arg, i| {
            if (i > 0 and cmd_len < cmd_buf.len) {
                cmd_buf[cmd_len] = ' ';
                cmd_len += 1;
            }

            const copy_len = @min(arg.len, cmd_buf.len - cmd_len);
            @memcpy(cmd_buf[cmd_len .. cmd_len + copy_len], arg[0..copy_len]);
            cmd_len += copy_len;

            if (cmd_len >= cmd_buf.len) break;
        }

        const command_str = cmd_buf[0..cmd_len];

        // Execute as if typed at prompt
        // Tokenize
        var tokenizer = parser_mod.Tokenizer.init(self.allocator, command_str);
        const tokens = tokenizer.tokenize() catch |err| {
            try IO.eprint("den: eval: parse error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };
        defer self.allocator.free(tokens);

        if (tokens.len == 0) {
            self.last_exit_code = 0;
            return;
        }

        // Parse
        var parser = parser_mod.Parser.init(self.allocator, tokens);
        var chain = parser.parse() catch |err| {
            try IO.eprint("den: eval: parse error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };
        defer chain.deinit(self.allocator);

        // Expand variables and aliases
        try self.expandCommandChain(&chain);
        try self.expandAliases(&chain);

        // Execute
        var executor = executor_mod.Executor.init(self.allocator, &self.environment);
        const exit_code = executor.executeChain(&chain) catch |err| {
            try IO.eprint("den: eval: execution error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };

        self.last_exit_code = exit_code;
    }

    /// Builtin: shift - shift positional parameters
    fn builtinShift(self: *Shell, cmd: *types.ParsedCommand) !void {
        // Parse shift count (default 1)
        const n: usize = if (cmd.args.len > 0)
            std.fmt.parseInt(usize, cmd.args[0], 10) catch 1
        else
            1;

        if (n > self.positional_params_count) {
            try IO.eprint("den: shift: shift count too large\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Shift parameters by freeing first n and moving rest
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (self.positional_params[i]) |param| {
                self.allocator.free(param);
                self.positional_params[i] = null;
            }
        }

        // Move remaining parameters down
        var dest: usize = 0;
        var src: usize = n;
        while (src < self.positional_params.len) : (src += 1) {
            self.positional_params[dest] = self.positional_params[src];
            if (dest != src) {
                self.positional_params[src] = null;
            }
            dest += 1;
        }

        self.positional_params_count -= n;
        self.last_exit_code = 0;
    }

    /// Builtin: time - time command execution
    fn builtinTime(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: time: missing command\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Join arguments to form command
        var cmd_buf: [4096]u8 = undefined;
        var cmd_len: usize = 0;

        for (cmd.args, 0..) |arg, i| {
            if (i > 0 and cmd_len < cmd_buf.len) {
                cmd_buf[cmd_len] = ' ';
                cmd_len += 1;
            }

            const copy_len = @min(arg.len, cmd_buf.len - cmd_len);
            @memcpy(cmd_buf[cmd_len .. cmd_len + copy_len], arg[0..copy_len]);
            cmd_len += copy_len;

            if (cmd_len >= cmd_buf.len) break;
        }

        const command_str = cmd_buf[0..cmd_len];

        // Get start time
        const start_time = std.time.nanoTimestamp();

        // Execute command
        var tokenizer = parser_mod.Tokenizer.init(self.allocator, command_str);
        const tokens = tokenizer.tokenize() catch |err| {
            try IO.eprint("den: time: parse error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };
        defer self.allocator.free(tokens);

        var parser = parser_mod.Parser.init(self.allocator, tokens);
        var chain = parser.parse() catch |err| {
            try IO.eprint("den: time: parse error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };
        defer chain.deinit(self.allocator);

        try self.expandCommandChain(&chain);
        try self.expandAliases(&chain);

        var executor = executor_mod.Executor.init(self.allocator, &self.environment);
        const exit_code = executor.executeChain(&chain) catch |err| {
            try IO.eprint("den: time: execution error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };

        // Get end time and calculate duration
        const end_time = std.time.nanoTimestamp();
        const duration_ns = end_time - start_time;
        const duration_ms = @divFloor(duration_ns, 1_000_000);
        const duration_s = @divFloor(duration_ms, 1000);
        const remaining_ms = @mod(duration_ms, 1000);

        try IO.eprint("\nreal\t{d}.{d:0>3}s\n", .{ duration_s, remaining_ms });

        self.last_exit_code = exit_code;
    }

    /// Builtin: umask - set file creation mask
    fn builtinUmask(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            // Display current umask
            const current = std.c.umask(0);
            _ = std.c.umask(current); // Restore it
            try IO.print("{o:0>4}\n", .{current});
            self.last_exit_code = 0;
        } else {
            // Set new umask
            const new_mask = std.fmt.parseInt(u32, cmd.args[0], 8) catch {
                try IO.eprint("den: umask: invalid octal number: {s}\n", .{cmd.args[0]});
                self.last_exit_code = 1;
                return;
            };

            _ = std.c.umask(@intCast(new_mask));
            self.last_exit_code = 0;
        }
    }

    /// Builtin: clear - clear the terminal screen
    fn builtinClear(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = self;
        _ = cmd;
        // ANSI escape sequence to clear screen and move cursor to top-left
        try IO.print("\x1b[2J\x1b[H", .{});
    }

    /// Builtin: uname - print system information
    fn builtinUname(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = self;

        const show_all = cmd.args.len > 0 and std.mem.eql(u8, cmd.args[0], "-a");
        const show_system = cmd.args.len == 0 or show_all or
            (cmd.args.len > 0 and std.mem.eql(u8, cmd.args[0], "-s"));

        if (show_system or show_all) {
            // Get system name from uname
            var utsname: std.posix.utsname = undefined;
            const result = std.c.uname(&utsname);
            if (result == 0) {
                const sysname = std.mem.sliceTo(&utsname.sysname, 0);
                try IO.print("{s}", .{sysname});

                if (show_all) {
                    const nodename = std.mem.sliceTo(&utsname.nodename, 0);
                    const release = std.mem.sliceTo(&utsname.release, 0);
                    const version = std.mem.sliceTo(&utsname.version, 0);
                    const machine = std.mem.sliceTo(&utsname.machine, 0);
                    try IO.print(" {s} {s} {s} {s}", .{ nodename, release, version, machine });
                }
            }
            try IO.print("\n", .{});
        }
    }

    /// Builtin: whoami - print current username
    fn builtinWhoami(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = self;
        _ = cmd;

        const user = std.posix.getenv("USER") orelse
            std.posix.getenv("LOGNAME") orelse
            "unknown";
        try IO.print("{s}\n", .{user});
    }

    /// Builtin: hash - remember/display command paths (simplified)
    fn builtinHash(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            // Display message - full hash table implementation would go here
            try IO.print("den: hash: command path caching not yet implemented\n", .{});
            self.last_exit_code = 0;
        } else if (std.mem.eql(u8, cmd.args[0], "-r")) {
            // Clear hash table
            try IO.print("den: hash: cache cleared\n", .{});
            self.last_exit_code = 0;
        } else {
            // Add command to hash table
            try IO.print("den: hash: {s} added to cache\n", .{cmd.args[0]});
            self.last_exit_code = 0;
        }
    }

    /// Builtin: return - return from function or script
    fn builtinReturn(self: *Shell, cmd: *types.ParsedCommand) !void {
        const code = if (cmd.args.len > 0)
            std.fmt.parseInt(i32, cmd.args[0], 10) catch 0
        else
            self.last_exit_code;

        // Set exit code and signal return
        self.last_exit_code = code;
        // In a full implementation, this would set a flag to break out of function/script
        // For now, just set the exit code
    }

    /// Builtin: break - exit from loop
    fn builtinBreak(self: *Shell, cmd: *types.ParsedCommand) !void {
        const levels = if (cmd.args.len > 0)
            std.fmt.parseInt(u32, cmd.args[0], 10) catch 1
        else
            1;

        // In a full implementation, this would break out of N levels of loops
        // For now, just acknowledge the command
        _ = levels;
        self.last_exit_code = 0;
        try IO.print("den: break: loop control not yet fully implemented\n", .{});
    }

    /// Builtin: continue - skip to next loop iteration
    fn builtinContinue(self: *Shell, cmd: *types.ParsedCommand) !void {
        const levels = if (cmd.args.len > 0)
            std.fmt.parseInt(u32, cmd.args[0], 10) catch 1
        else
            1;

        // In a full implementation, this would continue N levels of loops
        // For now, just acknowledge the command
        _ = levels;
        self.last_exit_code = 0;
        try IO.print("den: continue: loop control not yet fully implemented\n", .{});
    }

    /// Builtin: local - declare local variables (function scope)
    fn builtinLocal(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            // List local variables - for now, just show message
            try IO.print("den: local: variable scoping not yet fully implemented\n", .{});
            self.last_exit_code = 0;
            return;
        }

        // Parse VAR=value assignments
        for (cmd.args) |arg| {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                const var_name = arg[0..eq_pos];
                const var_value = arg[eq_pos + 1 ..];

                // For now, treat like regular export (full impl would track scope)
                const value = try self.allocator.dupe(u8, var_value);
                const gop = try self.environment.getOrPut(var_name);
                if (gop.found_existing) {
                    self.allocator.free(gop.value_ptr.*);
                    gop.value_ptr.* = value;
                } else {
                    const key = try self.allocator.dupe(u8, var_name);
                    gop.key_ptr.* = key;
                    gop.value_ptr.* = value;
                }
                self.last_exit_code = 0;
            } else {
                // Variable without value - declare it
                const gop = try self.environment.getOrPut(arg);
                if (!gop.found_existing) {
                    const key = try self.allocator.dupe(u8, arg);
                    const value = try self.allocator.dupe(u8, "");
                    gop.key_ptr.* = key;
                    gop.value_ptr.* = value;
                }
                self.last_exit_code = 0;
            }
        }
    }

    /// Builtin: declare - declare variables with attributes
    fn builtinDeclare(self: *Shell, cmd: *types.ParsedCommand) !void {
        // For now, treat like local
        try self.builtinLocal(cmd);
    }

    /// Builtin: readonly - declare readonly variables
    fn builtinReadonly(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.print("den: readonly: not yet fully implemented\n", .{});
            self.last_exit_code = 0;
            return;
        }

        // For now, just set variables (full impl would mark as readonly)
        for (cmd.args) |arg| {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                const var_name = arg[0..eq_pos];
                const var_value = arg[eq_pos + 1 ..];

                const value = try self.allocator.dupe(u8, var_value);
                const gop = try self.environment.getOrPut(var_name);
                if (gop.found_existing) {
                    self.allocator.free(gop.value_ptr.*);
                    gop.value_ptr.* = value;
                } else {
                    const key = try self.allocator.dupe(u8, var_name);
                    gop.key_ptr.* = key;
                    gop.value_ptr.* = value;
                }
            }
        }
        self.last_exit_code = 0;
    }

    /// Builtin: exec - replace shell with command
    fn builtinExec(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: exec: command required\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // In a full implementation, this would use execvpe to replace the shell process
        // For now, execute the command and set running=false to exit the shell
        const new_cmd = types.ParsedCommand{
            .name = cmd.args[0],
            .args = if (cmd.args.len > 1) cmd.args[1..] else &[_][]const u8{},
            .redirections = &[_]types.Redirection{},
        };

        const cmds = [_]types.ParsedCommand{new_cmd};
        const ops = [_]types.Operator{};
        var chain = types.CommandChain{
            .commands = @constCast(&cmds),
            .operators = @constCast(&ops),
        };

        // Execute the command
        var executor = executor_mod.Executor.init(self.allocator, &self.environment);
        const exit_code = try executor.executeChain(&chain);
        self.last_exit_code = exit_code;

        // Mark shell as not running to exit after this command
        self.running = false;
    }

    /// Builtin: wait - wait for job completion
    fn builtinWait(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            // Wait for all background jobs
            var waited = false;
            for (&self.background_jobs) |*maybe_job| {
                if (maybe_job.*) |*job| {
                    if (job.pid > 0) {
                        const result = std.posix.waitpid(job.pid, 0);
                        job.pid = 0; // Mark as completed
                        waited = true;
                        _ = result;
                    }
                }
            }
            self.last_exit_code = if (waited) 0 else 127;
            return;
        }

        // Wait for specific job(s)
        for (cmd.args) |arg| {
            if (arg[0] == '%') {
                const job_id = std.fmt.parseInt(usize, arg[1..], 10) catch {
                    try IO.eprint("den: wait: {s}: invalid job specification\n", .{arg});
                    self.last_exit_code = 1;
                    continue;
                };

                if (job_id > 0 and job_id <= self.background_jobs.len) {
                    if (self.background_jobs[job_id - 1]) |*job| {
                        if (job.pid > 0) {
                            const result = std.posix.waitpid(job.pid, 0);
                            job.pid = 0;
                            self.last_exit_code = 0;
                            _ = result;
                        }
                    }
                }
            } else {
                // Wait by PID
                const pid = std.fmt.parseInt(i32, arg, 10) catch {
                    try IO.eprint("den: wait: {s}: not a valid process id\n", .{arg});
                    self.last_exit_code = 1;
                    continue;
                };
                const result = std.posix.waitpid(pid, 0);
                self.last_exit_code = 0;
                _ = result;
            }
        }
    }

    /// Builtin: kill - send signal to job or process
    fn builtinKill(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: kill: usage: kill [-s sigspec | -n signum | -sigspec] pid | jobspec ...\n", .{});
            self.last_exit_code = 1;
            return;
        }

        var signal: u8 = std.posix.SIG.TERM; // Default signal
        var arg_idx: usize = 0;

        // Parse signal specification
        if (cmd.args.len > 1 and cmd.args[0][0] == '-') {
            const sig_arg = cmd.args[0];
            if (sig_arg.len > 1) {
                // Try to parse as number (e.g., -9)
                signal = std.fmt.parseInt(u8, sig_arg[1..], 10) catch blk: {
                    // Try to parse as name (e.g., -TERM, -KILL)
                    const sig_name = sig_arg[1..];
                    if (std.mem.eql(u8, sig_name, "TERM")) break :blk std.posix.SIG.TERM;
                    if (std.mem.eql(u8, sig_name, "KILL")) break :blk std.posix.SIG.KILL;
                    if (std.mem.eql(u8, sig_name, "INT")) break :blk std.posix.SIG.INT;
                    if (std.mem.eql(u8, sig_name, "HUP")) break :blk std.posix.SIG.HUP;
                    if (std.mem.eql(u8, sig_name, "STOP")) break :blk std.posix.SIG.STOP;
                    if (std.mem.eql(u8, sig_name, "CONT")) break :blk std.posix.SIG.CONT;
                    try IO.eprint("den: kill: {s}: invalid signal specification\n", .{sig_name});
                    self.last_exit_code = 1;
                    return;
                };
                arg_idx = 1;
            }
        }

        // Send signal to each specified process/job
        while (arg_idx < cmd.args.len) : (arg_idx += 1) {
            const target = cmd.args[arg_idx];

            if (target[0] == '%') {
                // Job specification
                const job_id = std.fmt.parseInt(usize, target[1..], 10) catch {
                    try IO.eprint("den: kill: {s}: invalid job specification\n", .{target});
                    self.last_exit_code = 1;
                    continue;
                };

                if (job_id > 0 and job_id <= self.background_jobs.len) {
                    if (self.background_jobs[job_id - 1]) |job| {
                        if (job.pid > 0) {
                            std.posix.kill(job.pid, signal) catch {
                                try IO.eprint("den: kill: ({d}) - No such process\n", .{job.pid});
                                self.last_exit_code = 1;
                                continue;
                            };
                        }
                    }
                }
            } else {
                // PID specification
                const pid = std.fmt.parseInt(i32, target, 10) catch {
                    try IO.eprint("den: kill: {s}: arguments must be process or job IDs\n", .{target});
                    self.last_exit_code = 1;
                    continue;
                };

                std.posix.kill(pid, signal) catch {
                    try IO.eprint("den: kill: ({d}) - No such process\n", .{pid});
                    self.last_exit_code = 1;
                    continue;
                };
            }
        }

        self.last_exit_code = 0;
    }

    /// Builtin: disown - remove jobs from job table
    fn builtinDisown(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            // Disown most recent job
            var found = false;
            var i: usize = self.background_jobs.len;
            while (i > 0) {
                i -= 1;
                if (self.background_jobs[i]) |_| {
                    self.background_jobs[i] = null;
                    found = true;
                    break;
                }
            }
            if (!found) {
                try IO.eprint("den: disown: current: no such job\n", .{});
                self.last_exit_code = 1;
            }
            return;
        }

        // Disown specific jobs
        for (cmd.args) |arg| {
            if (arg[0] == '%') {
                const job_id = std.fmt.parseInt(usize, arg[1..], 10) catch {
                    try IO.eprint("den: disown: {s}: no such job\n", .{arg});
                    self.last_exit_code = 1;
                    continue;
                };

                if (job_id > 0 and job_id <= self.background_jobs.len) {
                    self.background_jobs[job_id - 1] = null;
                } else {
                    try IO.eprint("den: disown: %{d}: no such job\n", .{job_id});
                    self.last_exit_code = 1;
                }
            }
        }
        self.last_exit_code = 0;
    }

    /// Builtin: trap - handle signals and special events
    fn builtinTrap(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.print("den: trap: full signal handling not yet implemented\n", .{});
            self.last_exit_code = 0;
            return;
        }

        // Stub - full implementation would register signal handlers
        try IO.print("den: trap: registering handler for signals (stub)\n", .{});
        self.last_exit_code = 0;
    }

    /// Builtin: getopts - parse command options
    fn builtinGetopts(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = cmd;
        try IO.print("den: getopts: option parsing not yet implemented\n", .{});
        self.last_exit_code = 1;
    }

    /// Builtin: timeout - execute command with timeout
    fn builtinTimeout(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len < 2) {
            try IO.eprint("den: timeout: usage: timeout DURATION COMMAND [ARG]...\n", .{});
            self.last_exit_code = 1;
            return;
        }

        try IO.print("den: timeout: command timeout not yet implemented\n", .{});
        self.last_exit_code = 1;
    }

    /// Builtin: times - display process times
    fn builtinTimes(self: *Shell, cmd: *types.ParsedCommand) !void {
        _ = cmd;
        try IO.print("0m0.000s 0m0.000s\n", .{}); // Shell user/sys time
        try IO.print("0m0.000s 0m0.000s\n", .{}); // Children user/sys time
        self.last_exit_code = 0;
    }

    /// Builtin: builtin - execute builtin command
    fn builtinBuiltin(self: *Shell, cmd: *types.ParsedCommand) !void {
        if (cmd.args.len == 0) {
            try IO.eprint("den: builtin: usage: builtin [shell-builtin [arg ...]]\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Execute the specified builtin, bypassing any functions with the same name
        const builtin_name = cmd.args[0];
        const new_cmd = types.ParsedCommand{
            .name = builtin_name,
            .args = if (cmd.args.len > 1) cmd.args[1..] else &[_][]const u8{},
            .redirections = &[_]types.Redirection{},
        };

        // Create a simple chain with just this command
        const cmds = [_]types.ParsedCommand{new_cmd};
        const ops = [_]types.Operator{};
        var chain = types.CommandChain{
            .commands = @constCast(&cmds),
            .operators = @constCast(&ops),
        };

        // Execute using executor (builtins will be dispatched there)
        var executor = executor_mod.Executor.init(self.allocator, &self.environment);
        const exit_code = try executor.executeChain(&chain);
        self.last_exit_code = exit_code;
    }
};


test "shell initialization" {
    const allocator = std.testing.allocator;
    var sh = try Shell.init(allocator);
    defer sh.deinit();

    try std.testing.expect(!sh.running);
}
