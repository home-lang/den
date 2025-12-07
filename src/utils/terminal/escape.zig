/// Escape sequence parser for arrow keys, function keys, etc.
pub const EscapeSequence = enum {
    up_arrow,
    down_arrow,
    left_arrow,
    right_arrow,
    ctrl_left, // Ctrl+Left arrow (word back)
    ctrl_right, // Ctrl+Right arrow (word forward)
    alt_b, // Alt+B (word back)
    alt_f, // Alt+F (word forward)
    alt_d, // Alt+D (delete word forward)
    home,
    end_key,
    delete,
    page_up,
    page_down,
    unknown,

    /// Parse escape sequence from input
    /// Returns null if not a complete sequence yet
    pub fn parse(bytes: []const u8) ?EscapeSequence {
        if (bytes.len < 2) return null;

        // Check for CSI sequence (ESC [)
        if (bytes[0] == 0x1B and bytes[1] == '[') {
            if (bytes.len < 3) return null;

            // Single character sequences
            switch (bytes[2]) {
                'A' => return .up_arrow,
                'B' => return .down_arrow,
                'C' => return .right_arrow,
                'D' => return .left_arrow,
                'H' => return .home,
                'F' => return .end_key,
                else => {},
            }

            // Multi-character sequences
            if (bytes.len >= 4 and bytes[3] == '~') {
                switch (bytes[2]) {
                    '3' => return .delete,
                    '5' => return .page_up,
                    '6' => return .page_down,
                    else => {},
                }
            }

            // Ctrl+Arrow sequences: ESC[1;5C (right) or ESC[1;5D (left)
            if (bytes.len >= 6 and bytes[2] == '1' and bytes[3] == ';' and bytes[4] == '5') {
                switch (bytes[5]) {
                    'C' => return .ctrl_right,
                    'D' => return .ctrl_left,
                    else => {},
                }
            }
        }

        // Alt+key sequences (ESC followed by character)
        if (bytes[0] == 0x1B and bytes.len >= 2 and bytes[1] != '[') {
            switch (bytes[1]) {
                'b', 'B' => return .alt_b, // Alt+B (word back)
                'f', 'F' => return .alt_f, // Alt+F (word forward)
                'd', 'D' => return .alt_d, // Alt+D (delete word forward)
                else => return .unknown,
            }
        }

        return .unknown;
    }
};
