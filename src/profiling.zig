// Profiling module exports
pub const Profiler = @import("profiling/profiler.zig").Profiler;
pub const ProfileZone = @import("profiling/profiler.zig").ProfileZone;
pub const ProfileEvent = @import("profiling/profiler.zig").ProfileEvent;
pub const ScopedZone = @import("profiling/profiler.zig").ScopedZone;
pub const profile = @import("profiling/profiler.zig").profile;

pub const Benchmark = @import("profiling/benchmarks.zig").Benchmark;
pub const BenchmarkResult = @import("profiling/benchmarks.zig").BenchmarkResult;
pub const BenchmarkSuite = @import("profiling/benchmarks.zig").BenchmarkSuite;
