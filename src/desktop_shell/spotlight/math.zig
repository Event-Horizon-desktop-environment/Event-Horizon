const std = @import("std");

const Token = union(enum) {
    num: f64,
    op: u8,
    lparen: void,
    rparen: void,
};

fn precedence(op: u8) u8 {
    return switch (op) {
        '+', '-' => 1,
        '*', '/', '%' => 2,
        '^' => 3,
        else => 0,
    };
}

fn applyOp(a: f64, b: f64, op: u8) ?f64 {
    return switch (op) {
        '+' => a + b,
        '-' => a - b,
        '*' => a * b,
        '/' => if (b == 0) null else a / b,
        '%' => if (b == 0) null else @mod(a, b),
        '^' => std.math.pow(f64, a, b),
        else => null,
    };
}

pub fn evaluate(expr: []const u8) ?f64 {
    var values: [64]f64 = undefined;
    var ops: [64]u8 = undefined;
    var nv: usize = 0;
    var no: usize = 0;
    var i: usize = 0;
    var expect_operand = true;
    while (i < expr.len) {
        const c = expr[i];
        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }
        if ((c >= '0' and c <= '9') or c == '.' or (c == '-' and expect_operand)) {
            const start = i;
            if (c == '-') i += 1;
            while (i < expr.len and ((expr[i] >= '0' and expr[i] <= '9') or expr[i] == '.' or expr[i] == 'e' or expr[i] == 'E')) i += 1;
            const v = std.fmt.parseFloat(f64, expr[start..i]) catch return null;
            if (nv >= values.len) return null;
            values[nv] = v;
            nv += 1;
            expect_operand = false;
            continue;
        }
        if (c == '(') {
            if (no >= ops.len) return null;
            ops[no] = c;
            no += 1;
            i += 1;
            expect_operand = true;
            continue;
        }
        if (c == ')') {
            while (no > 0 and ops[no - 1] != '(') {
                if (nv < 2) return null;
                const b = values[nv - 1];
                const a = values[nv - 2];
                nv -= 2;
                values[nv] = applyOp(a, b, ops[no - 1]) orelse return null;
                nv += 1;
                no -= 1;
            }
            if (no == 0) return null;
            no -= 1;
            i += 1;
            expect_operand = false;
            continue;
        }
        if (c == '+' or c == '-' or c == '*' or c == '/' or c == '%' or c == '^') {
            if (expect_operand and (c == '*' or c == '/' or c == '%' or c == '^')) return null;
            while (no > 0 and ops[no - 1] != '(' and (precedence(ops[no - 1]) > precedence(c) or (precedence(ops[no - 1]) == precedence(c) and c != '^'))) {
                if (nv < 2) return null;
                const b = values[nv - 1];
                const a = values[nv - 2];
                nv -= 2;
                values[nv] = applyOp(a, b, ops[no - 1]) orelse return null;
                nv += 1;
                no -= 1;
            }
            if (no >= ops.len) return null;
            ops[no] = c;
            no += 1;
            i += 1;
            expect_operand = true;
            continue;
        }
        return null;
    }
    while (no > 0) {
        if (ops[no - 1] == '(') return null;
        if (nv < 2) return null;
        const b = values[nv - 1];
        const a = values[nv - 2];
        nv -= 2;
        values[nv] = applyOp(a, b, ops[no - 1]) orelse return null;
        nv += 1;
        no -= 1;
    }
    if (nv != 1) return null;
    return values[0];
}

test "seeker-math: precedence, parens, errors" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 14.0), evaluate("2+3*4").?);
    try t.expectEqual(@as(f64, 20.0), evaluate("(2+3)*4").?);
    try t.expectEqual(@as(f64, 512.0), evaluate("2^3^2").?);
    try t.expectEqual(@as(f64, -5.0), evaluate("-5").?);
    try t.expect(evaluate("1/0") == null);
    try t.expect(evaluate("2+") == null);
    try t.expect(evaluate("abc") == null);
    try t.expect(evaluate("(1+2") == null);
}
