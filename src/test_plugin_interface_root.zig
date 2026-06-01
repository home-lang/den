//! src-rooted aggregator for the plugin interface test suite (keeps module path
//! at `src/` so plugin sources' `../` imports resolve).

test {
    _ = @import("plugins/test_interface.zig");
}
