/// Job control module for Den shell.
///
/// This module provides centralized job management including:
/// - Background job tracking
/// - Job status monitoring
/// - Builtin implementations (jobs, fg, bg, disown, wait)
pub const job_manager = @import("job_manager.zig");

pub const JobManager = job_manager.JobManager;
pub const JobStatus = job_manager.JobStatus;
pub const BackgroundJob = job_manager.BackgroundJob;
pub const ProcessId = job_manager.ProcessId;
pub const MAX_JOBS = job_manager.MAX_JOBS;
