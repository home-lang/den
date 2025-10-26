const std = @import("std");

/// Simple arithmetic evaluator for shell arithmetic expansion
pub const Arithmetic = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Arithmetic {
        return .{ .allocator = allocator };
    }

    /// Evaluate an arithmetic expression and return the result
    pub fn eval(self: *Arithmetic, expr: []const u8) !i64 {
        const trimmed = std.mem.trim(u8, expr, &std.ascii.whitespace);

        // Parse and evaluate the expression
        var parser = Parser{
            .input = trimmed,
            .pos = 0,
            .allocator = self.allocator,
        };

        return try parser.parseExpression();
    }
};

const ArithmeticError = error{
    DivisionByZero,
    NegativeExponent,
    UnexpectedEnd,
    MissingClosingParen,
    InvalidNumber,
};

const Parser = struct {
    input: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    fn parseExpression(self: *Parser) ArithmeticError!i64 {
        return try self.parseAddSub();
    }

    fn parseAddSub(self: *Parser) ArithmeticError!i64 {
        var left = try self.parseMulDiv();

        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) break;

            const op = self.input[self.pos];
            if (op == '+') {
                self.pos += 1;
                const right = try self.parseMulDiv();
                left = left + right;
            } else if (op == '-') {
                self.pos += 1;
                const right = try self.parseMulDiv();
                left = left - right;
            } else {
                break;
            }
        }

        return left;
    }

    fn parseMulDiv(self: *Parser) ArithmeticError!i64 {
        var left = try self.parsePower();

        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) break;

            const op = self.input[self.pos];
            if (op == '*') {
                self.pos += 1;
                const right = try self.parsePower();
                left = left * right;
            } else if (op == '/') {
                self.pos += 1;
                const right = try self.parsePower();
                if (right == 0) return error.DivisionByZero;
                left = @divTrunc(left, right);
            } else if (op == '%') {
                self.pos += 1;
                const right = try self.parsePower();
                if (right == 0) return error.DivisionByZero;
                left = @rem(left, right);
            } else {
                break;
            }
        }

        return left;
    }

    fn parsePower(self: *Parser) ArithmeticError!i64 {
        var left = try self.parseUnary();

        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) break;

            // Check for ** operator
            if (self.pos + 1 < self.input.len and
                self.input[self.pos] == '*' and
                self.input[self.pos + 1] == '*') {
                self.pos += 2;
                const right = try self.parseUnary();
                left = try self.power(left, right);
            } else {
                break;
            }
        }

        return left;
    }

    fn parseUnary(self: *Parser) ArithmeticError!i64 {
        self.skipWhitespace();

        if (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '-') {
                self.pos += 1;
                const value = try self.parseUnary();
                return -value;
            } else if (ch == '+') {
                self.pos += 1;
                return try self.parseUnary();
            }
        }

        return try self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) ArithmeticError!i64 {
        self.skipWhitespace();

        if (self.pos >= self.input.len) {
            return error.UnexpectedEnd;
        }

        // Handle parentheses
        if (self.input[self.pos] == '(') {
            self.pos += 1;
            const value = try self.parseExpression();
            self.skipWhitespace();
            if (self.pos >= self.input.len or self.input[self.pos] != ')') {
                return error.MissingClosingParen;
            }
            self.pos += 1;
            return value;
        }

        // Parse number
        return try self.parseNumber();
    }

    fn parseNumber(self: *Parser) ArithmeticError!i64 {
        self.skipWhitespace();

        const start = self.pos;

        // Allow leading sign
        if (self.pos < self.input.len and (self.input[self.pos] == '-' or self.input[self.pos] == '+')) {
            self.pos += 1;
        }

        // Parse digits
        while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
            self.pos += 1;
        }

        if (start == self.pos or (self.pos == start + 1 and !std.ascii.isDigit(self.input[start]))) {
            return error.InvalidNumber;
        }

        const num_str = self.input[start..self.pos];
        return std.fmt.parseInt(i64, num_str, 10) catch error.InvalidNumber;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }
    }

    fn power(self: *Parser, base: i64, exp: i64) ArithmeticError!i64 {
        _ = self;

        if (exp < 0) return error.NegativeExponent;
        if (exp == 0) return 1;

        var result: i64 = 1;
        var b = base;
        var e = exp;

        while (e > 0) {
            if (@rem(e, 2) == 1) {
                result = result * b;
            }
            b = b * b;
            e = @divTrunc(e, 2);
        }

        return result;
    }
};

test "arithmetic basic operations" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    try std.testing.expectEqual(@as(i64, 5), try arith.eval("2 + 3"));
    try std.testing.expectEqual(@as(i64, -1), try arith.eval("2 - 3"));
    try std.testing.expectEqual(@as(i64, 6), try arith.eval("2 * 3"));
    try std.testing.expectEqual(@as(i64, 2), try arith.eval("6 / 3"));
    try std.testing.expectEqual(@as(i64, 1), try arith.eval("7 % 3"));
}

test "arithmetic operator precedence" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    try std.testing.expectEqual(@as(i64, 14), try arith.eval("2 + 3 * 4"));
    try std.testing.expectEqual(@as(i64, 20), try arith.eval("(2 + 3) * 4"));
    try std.testing.expectEqual(@as(i64, 11), try arith.eval("2 * 3 + 5"));
}

test "arithmetic power" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    try std.testing.expectEqual(@as(i64, 8), try arith.eval("2 ** 3"));
    try std.testing.expectEqual(@as(i64, 16), try arith.eval("2 ** 2 ** 2"));
}

test "arithmetic unary operators" {
    const allocator = std.testing.allocator;
    var arith = Arithmetic.init(allocator);

    try std.testing.expectEqual(@as(i64, -5), try arith.eval("-5"));
    try std.testing.expectEqual(@as(i64, 5), try arith.eval("+5"));
    try std.testing.expectEqual(@as(i64, -8), try arith.eval("-(3 + 5)"));
}
