/// A terminal surface — the core unit of Phantty.
/// Each Surface is a fully independent terminal session, owning a PTY,
/// terminal state machine, selection, and OSC title state.
///
/// Modeled after Ghostty's `src/Surface.zig`:
/// - Ghostty: Surface owns terminal, PTY, IO thread, renderer thread
/// - Phantty (Phase 1): Surface owns terminal, PTY, selection, OSC state
///   (IO thread added in Phase 2, renderer stays in main.zig for now)
///
/// TabState in main.zig becomes a thin wrapper: `{ surface: *Surface }`.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Pty = @import("pty.zig").Pty;
const renderer = @import("renderer.zig");
const Config = @import("config.zig");

const Surface = @This();

// ============================================================================
// Types
// ============================================================================

/// Selection state for text selection.
pub const Selection = struct {
    start_col: usize = 0,
    start_row: usize = 0,
    end_col: usize = 0,
    end_row: usize = 0,
    active: bool = false,
};

/// OSC parser state machine — handles sequences split across PTY reads.
const OscParseState = enum { ground, esc, osc_num, osc_semi, osc_title };

// ============================================================================
// Core state
// ============================================================================

terminal: ghostty_vt.Terminal,
pty: Pty,
selection: Selection,
render_state: renderer.State,

/// Dirty flag — set by IO thread (Phase 2), read by render loop.
/// For Phase 1 this is always effectively true (we render every frame).
dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

/// Set when the PTY process has exited.
exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

/// IO thread handle (null until Phase 2).
io_thread: ?std.Thread = null,

// ============================================================================
// OSC title fields
// ============================================================================

window_title: [256]u8 = undefined,
window_title_len: usize = 0,
osc_state: OscParseState = .ground,
osc_is_title: bool = false,
osc_num: u8 = 0,
osc_buf: [512]u8 = undefined,
osc_buf_len: usize = 0,
osc7_title: [256]u8 = undefined,
osc7_title_len: usize = 0,
got_osc7_this_batch: bool = false,

// ============================================================================
// Lifecycle
// ============================================================================

/// Initialize a new Surface with its own PTY and terminal.
pub fn init(
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    shell_cmd: [:0]const u16,
    scrollback_limit: u32,
    cursor_style: Config.CursorStyle,
    cursor_blink: bool,
) !*Surface {
    const surface = try allocator.create(Surface);
    errdefer allocator.destroy(surface);

    // Initialize terminal
    surface.terminal = ghostty_vt.Terminal.init(allocator, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = scrollback_limit,
    }) catch |err| {
        return err;
    };
    errdefer surface.terminal.deinit(allocator);

    // Set cursor style/blink from config
    surface.terminal.screens.active.cursor.cursor_style = switch (cursor_style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    surface.terminal.modes.set(.cursor_blinking, cursor_blink);

    // Spawn PTY
    surface.pty = Pty.spawn(cols, rows, shell_cmd) catch |err| {
        surface.terminal.deinit(allocator);
        return err;
    };

    // Init remaining fields
    surface.selection = .{};
    surface.render_state = renderer.State.init(&surface.terminal);
    surface.dirty = std.atomic.Value(bool).init(true);
    surface.exited = std.atomic.Value(bool).init(false);
    surface.io_thread = null;

    // Init OSC state
    surface.window_title_len = 0;
    surface.osc_state = .ground;
    surface.osc_is_title = false;
    surface.osc_num = 0;
    surface.osc_buf_len = 0;
    surface.osc7_title_len = 0;
    surface.got_osc7_this_batch = false;

    return surface;
}

/// Deinitialize and free a Surface.
pub fn deinit(self: *Surface, allocator: std.mem.Allocator) void {
    self.pty.deinit();
    self.terminal.deinit(allocator);
    allocator.destroy(self);
}

// ============================================================================
// Title
// ============================================================================

/// Get the display title for this surface.
pub fn getTitle(self: *const Surface) []const u8 {
    if (self.osc7_title_len > 0)
        return self.osc7_title[0..self.osc7_title_len];
    if (self.window_title_len > 0)
        return self.window_title[0..self.window_title_len];
    return "phantty";
}

/// Reset OSC batch state — call before each PTY read batch.
pub fn resetOscBatch(self: *Surface) void {
    self.got_osc7_this_batch = false;
}

