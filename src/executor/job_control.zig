const std = @import("std");
const builtin = @import("builtin");
const process = @import("../utils/process.zig");

/// Cross-Platform Job Control
/// Provides unified API for managing background jobs across POSIX and Windows

// =============================================================================
// Job State
// =============================================================================

/// Job status
pub const JobStatus = enum {
    running,
    stopped,
    completed,
    failed,

    pub fn toString(self: JobStatus) []const u8 {
        return switch (self) {
            .running => "Running",
            .stopped => "Stopped",
            .completed => "Done",
            .failed => "Exit",
        };
    }
};

/// A background job
pub const Job = struct {
    id: usize,
    pid: process.ProcessId,
    command: []const u8,
    status: JobStatus,
    exit_code: ?i32 = null,

    /// Check if job is still active
    pub fn isActive(self: *const Job) bool {
        return self.status == .running or self.status == .stopped;
    }
};

// =============================================================================
// Job Control Operations
// =============================================================================

/// Wait for a specific job to complete
pub fn waitJob(job: *Job) !process.ExitStatus {
    const result = try process.waitProcess(job.pid, .{ .no_hang = false });

    if (result.status.success()) {
        job.status = .completed;
    } else {
        job.status = .failed;
    }
    job.exit_code = result.status.code;

    return result.status;
}

/// Wait for job with timeout (non-blocking check)
pub fn checkJob(job: *Job) !bool {
    const result = try process.waitProcess(job.pid, .{ .no_hang = true });

    if (!result.still_running) {
        if (result.status.success()) {
            job.status = .completed;
        } else {
            job.status = .failed;
        }
        job.exit_code = result.status.code;
        return false; // Job completed
    }

    return true; // Job still running
}

/// Send signal to job (terminate)
pub fn killJob(job: *Job, signal: u8) !void {
    try process.killProcess(job.pid, signal);
}

/// Terminate job gracefully (SIGTERM or Windows equivalent)
pub fn terminateJob(job: *Job) !void {
    try process.terminateProcess(job.pid);
}

/// Force kill job (SIGKILL or Windows equivalent)
pub fn forceKillJob(job: *Job) !void {
    try process.forceKillProcess(job.pid);
}

/// Stop/pause a job (SIGSTOP) - POSIX only
pub fn stopJob(job: *Job) !void {
    if (builtin.os.tag == .windows) {
        return error.NotSupported;
    }
    try process.stopProcess(job.pid);
    job.status = .stopped;
}

/// Continue/resume a job (SIGCONT) - POSIX only
pub fn continueJob(job: *Job) !void {
    if (builtin.os.tag == .windows) {
        return error.NotSupported;
    }
    try process.continueProcess(job.pid);
    job.status = .running;
}

/// Bring job to foreground (wait for completion)
pub fn foregroundJob(job: *Job) !process.ExitStatus {
    // On POSIX, we could use tcsetpgrp to give terminal control
    // For simplicity, we just resume and wait for the job

    if (job.status == .stopped) {
        try continueJob(job);
    }

    return try waitJob(job);
}

/// Send job to background (continue without waiting)
pub fn backgroundJob(job: *Job) !void {
    if (job.status == .stopped) {
        try continueJob(job);
    }
    job.status = .running;
}

// =============================================================================
// Job List Management
// =============================================================================

