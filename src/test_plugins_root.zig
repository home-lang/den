//! src-rooted aggregator for the plugin test suite. Rooting the test module at
//! `src/` (rather than at `src/plugins/test_plugins.zig`) keeps the module path
//! at `src/`, so the plugin sources' `@import("../shell.zig")` /
//! `@import("../utils/io.zig")` imports resolve correctly.

test {
    _ = @import("plugins/test_plugins.zig");
}
