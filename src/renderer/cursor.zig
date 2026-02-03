/// Cursor rendering types.
/// The actual rendering still lives in main.zig for now;
/// this module defines the shared types.

const Config = @import("../config.zig");

/// Cursor style as reported by the terminal (DECSCUSR escape sequence).
/// Matches ghostty's terminal/cursor.zig.
pub const TerminalCursorStyle = enum {
    bar,
    block,
    underline,
    block_hollow,
};

/// Result from rendering a cursor — tells the caller
/// whether to invert the foreground color of the cell.
pub const CursorRenderResult = struct {
    invert_fg: bool,
};
