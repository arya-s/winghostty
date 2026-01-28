//! Braille Patterns | U+2800...U+28FF
//! https://en.wikipedia.org/wiki/Braille_Patterns
//!
//! Braille patterns are 8-dot patterns arranged in a 2x4 grid.
//! The codepoint encodes which dots are filled as a bitmask.
//!
//! Dot positions:
//!   1  4     (top)
//!   2  5     (upper)
//!   3  6     (lower)
//!   7  8     (bottom)
//!
//! Based on Ghostty's braille.zig implementation.

const std = @import("std");
const canvas_mod = @import("../canvas.zig");
const Canvas = canvas_mod.Canvas;
const Color = canvas_mod.Color;
const Metrics = @import("common.zig").Metrics;

/// A braille pattern - matches bit layout of Unicode codepoints.
///
/// Mnemonic:
/// [t]op    - .       .
/// [u]pper  - .       .
/// [l]ower  - .       .
/// [b]ottom - .       .
///            |       |
///           [l]eft, [r]ight
const Pattern = packed struct(u8) {
    tl: bool, // bit 0: top-left (dot 1)
    ul: bool, // bit 1: upper-left (dot 2)
    ll: bool, // bit 2: lower-left (dot 3)
    tr: bool, // bit 3: top-right (dot 4)
    ur: bool, // bit 4: upper-right (dot 5)
    lr: bool, // bit 5: lower-right (dot 6)
    bl: bool, // bit 6: bottom-left (dot 7)
    br: bool, // bit 7: bottom-right (dot 8)

    fn from(cp: u32) Pattern {
        return @bitCast(@as(u8, @truncate(cp)));
    }
};

/// Draw a braille pattern (U+2800-U+28FF)
pub fn draw(cp: u32, canvas: *Canvas, metrics: Metrics) void {
    const width = metrics.cell_width;
    const height = metrics.cell_height;

    // Calculate dot size and spacing
    // We want 2 columns and 4 rows of dots with margins and spacing
    var w: i32 = @intCast(@min(width / 4, height / 8));
    var x_spacing: i32 = @intCast(width / 4);
    var y_spacing: i32 = @intCast(height / 8);
    var x_margin: i32 = @divFloor(x_spacing, 2);
    var y_margin: i32 = @divFloor(y_spacing, 2);

    var x_px_left: i32 =
        @as(i32, @intCast(width)) - 2 * x_margin - x_spacing - 2 * w;

    var y_px_left: i32 =
        @as(i32, @intCast(height)) - 2 * y_margin - 3 * y_spacing - 4 * w;

    // First, try hard to ensure the DOT width is non-zero
    if (x_px_left >= 2 and y_px_left >= 4 and w == 0) {
        w += 1;
        x_px_left -= 2;
        y_px_left -= 4;
    }

    // Second, prefer a non-zero margin
    if (x_px_left >= 2 and x_margin == 0) {
        x_margin = 1;
        x_px_left -= 2;
    }
    if (y_px_left >= 2 and y_margin == 0) {
        y_margin = 1;
        y_px_left -= 2;
    }

    // Third, increase spacing
    if (x_px_left >= 1) {
        x_spacing += 1;
        x_px_left -= 1;
    }
    if (y_px_left >= 3) {
        y_spacing += 1;
        y_px_left -= 3;
    }

    // Fourth, margins ("spacing", but on the sides)
    if (x_px_left >= 2) {
        x_margin += 1;
        x_px_left -= 2;
    }
    if (y_px_left >= 2) {
        y_margin += 1;
        y_px_left -= 2;
    }

    // Last - increase dot width
    if (x_px_left >= 2 and y_px_left >= 4) {
        w += 1;
        x_px_left -= 2;
        y_px_left -= 4;
    }

    // Calculate positions for the 2 columns
    const x = [2]i32{ x_margin, x_margin + w + x_spacing };

    // Calculate positions for the 4 rows
    const y = blk: {
        var y_arr: [4]i32 = undefined;
        y_arr[0] = y_margin;
        y_arr[1] = y_arr[0] + w + y_spacing;
        y_arr[2] = y_arr[1] + w + y_spacing;
        y_arr[3] = y_arr[2] + w + y_spacing;
        break :blk y_arr;
    };

    // Decode the pattern from the codepoint
    const p: Pattern = Pattern.from(cp);

    // Draw the dots that are set (using box which takes x0,y0,x1,y1)
    const color = Color.on;
    if (p.tl) canvas.box(x[0], y[0], x[0] + w, y[0] + w, color);
    if (p.ul) canvas.box(x[0], y[1], x[0] + w, y[1] + w, color);
    if (p.ll) canvas.box(x[0], y[2], x[0] + w, y[2] + w, color);
    if (p.bl) canvas.box(x[0], y[3], x[0] + w, y[3] + w, color);
    if (p.tr) canvas.box(x[1], y[0], x[1] + w, y[0] + w, color);
    if (p.ur) canvas.box(x[1], y[1], x[1] + w, y[1] + w, color);
    if (p.lr) canvas.box(x[1], y[2], x[1] + w, y[2] + w, color);
    if (p.br) canvas.box(x[1], y[3], x[1] + w, y[3] + w, color);
}
