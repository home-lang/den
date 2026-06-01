//! src-rooted aggregator for the plugin integration test suite (keeps module
//! path at `src/` so plugin sources' `../` imports resolve).

test {
    _ = @import("plugins/test_integration.zig");
}