/// Scan PTY output for OSC 0/1/2/7 title sequences.
/// Handles sequences split across multiple reads via state machine.
pub fn scanForOscTitle(self: *Surface, data: []const u8) void {
    for (data) |byte| {
        switch (self.osc_state) {
            .ground => {
                if (byte == 0x1b) {
                    self.osc_state = .esc;
                }
            },
            .esc => {
                if (byte == ']') {
                    self.osc_state = .osc_num;
                    self.osc_is_title = false;
                } else {
                    self.osc_state = .ground;
                }
            },
            .osc_num => {
                if (byte == '0' or byte == '1' or byte == '2' or byte == '7') {
                    self.osc_is_title = true;
                    self.osc_num = byte;
                    self.osc_state = .osc_semi;
                } else if (byte >= '0' and byte <= '9') {
                    self.osc_is_title = false;
                    self.osc_num = byte;
                    self.osc_state = .osc_semi;
                } else {
                    self.osc_state = .ground;
                }
            },
            .osc_semi => {
                if (byte == ';') {
                    if (self.osc_is_title) {
                        self.osc_buf_len = 0;
                        self.osc_state = .osc_title;
                    } else {
                        self.osc_state = .ground;
                    }
                } else if (byte >= '0' and byte <= '9') {
                    // Multi-digit OSC number, stay in osc_semi
                } else {
                    self.osc_state = .ground;
                }
            },
            .osc_title => {
                if (byte == 0x07) {
                    self.updateTitle(self.osc_buf[0..self.osc_buf_len], self.osc_num);
                    self.osc_state = .ground;
                } else if (byte == 0x1b) {
                    self.updateTitle(self.osc_buf[0..self.osc_buf_len], self.osc_num);
                    self.osc_state = .esc;
                } else if (self.osc_buf_len < self.osc_buf.len) {
                    self.osc_buf[self.osc_buf_len] = byte;
                    self.osc_buf_len += 1;
                }
            },
        }
    }
}

/// Map known shell executable paths/titles to friendly display names.
fn shellFriendlyName(title: []const u8) []const u8 {
    var lower_buf: [512]u8 = undefined;
    const len = @min(title.len, lower_buf.len);
    for (0..len) |i| {
        lower_buf[i] = if (title[i] >= 'A' and title[i] <= 'Z') title[i] + 32 else title[i];
    }
    const lower = lower_buf[0..len];

    if (std.mem.indexOf(u8, lower, "powershell.exe") != null) return "Windows PowerShell";
    if (std.mem.indexOf(u8, lower, "pwsh.exe") != null) return "PowerShell";
    if (std.mem.indexOf(u8, lower, "powershell") != null and
        std.mem.indexOf(u8, lower, ".exe") == null) return "Windows PowerShell";
    if (std.mem.indexOf(u8, lower, "pwsh") != null and
        std.mem.indexOf(u8, lower, ".exe") == null) return "PowerShell";
    if (std.mem.indexOf(u8, lower, "cmd.exe") != null) return "Command Prompt";
    if (std.mem.eql(u8, lower, "cmd")) return "Command Prompt";

    return title;
}

/// Update the surface title from an OSC sequence.
fn updateTitle(self: *Surface, title: []const u8, osc_num: u8) void {
    if (title.len == 0) return;

    if (osc_num == '7') {
        // OSC 7: file://host/path — extract the path
        self.got_osc7_this_batch = true;
        const prefix = "file://";
        if (std.mem.startsWith(u8, title, prefix)) {
            const after_prefix = title[prefix.len..];
            if (std.mem.indexOfScalar(u8, after_prefix, '/')) |slash| {
                const path = after_prefix[slash..];

                const home_prefix = "/home/";
                if (std.mem.startsWith(u8, path, home_prefix)) {
                    const after_home = path[home_prefix.len..];
                    const user_end = std.mem.indexOfScalar(u8, after_home, '/') orelse after_home.len;
                    const home_len = home_prefix.len + user_end;

                    const rest = path[home_len..];
                    self.osc7_title[0] = '~';
                    const rest_len = @min(rest.len, self.osc7_title.len - 1);
                    @memcpy(self.osc7_title[1 .. 1 + rest_len], rest[0..rest_len]);
                    self.osc7_title_len = 1 + rest_len;
                } else {
                    const path_len = @min(path.len, self.osc7_title.len);
                    @memcpy(self.osc7_title[0..path_len], path[0..path_len]);
                    self.osc7_title_len = path_len;
                }
            }
        }
    } else {
        // OSC 0/1/2 — skip if we already got OSC 7 in this same batch
        if (self.got_osc7_this_batch) return;

        const friendly = shellFriendlyName(title);

        // Accept and clear OSC 7 cache
        self.osc7_title_len = 0;
        const friendly_len = @min(friendly.len, self.window_title.len);
        @memcpy(self.window_title[0..friendly_len], friendly[0..friendly_len]);
        self.window_title_len = friendly_len;
    }
}