/// Job list for managing multiple background jobs
pub const JobList = struct {
    jobs: std.ArrayList(?Job),
    allocator: std.mem.Allocator,
    next_id: usize = 1,

    pub fn init(allocator: std.mem.Allocator) JobList {
        return .{
            .jobs = std.ArrayList(?Job).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *JobList) void {
        // Free command strings
        for (self.jobs.items) |maybe_job| {
            if (maybe_job) |job| {
                self.allocator.free(job.command);
            }
        }
        self.jobs.deinit();
    }

    /// Add a new job
    pub fn addJob(self: *JobList, pid: process.ProcessId, command: []const u8) !*Job {
        const cmd_copy = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(cmd_copy);

        const job = Job{
            .id = self.next_id,
            .pid = pid,
            .command = cmd_copy,
            .status = .running,
        };

        // Find empty slot or append
        for (self.jobs.items, 0..) |*maybe_job, i| {
            if (maybe_job.* == null) {
                maybe_job.* = job;
                self.next_id += 1;
                return &self.jobs.items[i].?;
            }
        }

        try self.jobs.append(job);
        self.next_id += 1;
        return &self.jobs.items[self.jobs.items.len - 1].?;
    }

    /// Remove a job by index
    pub fn removeJob(self: *JobList, index: usize) void {
        if (index >= self.jobs.items.len) return;
        if (self.jobs.items[index]) |job| {
            self.allocator.free(job.command);
            self.jobs.items[index] = null;
        }
    }

    /// Get job by ID
    pub fn getJobById(self: *JobList, id: usize) ?*Job {
        for (self.jobs.items) |*maybe_job| {
            if (maybe_job.*) |*job| {
                if (job.id == id) return job;
            }
        }
        return null;
    }

    /// Get job by index
    pub fn getJobByIndex(self: *JobList, index: usize) ?*Job {
        if (index >= self.jobs.items.len) return null;
        if (self.jobs.items[index]) |*job| {
            return job;
        }
        return null;
    }

    /// Get most recent job
    pub fn getLastJob(self: *JobList) ?*Job {
        var last: ?*Job = null;
        for (self.jobs.items) |*maybe_job| {
            if (maybe_job.*) |*job| {
                if (job.isActive()) {
                    last = job;
                }
            }
        }
        return last;
    }

    /// Count active jobs
    pub fn activeCount(self: *const JobList) usize {
        var count: usize = 0;
        for (self.jobs.items) |maybe_job| {
            if (maybe_job) |job| {
                if (job.isActive()) count += 1;
            }
        }
        return count;
    }

    /// Update status of all jobs (non-blocking check)
    pub fn updateAll(self: *JobList) void {
        for (self.jobs.items) |*maybe_job| {
            if (maybe_job.*) |*job| {
                if (job.status == .running) {
                    _ = checkJob(job) catch {};
                }
            }
        }
    }

    /// Wait for all jobs to complete
    pub fn waitAll(self: *JobList) void {
        for (self.jobs.items) |*maybe_job| {
            if (maybe_job.*) |*job| {
                if (job.isActive()) {
                    _ = waitJob(job) catch {};
                }
            }
        }
    }

    /// Print job list (for `jobs` builtin)
    pub fn printJobs(self: *const JobList, writer: anytype) !void {
        for (self.jobs.items, 0..) |maybe_job, i| {
            if (maybe_job) |job| {
                const current_marker: u8 = if (i == self.jobs.items.len - 1) '+' else if (i == self.jobs.items.len - 2) '-' else ' ';

                try writer.print("[{d}]{c} {s}\t\t{s}\n", .{
                    job.id,
                    current_marker,
                    job.status.toString(),
                    job.command,
                });
            }
        }
    }
};

// =============================================================================
// Utility Functions
// =============================================================================

/// Parse job specification (e.g., %1, %+, %-, %%))
pub fn parseJobSpec(spec: []const u8, job_list: *JobList) ?*Job {
    if (spec.len == 0) return null;

    if (spec[0] != '%') {
        // Not a job spec, might be a PID
        return null;
    }

    if (spec.len == 1) {
        // Just %, same as %+
        return job_list.getLastJob();
    }

    const spec_char = spec[1];

    switch (spec_char) {
        '+', '%' => return job_list.getLastJob(),
        '-' => {
            // Previous job
            var prev: ?*Job = null;
            var last: ?*Job = null;
            for (job_list.jobs.items) |*maybe_job| {
                if (maybe_job.*) |*job| {
                    if (job.isActive()) {
                        prev = last;
                        last = job;
                    }
                }
            }
            return prev;
        },
        '0'...'9' => {
            // Job number
            const id = std.fmt.parseInt(usize, spec[1..], 10) catch return null;
            return job_list.getJobById(id);
        },
        else => {
            // Job name prefix search
            const prefix = spec[1..];
            for (job_list.jobs.items) |*maybe_job| {
                if (maybe_job.*) |*job| {
                    if (std.mem.startsWith(u8, job.command, prefix)) {
                        return job;
                    }
                }
            }
            return null;
        },
    }
}

/// Check if job control is supported on this platform
pub fn isJobControlSupported() bool {
    // Job control is fully supported on POSIX
    // On Windows, basic background execution works but stop/continue doesn't
    return true;
}

/// Check if stop/continue is supported
pub fn isStopContinueSupported() bool {
    return builtin.os.tag != .windows;
}

// =============================================================================
// Tests
// =============================================================================

test "job status toString" {
    try std.testing.expectEqualStrings("Running", JobStatus.running.toString());
    try std.testing.expectEqualStrings("Stopped", JobStatus.stopped.toString());
    try std.testing.expectEqualStrings("Done", JobStatus.completed.toString());
    try std.testing.expectEqualStrings("Exit", JobStatus.failed.toString());
}

test "job list init and deinit" {
    const allocator = std.testing.allocator;
    var list = JobList.init(allocator);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 0), list.activeCount());
}

test "job control support detection" {
    _ = isJobControlSupported();
    _ = isStopContinueSupported();
}
