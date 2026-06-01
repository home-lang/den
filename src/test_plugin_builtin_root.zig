//! src-rooted aggregator for the builtin-plugins test suite (keeps module path
//! at `src/` so plugin sources' `../` imports resolve).

test {
    _ = @import("plugins/test_builtin_plugins.zig");
}
