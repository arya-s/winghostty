const std = @import("std");
const build_options = @import("build_options");
const ghostty_vt = @import("ghostty-vt");
const freetype = @import("freetype");
const Pty = @import("pty.zig").Pty;
const sprite = @import("font/sprite.zig");
const directwrite = @import("directwrite.zig");
const Config = @import("config.zig");
const win32_backend = if (build_options.use_win32) @import("win32.zig") else struct {};

const c = @cImport({
    @cInclude("glad/gl.h");
    if (!build_options.use_win32) {
        @cInclude("GLFW/glfw3.h");
    }
});

// Type aliases from config module
const Color = Config.Color;
const Theme = Config.Theme;
const CursorStyle = Config.CursorStyle;
const hexToColor = Config.hexToColor;
const parseColor = Config.parseColor;

// Global theme (set at startup via config)
var g_theme: Theme = Theme.default();

/// Convert FreeType 26.6 fixed-point to f64 (like Ghostty)
fn f26dot6ToF64(v: anytype) f64 {
    return @as(f64, @floatFromInt(v)) / 64.0;
}

// ============================================================================
// Font Discovery Test Functions (use --list-fonts or --test-font-discovery)
// ============================================================================

fn listSystemFonts(allocator: std.mem.Allocator) !void {
    std.debug.print("Listing system fonts via DirectWrite...\n\n", .{});

    var dw = directwrite.FontDiscovery.init() catch |err| {
        std.debug.print("Failed to initialize DirectWrite: {}\n", .{err});
        return err;
    };
    defer dw.deinit();

    const families = try dw.listFontFamilies(allocator);
    defer {
        for (families) |f| allocator.free(f);
        allocator.free(families);
    }

    std.debug.print("Found {} font families:\n", .{families.len});
    for (families, 0..) |family, i| {
        std.debug.print("  {d:4}. {s}\n", .{ i + 1, family });
    }
}

fn testFontDiscovery(allocator: std.mem.Allocator) !void {
    std.debug.print("Testing font discovery...\n\n", .{});

    var dw = directwrite.FontDiscovery.init() catch |err| {
        std.debug.print("Failed to initialize DirectWrite: {}\n", .{err});
        return err;
    };
    defer dw.deinit();

    // Test fonts to look for
    const test_fonts = [_][]const u8{
        "JetBrains Mono",
        "Cascadia Code",
        "Consolas",
        "Courier New",
        "Arial",
        "Segoe UI",
        "NonExistentFont12345",
    };

    for (test_fonts) |font_name| {
        std.debug.print("Looking for '{s}'... ", .{font_name});

        if (dw.findFontFilePath(allocator, font_name, .NORMAL, .NORMAL)) |maybe_result| {
            if (maybe_result) |result| {
                var r = result;
                defer r.deinit();
                std.debug.print("FOUND\n", .{});
                std.debug.print("  Path: {s}\n", .{result.path});
                std.debug.print("  Face index: {}\n\n", .{result.face_index});
            } else {
                std.debug.print("NOT FOUND\n\n", .{});
            }
        } else |err| {
            std.debug.print("ERROR: {}\n\n", .{err});
        }
    }
}

// Global pointers for callbacks
var g_window: if (build_options.use_win32) ?*win32_backend.Window else ?*c.GLFWwindow = null;
var g_allocator: ?std.mem.Allocator = null;

// Selection state (per-tab)
const Selection = struct {
    start_col: usize = 0,
    start_row: usize = 0,
    end_col: usize = 0,
    end_row: usize = 0,
    active: bool = false,
};

var g_should_close: bool = false; // Set by Ctrl+W with 1 tab
var g_selecting: bool = false; // True while mouse button is held
var g_click_x: f64 = 0; // X position of initial click (for threshold calculation)
var g_click_y: f64 = 0; // Y position of initial click

// ============================================================================
// Tab model — each tab owns its own PTY, terminal, and OSC state
// ============================================================================

// OSC parser state machine — handles sequences split across PTY reads
const OscParseState = enum { ground, esc, osc_num, osc_semi, osc_title };

const TabState = struct {
    pty: Pty,
    terminal: ghostty_vt.Terminal,
    selection: Selection,

    // Per-tab OSC title state
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

    /// Get the display title for this tab
    fn getTitle(self: *const TabState) []const u8 {
        if (self.osc7_title_len > 0)
            return self.osc7_title[0..self.osc7_title_len];
        if (self.window_title_len > 0)
            return self.window_title[0..self.window_title_len];
        return "phantty";
    }

    fn deinit(self: *TabState, allocator: std.mem.Allocator) void {
        self.pty.deinit();
        self.terminal.deinit(allocator);
    }
};

const MAX_TABS = 16;
var g_tabs: [MAX_TABS]?*TabState = .{null} ** MAX_TABS;
var g_tab_count: usize = 0;
var g_active_tab: usize = 0;

// Global shell command for spawning new tabs (set once at startup from config)
var g_shell_cmd_buf: [256]u16 = undefined;
var g_shell_cmd_len: usize = 0;
var g_scrollback_limit: u32 = 10_000_000;

fn getShellCmd() [:0]const u16 {
    return g_shell_cmd_buf[0..g_shell_cmd_len :0];
}

/// Get the active tab's PTY, or null
fn activePty() ?*Pty {
    if (g_tab_count == 0) return null;
    const tab = g_tabs[g_active_tab] orelse return null;
    return &tab.pty;
}

/// Get the active tab's terminal, or null
fn activeTerminal() ?*ghostty_vt.Terminal {
    if (g_tab_count == 0) return null;
    const tab = g_tabs[g_active_tab] orelse return null;
    return &tab.terminal;
}

/// Get the active tab's selection
fn activeSelection() *Selection {
    if (g_tab_count > 0) {
        if (g_tabs[g_active_tab]) |tab| {
            return &tab.selection;
        }
    }
    // Fallback — should never happen in practice
    const S = struct {
        var dummy: Selection = .{};
    };
    return &S.dummy;
}

/// Scan PTY output for OSC 0 / OSC 2 title sequences (per-tab).
/// Handles sequences split across multiple reads via state machine.
fn scanForOscTitle(tab: *TabState, data: []const u8) void {
    for (data) |byte| {
        switch (tab.osc_state) {
            .ground => {
                if (byte == 0x1b) {
                    tab.osc_state = .esc;
                }
            },
            .esc => {
                if (byte == ']') {
                    tab.osc_state = .osc_num;
                    tab.osc_is_title = false;
                } else {
                    tab.osc_state = .ground;
                }
            },
            .osc_num => {
                if (byte == '0' or byte == '1' or byte == '2' or byte == '7') {
                    tab.osc_is_title = true;
                    tab.osc_num = byte;
                    tab.osc_state = .osc_semi;
                } else if (byte >= '0' and byte <= '9') {
                    tab.osc_is_title = false;
                    tab.osc_num = byte;
                    tab.osc_state = .osc_semi;
                } else {
                    tab.osc_state = .ground;
                }
            },
            .osc_semi => {
                if (byte == ';') {
                    if (tab.osc_is_title) {
                        tab.osc_buf_len = 0;
                        tab.osc_state = .osc_title;
                    } else {
                        tab.osc_state = .ground;
                    }
                } else if (byte >= '0' and byte <= '9') {
                    // Multi-digit OSC number, stay in osc_semi
                } else {
                    tab.osc_state = .ground;
                }
            },
            .osc_title => {
                if (byte == 0x07) {
                    updateTabTitle(tab, tab.osc_buf[0..tab.osc_buf_len], tab.osc_num);
                    tab.osc_state = .ground;
                } else if (byte == 0x1b) {
                    updateTabTitle(tab, tab.osc_buf[0..tab.osc_buf_len], tab.osc_num);
                    tab.osc_state = .esc;
                } else if (tab.osc_buf_len < tab.osc_buf.len) {
                    tab.osc_buf[tab.osc_buf_len] = byte;
                    tab.osc_buf_len += 1;
                }
            },
        }
    }
}

/// OSC 7 gives us a reliable CWD. OSC 0/1/2 give us whatever the shell sets.
/// Within the same PTY read batch, OSC 7 wins over 0/1/2 (OMZ sends truncated
/// OSC 0 after the full OSC 7). Between batches, any new title is accepted.
var g_osc7_title: [256]u8 = undefined;
var g_osc7_title_len: usize = 0;
var g_got_osc7_this_batch: bool = false;

/// Map known shell executable paths/titles to friendly display names.
/// Windows Terminal does the same — "Windows PowerShell", "Command Prompt", etc.
fn shellFriendlyName(title: []const u8) []const u8 {
    // Case-insensitive check helpers
    const lower_buf = blk: {
        var buf: [512]u8 = undefined;
        const len = @min(title.len, buf.len);
        for (0..len) |i| {
            buf[i] = if (title[i] >= 'A' and title[i] <= 'Z') title[i] + 32 else title[i];
        }
        break :blk buf[0..len];
    };

    // PowerShell (Windows PowerShell or pwsh)
    if (std.mem.indexOf(u8, lower_buf, "powershell.exe") != null) return "Windows PowerShell";
    if (std.mem.indexOf(u8, lower_buf, "pwsh.exe") != null) return "PowerShell";
    if (std.mem.indexOf(u8, lower_buf, "powershell") != null and
        std.mem.indexOf(u8, lower_buf, ".exe") == null) return "Windows PowerShell";
    if (std.mem.indexOf(u8, lower_buf, "pwsh") != null and
        std.mem.indexOf(u8, lower_buf, ".exe") == null) return "PowerShell";

    // Command Prompt
    if (std.mem.indexOf(u8, lower_buf, "cmd.exe") != null) return "Command Prompt";
    if (std.mem.eql(u8, lower_buf, "cmd")) return "Command Prompt";

    // Return original title if no match
    return title;
}

fn resetOscBatch(tab: *TabState) void {
    tab.got_osc7_this_batch = false;
}

fn updateTabTitle(tab: *TabState, title: []const u8, osc_num: u8) void {
    if (title.len == 0) return;

    if (osc_num == '7') {
        // OSC 7: file://host/path — extract the path, replace /home/<user> with ~
        tab.got_osc7_this_batch = true;
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
                    tab.osc7_title[0] = '~';
                    const rest_len = @min(rest.len, tab.osc7_title.len - 1);
                    @memcpy(tab.osc7_title[1 .. 1 + rest_len], rest[0..rest_len]);
                    tab.osc7_title_len = 1 + rest_len;
                } else {
                    const len = @min(path.len, tab.osc7_title.len);
                    @memcpy(tab.osc7_title[0..len], path[0..len]);
                    tab.osc7_title_len = len;
                }
            }
        }
    } else {
        // OSC 0/1/2 — skip if we already got OSC 7 in this same batch
        if (tab.got_osc7_this_batch) return;

        // Map known shell paths/titles to friendly names
        const friendly = shellFriendlyName(title);

        // Accept and clear OSC 7 cache (new shell may not send OSC 7)
        tab.osc7_title_len = 0;
        const len = @min(friendly.len, tab.window_title.len);
        @memcpy(tab.window_title[0..len], friendly[0..len]);
        tab.window_title_len = len;
    }
}

/// Spawn a new tab with its own PTY + terminal instance.
/// Called for both the initial tab and Ctrl+Shift+T.
fn spawnTab(allocator: std.mem.Allocator) bool {
    if (g_tab_count >= MAX_TABS) return false;

    // Allocate TabState on the heap so pointers stay stable when tabs shift
    const tab = allocator.create(TabState) catch {
        std.debug.print("Failed to allocate TabState\n", .{});
        return false;
    };

    // Initialize terminal
    tab.terminal = ghostty_vt.Terminal.init(allocator, .{
        .cols = term_cols,
        .rows = term_rows,
        .max_scrollback = g_scrollback_limit,
    }) catch {
        std.debug.print("Failed to init terminal for new tab\n", .{});
        allocator.destroy(tab);
        return false;
    };

    // Set cursor style/blink from config
    tab.terminal.screens.active.cursor.cursor_style = switch (g_cursor_style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    tab.terminal.modes.set(.cursor_blinking, g_cursor_blink);

    // Spawn PTY
    tab.pty = Pty.spawn(term_cols, term_rows, getShellCmd()) catch {
        std.debug.print("Failed to spawn PTY for new tab\n", .{});
        tab.terminal.deinit(allocator);
        allocator.destroy(tab);
        return false;
    };

    // Init per-tab state
    tab.selection = .{};
    tab.window_title_len = 0;
    tab.osc_state = .ground;
    tab.osc_is_title = false;
    tab.osc_num = 0;
    tab.osc_buf_len = 0;
    tab.osc7_title_len = 0;
    tab.got_osc7_this_batch = false;

    g_tabs[g_tab_count] = tab;
    g_active_tab = g_tab_count;
    g_tab_count += 1;

    // Clear selection state when switching to new tab
    g_selecting = false;

    std.debug.print("New tab spawned (count={}), active: {}\n", .{ g_tab_count, g_active_tab });
    return true;
}

fn closeTab(idx: usize) void {
    if (g_tab_count <= 1) return; // last tab closed via g_should_close instead
    if (idx >= g_tab_count) return;

    const allocator = g_allocator orelse return;

    // Deinit and free the tab
    if (g_tabs[idx]) |tab| {
        tab.deinit(allocator);
        allocator.destroy(tab);
    }

    // Shift tabs down
    var i = idx;
    while (i + 1 < g_tab_count) : (i += 1) {
        g_tabs[i] = g_tabs[i + 1];
    }
    g_tabs[g_tab_count - 1] = null;
    g_tab_count -= 1;

    // Adjust active tab index
    if (g_active_tab == idx) {
        if (g_active_tab >= g_tab_count) {
            g_active_tab = g_tab_count - 1;
        }
    } else if (g_active_tab > idx) {
        g_active_tab -= 1;
    }

    // Clear selection state when tab changes
    g_selecting = false;
}

fn switchTab(idx: usize) void {
    if (idx < g_tab_count) {
        g_active_tab = idx;
        // Clear selection state when switching tabs
        g_selecting = false;
    }
}

fn isActiveTabTerminal() bool {
    if (g_tab_count == 0) return false;
    return g_tabs[g_active_tab] != null;
}

/// Get the active tab, or null
fn activeTab() ?*TabState {
    if (g_tab_count == 0) return null;
    return g_tabs[g_active_tab];
}

// Embed the font
// Embedded fallback font (JetBrains Mono, like Ghostty)
const embedded = @import("font/embedded.zig");

// Terminal dimensions (initial, will be updated on resize)
// Defaults match Ghostty's default of 0 (auto-size), but we set
// reasonable defaults since we don't auto-detect screen size.
var term_cols: u16 = 80;
var term_rows: u16 = 24;
const DEFAULT_FONT_SIZE: u32 = 14;

// OpenGL context from glad
var gl: c.GladGLContext = undefined;

const Character = struct {
    texture_id: c.GLuint,
    size_x: i32,
    size_y: i32,
    bearing_x: i32,
    bearing_y: i32,
    advance: i64,
    valid: bool = false,
};

// Glyph cache using a hashmap for Unicode support
var glyph_cache: std.AutoHashMapUnmanaged(u32, Character) = .empty;
var glyph_face: ?freetype.Face = null;
var icon_face: ?freetype.Face = null; // Segoe MDL2 Assets for caption button icons
var icon_cache: std.AutoHashMapUnmanaged(u32, Character) = .empty;
var vao: c.GLuint = 0;
var vbo: c.GLuint = 0;
var shader_program: c.GLuint = 0;
var cell_width: f32 = 10;
var cell_height: f32 = 20;
var cell_baseline: f32 = 4; // Distance from bottom of cell to baseline
var cursor_height: f32 = 16; // Height of cursor (ascender portion)
var box_thickness: u32 = 1; // Thickness for box drawing characters
var window_focused: bool = true; // Track window focus state

// Fullscreen state (Alt+Enter to toggle)
var g_is_fullscreen: bool = false;
var g_windowed_x: c_int = 0; // Saved windowed position/size for restore
var g_windowed_y: c_int = 0;
var g_windowed_width: c_int = 800;
var g_windowed_height: c_int = 600;

// Post-processing custom shader (Ghostty-compatible)
var g_post_fbo: c.GLuint = 0; // Framebuffer object for off-screen render
var g_post_texture: c.GLuint = 0; // Color attachment texture
var g_post_program: c.GLuint = 0; // Post-processing shader program
var g_post_vao: c.GLuint = 0; // Fullscreen quad VAO
var g_post_vbo: c.GLuint = 0; // Fullscreen quad VBO
var g_post_enabled: bool = false; // Whether custom shader is active
var g_post_fb_width: c_int = 0; // Current FBO texture dimensions
var g_post_fb_height: c_int = 0;
var g_frame_count: u32 = 0; // Frame counter for iFrame
var g_start_time: i64 = 0; // Start time for iTime

// Pending resize state (resize is deferred to main loop to avoid PageList integrity issues)
// Ghostty coalesces resize events with a 25ms timer to batch rapid resizes
var g_pending_resize: bool = false;
var g_pending_cols: u16 = 0;
var g_pending_rows: u16 = 0;
var g_last_resize_time: i64 = 0;
var g_resize_in_progress: bool = false; // Prevent rendering during resize
const RESIZE_COALESCE_MS: i64 = 25; // Same as Ghostty

var g_cursor_style: CursorStyle = .block; // Default cursor style
var g_cursor_blink: bool = true; // Whether cursor should blink (default: true like Ghostty)
var g_cursor_blink_visible: bool = true; // Current blink state (toggled by timer)
var g_last_blink_time: i64 = 0; // Timestamp of last blink toggle
const CURSOR_BLINK_INTERVAL_MS: i64 = 600; // Blink interval in ms (same as Ghostty)

const ConfigWatcher = @import("config_watcher.zig");

// Font fallback system
var g_ft_lib: ?freetype.Library = null;
var g_font_discovery: ?*directwrite.FontDiscovery = null;
var g_fallback_faces: std.AutoHashMapUnmanaged(u32, freetype.Face) = .empty; // codepoint -> fallback face
var g_font_size: u32 = DEFAULT_FONT_SIZE;

const vertex_shader_source: [*c]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec4 vertex;
    \\out vec2 TexCoords;
    \\uniform mat4 projection;
    \\void main() {
    \\    gl_Position = projection * vec4(vertex.xy, 0.0, 1.0);
    \\    TexCoords = vertex.zw;
    \\}
;

const fragment_shader_source: [*c]const u8 =
    \\#version 330 core
    \\in vec2 TexCoords;
    \\out vec4 color;
    \\uniform sampler2D text;
    \\uniform vec3 textColor;
    \\void main() {
    \\    vec4 sampled = vec4(1.0, 1.0, 1.0, texture(text, TexCoords).r);
    \\    color = vec4(textColor, 1.0) * sampled;
    \\}
;

fn compileShader(shader_type: c.GLenum, source: [*c]const u8) ?c.GLuint {
    const shader = gl.CreateShader.?(shader_type);
    if (shader == 0) {
        const gl_err = if (gl.GetError) |getErr| getErr() else 0;
        std.debug.print("Shader error: glCreateShader returned 0, type=0x{X}, glError=0x{X}\n", .{ shader_type, gl_err });
        return null;
    }

    gl.ShaderSource.?(shader, 1, &source, null);
    gl.CompileShader.?(shader);

    var success: c.GLint = 0;
    gl.GetShaderiv.?(shader, c.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = @splat(0);
        var log_len: c.GLsizei = 0;
        gl.GetShaderInfoLog.?(shader, 512, &log_len, &info_log);
        const len: usize = if (log_len > 0) @intCast(log_len) else 0;
        if (len > 0) {
            std.debug.print("Shader compilation failed: {s}\n", .{info_log[0..len]});
        } else {
            std.debug.print("Shader compilation failed (no error log, shader={})\n", .{shader});
        }
        return null;
    }
    return shader;
}

fn initShaders() bool {
    const vertex_shader = compileShader(c.GL_VERTEX_SHADER, vertex_shader_source) orelse return false;
    defer gl.DeleteShader.?(vertex_shader);

    const fragment_shader = compileShader(c.GL_FRAGMENT_SHADER, fragment_shader_source) orelse return false;
    defer gl.DeleteShader.?(fragment_shader);

    shader_program = gl.CreateProgram.?();
    gl.AttachShader.?(shader_program, vertex_shader);
    gl.AttachShader.?(shader_program, fragment_shader);
    gl.LinkProgram.?(shader_program);

    var success: c.GLint = 0;
    gl.GetProgramiv.?(shader_program, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = @splat(0);
        var log_len: c.GLsizei = 0;
        gl.GetProgramInfoLog.?(shader_program, 512, &log_len, &info_log);
        const len: usize = if (log_len > 0) @intCast(log_len) else 0;
        if (len > 0) {
            std.debug.print("Shader linking failed: {s}\n", .{info_log[0..len]});
        } else {
            std.debug.print("Shader linking failed (no error log available)\n", .{});
        }
        return false;
    }

    return true;
}

fn initBuffers() void {
    gl.GenVertexArrays.?(1, &vao);
    gl.GenBuffers.?(1, &vbo);
    gl.BindVertexArray.?(vao);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(f32) * 6 * 4, null, c.GL_DYNAMIC_DRAW);
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 4, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), null);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.BindVertexArray.?(0);
}

/// Load a single glyph into the cache
fn loadGlyph(codepoint: u32) ?Character {
    // Check if already cached
    if (glyph_cache.get(codepoint)) |ch| {
        return ch;
    }

    const alloc = g_allocator orelse return null;

    // Try sprite rendering first for special characters
    if (sprite.isSprite(codepoint)) {
        if (loadSpriteGlyph(codepoint, alloc)) |char_data| {
            glyph_cache.put(alloc, codepoint, char_data) catch return null;
            return char_data;
        }
    }

    // Fall back to FreeType font rendering
    const primary_face = glyph_face orelse return null;

    // Get glyph index for this codepoint from primary font
    var glyph_index = primary_face.getCharIndex(codepoint) orelse 0;
    var face_to_use = primary_face;

    // If glyph is missing (index 0), try to find a fallback font
    if (glyph_index == 0) {
        if (findOrLoadFallbackFace(codepoint, alloc)) |fallback| {
            const fallback_index = fallback.getCharIndex(codepoint) orelse 0;
            if (fallback_index != 0) {
                glyph_index = fallback_index;
                face_to_use = fallback;
            }
        }
    }

    // Use light hinting like Ghostty (matches most fontconfig-aware software)
    face_to_use.loadGlyph(@intCast(glyph_index), .{ .target = .light }) catch return null;
    face_to_use.renderGlyph(.light) catch return null;

    const glyph = face_to_use.handle.*.glyph;
    const bitmap = glyph.*.bitmap;

    var texture: c.GLuint = 0;
    gl.GenTextures.?(1, &texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, texture);
    gl.TexImage2D.?(
        c.GL_TEXTURE_2D,
        0,
        c.GL_RED,
        @intCast(bitmap.width),
        @intCast(bitmap.rows),
        0,
        c.GL_RED,
        c.GL_UNSIGNED_BYTE,
        bitmap.buffer,
    );
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);

    const char_data = Character{
        .texture_id = texture,
        .size_x = @intCast(bitmap.width),
        .size_y = @intCast(bitmap.rows),
        .bearing_x = glyph.*.bitmap_left,
        .bearing_y = glyph.*.bitmap_top,
        .advance = glyph.*.advance.x,
        .valid = true,
    };

    // Store in cache
    glyph_cache.put(alloc, codepoint, char_data) catch return null;

    return char_data;
}

/// Find or load a fallback font that contains the given codepoint
fn findOrLoadFallbackFace(codepoint: u32, alloc: std.mem.Allocator) ?freetype.Face {
    // Check if we already have a fallback for this codepoint
    if (g_fallback_faces.get(codepoint)) |face| {
        return face;
    }

    // Need DirectWrite and FreeType library to find fallbacks
    const dw = g_font_discovery orelse return null;
    const ft_lib = g_ft_lib orelse return null;

    // Use DirectWrite to find a font with this codepoint
    const maybe_font = dw.findFallbackFont(codepoint) catch return null;
    const font = maybe_font orelse return null;
    defer font.release();

    // Get the font face to extract file path
    const dw_face = font.createFontFace() catch return null;
    defer dw_face.release();

    // Get font file
    const font_file = dw_face.getFiles() catch return null;
    defer font_file.release();

    // Get file loader
    const loader = font_file.getLoader() catch return null;
    defer loader.release();

    // Get local font file loader
    const local_loader = loader.queryLocalFontFileLoader() orelse return null;
    defer local_loader.release();

    // Get reference key
    const ref_key = font_file.getReferenceKey() catch return null;

    // Get path length
    const path_len = local_loader.getFilePathLengthFromKey(ref_key.key, ref_key.size) catch return null;

    // Allocate buffer for path
    var path_buf = alloc.alloc(u16, path_len + 1) catch return null;
    defer alloc.free(path_buf);

    // Get the path
    local_loader.getFilePathFromKey(ref_key.key, ref_key.size, path_buf) catch return null;

    // Convert to UTF-8
    const utf8_path = std.unicode.utf16LeToUtf8AllocZ(alloc, path_buf[0..path_len]) catch return null;
    defer alloc.free(utf8_path);

    const face_index = dw_face.getIndex();

    std.debug.print("Loading fallback font for U+{X:0>4}: {s}\n", .{ codepoint, utf8_path });

    // Load with FreeType
    const ft_face = ft_lib.initFace(utf8_path, @intCast(face_index)) catch return null;

    // Set size to match primary font
    ft_face.setCharSize(0, @as(i32, @intCast(g_font_size)) * 64, 96, 96) catch {
        ft_face.deinit();
        return null;
    };

    // Cache the fallback face for this codepoint
    g_fallback_faces.put(alloc, codepoint, ft_face) catch {
        ft_face.deinit();
        return null;
    };

    return ft_face;
}

/// Load a sprite glyph (box drawing, powerline, etc.)
fn loadSpriteGlyph(codepoint: u32, alloc: std.mem.Allocator) ?Character {
    const metrics = sprite.Metrics{
        .cell_width = @intFromFloat(cell_width),
        .cell_height = @intFromFloat(cell_height),
        .box_thickness = box_thickness,
    };

    var result = sprite.renderSprite(alloc, codepoint, metrics) catch return null;
    if (result == null) return null;

    defer result.?.deinit();

    const r = result.?;

    // Extract only the trimmed region for the texture (like Ghostty's writeAtlas)
    // We need to copy row by row since the trimmed region is smaller than the surface
    var trimmed_data = alloc.alloc(u8, r.width * r.height) catch return null;
    defer alloc.free(trimmed_data);

    const src_stride = r.surface_width;
    for (0..r.height) |y| {
        const src_y = y + r.clip_top;
        const src_start = src_y * src_stride + r.clip_left;
        const dst_start = y * r.width;
        @memcpy(trimmed_data[dst_start..][0..r.width], r.data[src_start..][0..r.width]);
    }

    // Create OpenGL texture from trimmed sprite data
    var texture: c.GLuint = 0;
    gl.GenTextures.?(1, &texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, texture);
    gl.TexImage2D.?(
        c.GL_TEXTURE_2D,
        0,
        c.GL_RED,
        @intCast(r.width),
        @intCast(r.height),
        0,
        c.GL_RED,
        c.GL_UNSIGNED_BYTE,
        trimmed_data.ptr,
    );
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);

    // Calculate glyph offsets like Ghostty does:
    // Ghostty: offset_x = clip_left - padding_x  
    // Ghostty: offset_y = region.height + clip_bottom - padding_y
    //
    // Ghostty's offset_y is the distance from cell BOTTOM to glyph TOP.
    // 
    // Our renderChar formula: y0 = y + cell_baseline - (size_y - bearing_y)
    //                         glyph_top = y0 + size_y = y + cell_baseline + bearing_y
    //
    // We want glyph_top = y + offset_y (cell bottom + distance to glyph top)
    // So: y + cell_baseline + bearing_y = y + offset_y
    // Thus: bearing_y = offset_y - cell_baseline
    const offset_x: i32 = @as(i32, @intCast(r.clip_left)) - @as(i32, @intCast(r.padding_x));
    var offset_y: i32 = @as(i32, @intCast(r.height + r.clip_bottom)) - @as(i32, @intCast(r.padding_y));
    const baseline_i: i32 = @intFromFloat(cell_baseline);

    // For braille (no trim, no padding), offset_y = cell_height, meaning glyph top = cell top.
    // But braille should sit ON the baseline like text, not fill from cell top.
    // Experimentally: subtracting full baseline (6) is too low, 0 is too high.
    // Try half the baseline as a compromise.
    if (codepoint >= 0x2800 and codepoint <= 0x28FF) {
        offset_y -= @divFloor(baseline_i, 2);
    }

    const bearing_y = offset_y - baseline_i;

    return Character{
        .texture_id = texture,
        .size_x = @intCast(r.width),
        .size_y = @intCast(r.height),
        .bearing_x = offset_x,
        .bearing_y = bearing_y,
        .advance = @as(i64, @intCast(r.cell_width)) << 6, // Cell width in 26.6 fixed point
        .valid = true,
    };
}

/// Preload common character ranges
fn preloadCharacters(face: freetype.Face) void {
    gl.PixelStorei.?(c.GL_UNPACK_ALIGNMENT, 1);

    // Store face for later on-demand loading
    glyph_face = face;

    std.debug.print("Starting glyph preload, g_allocator set: {}\n", .{g_allocator != null});

    // Calculate cell dimensions FIRST from font metrics (like Ghostty)
    // This must happen before loading sprites so they use correct dimensions
    //
    // Cell width is the maximum advance of all visible ASCII characters (like Ghostty)
    // This ensures proper spacing for monospace fonts
    {
        var max_advance: f64 = 0;
        var ascii_char: u8 = ' ';
        while (ascii_char < 127) : (ascii_char += 1) {
            if (loadGlyph(ascii_char)) |char| {
                const advance = @as(f64, @floatFromInt(char.advance)) / 64.0; // 26.6 fixed point
                max_advance = @max(max_advance, advance);
            }
        }
        if (max_advance > 0) {
            cell_width = @floatCast(max_advance);
        }
    }

    if (loadGlyph('M')) |_| {

        // Get metrics like Ghostty does - from font tables with fallback to FreeType
        const size_metrics = face.handle.*.size.*.metrics;
        const px_per_em: f64 = @floatFromInt(size_metrics.y_ppem);

        // Get units_per_em from head table or FreeType
        const units_per_em: f64 = blk: {
            if (face.getSfntTable(.head)) |head| {
                break :blk @floatFromInt(head.Units_Per_EM);
            }
            if (face.handle.*.face_flags & freetype.c.FT_FACE_FLAG_SCALABLE != 0) {
                break :blk @floatFromInt(face.handle.*.units_per_EM);
            }
            break :blk @floatFromInt(size_metrics.y_ppem);
        };
        const px_per_unit = px_per_em / units_per_em;

        // Get vertical metrics from font tables (like Ghostty)
        const ascent: f64, const descent: f64, const line_gap: f64 = vertical_metrics: {
            const hhea_ = face.getSfntTable(.hhea);
            const os2_ = face.getSfntTable(.os2);

            // If no hhea table, fall back to FreeType metrics
            const hhea = hhea_ orelse {
                const ft_ascender = f26dot6ToF64(size_metrics.ascender);
                const ft_descender = f26dot6ToF64(size_metrics.descender);
                const ft_height = f26dot6ToF64(size_metrics.height);
                break :vertical_metrics .{
                    ft_ascender,
                    ft_descender,
                    ft_height + ft_descender - ft_ascender,
                };
            };

            const hhea_ascent: f64 = @floatFromInt(hhea.Ascender);
            const hhea_descent: f64 = @floatFromInt(hhea.Descender);
            const hhea_line_gap: f64 = @floatFromInt(hhea.Line_Gap);

            // If no OS/2 table, use hhea metrics
            const os2 = os2_ orelse break :vertical_metrics .{
                hhea_ascent * px_per_unit,
                hhea_descent * px_per_unit,
                hhea_line_gap * px_per_unit,
            };

            // Check for invalid OS/2 table
            if (os2.version == 0xFFFF) break :vertical_metrics .{
                hhea_ascent * px_per_unit,
                hhea_descent * px_per_unit,
                hhea_line_gap * px_per_unit,
            };

            const os2_ascent: f64 = @floatFromInt(os2.sTypoAscender);
            const os2_descent: f64 = @floatFromInt(os2.sTypoDescender);
            const os2_line_gap: f64 = @floatFromInt(os2.sTypoLineGap);

            // If USE_TYPO_METRICS bit is set (bit 7), use OS/2 typo metrics
            if (os2.fsSelection & (1 << 7) != 0) {
                break :vertical_metrics .{
                    os2_ascent * px_per_unit,
                    os2_descent * px_per_unit,
                    os2_line_gap * px_per_unit,
                };
            }

            // Otherwise prefer hhea if available
            if (hhea.Ascender != 0 or hhea.Descender != 0) {
                break :vertical_metrics .{
                    hhea_ascent * px_per_unit,
                    hhea_descent * px_per_unit,
                    hhea_line_gap * px_per_unit,
                };
            }

            // Fall back to OS/2 sTypo metrics
            if (os2_ascent != 0 or os2_descent != 0) {
                break :vertical_metrics .{
                    os2_ascent * px_per_unit,
                    os2_descent * px_per_unit,
                    os2_line_gap * px_per_unit,
                };
            }

            // Last resort: OS/2 usWin metrics
            const win_ascent: f64 = @floatFromInt(os2.usWinAscent);
            const win_descent: f64 = @floatFromInt(os2.usWinDescent);
            break :vertical_metrics .{
                win_ascent * px_per_unit,
                -win_descent * px_per_unit, // usWinDescent is positive, flip sign
                0.0,
            };
        };

        // Calculate cell dimensions like Ghostty
        const face_height = ascent - descent + line_gap;
        cell_height = @floatCast(@round(face_height));

        // Split line gap in half for top/bottom padding (like Ghostty)
        const half_line_gap = line_gap / 2.0;

        // Calculate baseline from bottom of cell (like Ghostty)
        // face_baseline = half_line_gap - descent (descent is negative, so this adds)
        const face_baseline = half_line_gap - descent;
        // Center the baseline by accounting for rounding difference
        const baseline_centered = face_baseline - (cell_height - face_height) / 2.0;
        cell_baseline = @floatCast(@round(baseline_centered));

        // Cursor height is the ascender
        cursor_height = @floatCast(@round(ascent));

        // Get underline thickness from post table for box drawing (like Ghostty)
        const underline_thickness: f64 = ul_thick: {
            if (face.getSfntTable(.post)) |post| {
                if (post.underlineThickness != 0) {
                    break :ul_thick @as(f64, @floatFromInt(post.underlineThickness)) * px_per_unit;
                }
            }
            // Fallback: use a reasonable default based on cell height
            break :ul_thick @max(1.0, @round(cell_height / 16.0));
        };
        // Use ceiling like Ghostty
        box_thickness = @max(1, @as(u32, @intFromFloat(@ceil(underline_thickness))));

        std.debug.print("Cell dimensions: {d:.0}x{d:.0} (ascent={d:.1}, descent={d:.1}, line_gap={d:.1}, baseline={d:.0}, box_thick={})\n", .{
            cell_width, cell_height, ascent, descent, line_gap, cell_baseline, box_thickness,
        });
    } else {
        std.debug.print("ERROR: Could not load 'M' glyph!\n", .{});
    }

    // Preload ASCII printable characters (32-126)
    var ascii_loaded: u32 = 0;
    for (32..127) |char| {
        if (loadGlyph(@intCast(char)) != null) {
            ascii_loaded += 1;
        }
    }
    std.debug.print("ASCII glyphs loaded: {}\n", .{ascii_loaded});

    // Preload box drawing characters (U+2500 - U+257F)
    var box_loaded: u32 = 0;
    for (0x2500..0x2580) |char| {
        if (loadGlyph(@intCast(char)) != null) {
            box_loaded += 1;
        }
    }
    std.debug.print("Box drawing glyphs loaded: {}\n", .{box_loaded});

    // Preload block elements (U+2580 - U+259F)
    for (0x2580..0x25A0) |char| {
        _ = loadGlyph(@intCast(char));
    }

    std.debug.print("Total glyphs in cache: {}\n", .{glyph_cache.count()});
}

fn indexToRgb(color_idx: u8) [3]f32 {
    // Use theme palette for colors 0-15
    if (color_idx < 16) {
        return g_theme.palette[color_idx];
    } else if (color_idx < 232) {
        // 216 color cube (6x6x6): indices 16-231
        const idx = color_idx - 16;
        const r = idx / 36;
        const g = (idx / 6) % 6;
        const b = idx % 6;
        return .{
            if (r == 0) 0.0 else (@as(f32, @floatFromInt(r)) * 40.0 + 55.0) / 255.0,
            if (g == 0) 0.0 else (@as(f32, @floatFromInt(g)) * 40.0 + 55.0) / 255.0,
            if (b == 0) 0.0 else (@as(f32, @floatFromInt(b)) * 40.0 + 55.0) / 255.0,
        };
    } else {
        // Grayscale: indices 232-255 (24 shades)
        const gray = (@as(f32, @floatFromInt(color_idx - 232)) * 10.0 + 8.0) / 255.0;
        return .{ gray, gray, gray };
    }
}

fn renderChar(codepoint: u32, x: f32, y: f32, color: [3]f32) void {
    // Skip control characters
    if (codepoint < 32) return;

    // Get character from cache (load on-demand if needed)
    const ch: Character = loadGlyph(codepoint) orelse return;

    // Position glyph relative to baseline (like Ghostty)
    // y = cell bottom, cell_baseline = distance from cell bottom to baseline
    // bearing_y (bitmap_top) = distance from baseline to glyph top
    // y0 = glyph bottom = cell_bottom + cell_baseline + bearing_y - glyph_height
    const x0 = x + @as(f32, @floatFromInt(ch.bearing_x));
    const y0 = y + cell_baseline - @as(f32, @floatFromInt(ch.size_y - ch.bearing_y));
    const w = @as(f32, @floatFromInt(ch.size_x));
    const h = @as(f32, @floatFromInt(ch.size_y));

    const vertices = [6][4]f32{
        .{ x0, y0 + h, 0.0, 0.0 },
        .{ x0, y0, 0.0, 1.0 },
        .{ x0 + w, y0, 1.0, 1.0 },
        .{ x0, y0 + h, 0.0, 0.0 },
        .{ x0 + w, y0, 1.0, 1.0 },
        .{ x0 + w, y0 + h, 1.0, 0.0 },
    };

    gl.Uniform3f.?(gl.GetUniformLocation.?(shader_program, "textColor"), color[0], color[1], color[2]);
    gl.BindTexture.?(c.GL_TEXTURE_2D, ch.texture_id);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
}

/// Render a character with uniform scaling applied to the glyph quad.
/// scale < 1.0 makes text smaller. The position (x, y) is the cell bottom-left.
/// Get scaled advance width for a codepoint.
fn glyphAdvanceScaled(codepoint: u32, scale: f32) f32 {
    if (loadGlyph(codepoint)) |glyph| {
        return @as(f32, @floatFromInt(glyph.advance >> 6)) * scale;
    }
    return cell_width * scale;
}

fn renderCharScaled(codepoint: u32, x: f32, y: f32, color: [3]f32, scale: f32) void {
    if (codepoint < 32) return;
    const ch: Character = loadGlyph(codepoint) orelse return;

    const w = @as(f32, @floatFromInt(ch.size_x)) * scale;
    const h = @as(f32, @floatFromInt(ch.size_y)) * scale;
    const bearing_x = @as(f32, @floatFromInt(ch.bearing_x)) * scale;
    const bearing_y = @as(f32, @floatFromInt(ch.bearing_y)) * scale;
    const size_y = @as(f32, @floatFromInt(ch.size_y)) * scale;

    const x0 = x + bearing_x;
    const y0 = y + cell_baseline * scale - (size_y - bearing_y);

    const vertices = [6][4]f32{
        .{ x0, y0 + h, 0.0, 0.0 },
        .{ x0, y0, 0.0, 1.0 },
        .{ x0 + w, y0, 1.0, 1.0 },
        .{ x0, y0 + h, 0.0, 0.0 },
        .{ x0 + w, y0, 1.0, 1.0 },
        .{ x0 + w, y0 + h, 1.0, 0.0 },
    };

    gl.Uniform3f.?(gl.GetUniformLocation.?(shader_program, "textColor"), color[0], color[1], color[2]);
    gl.BindTexture.?(c.GL_TEXTURE_2D, ch.texture_id);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
}

/// Render the Ghostty-style tab bar.
/// Single row: [tabs...][+][  ][min][max][close]
///
/// Design (from Ghostty macOS screenshot):
/// - Tabs fill available width equally (left of + and caption buttons)
/// - Active tab: same color as terminal background (merges with content)
/// - Inactive tabs: slightly lighter shade
/// - Thin vertical separators between tabs
/// - No rounded corners, no accent lines — purely shade-based
/// - + button right of last tab
/// - Caption buttons on far right
///
/// OpenGL Y=0 is BOTTOM, so titlebar top = window_height - titlebar_h.
fn renderTitlebar(window_width: f32, window_height: f32, titlebar_h: f32) void {
    if (titlebar_h <= 0) return;

    gl.UseProgram.?(shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(vao);

    const tb_top = window_height - titlebar_h; // top of titlebar in GL coords
    const bg = g_theme.background;

    // Colors — Ghostty style:
    // - Active tab: same as terminal bg, no border (merges with content)
    // - Inactive tabs & + button: slightly lighter bg with 1px darker inset border
    const inactive_tab_bg = [3]f32{
        @min(1.0, bg[0] + 0.05),
        @min(1.0, bg[1] + 0.05),
        @min(1.0, bg[2] + 0.05),
    };
    const border_color = [3]f32{
        @max(0.0, bg[0] - 0.02),
        @max(0.0, bg[1] - 0.02),
        @max(0.0, bg[2] - 0.02),
    };
    const text_active = [3]f32{ 0.9, 0.9, 0.9 };
    const text_inactive = [3]f32{ 0.55, 0.55, 0.55 };

    // Layout constants
    const caption_btn_w: f32 = 46;
    const caption_area_w: f32 = caption_btn_w * 3; // min + max + close
    const plus_btn_w: f32 = 46; // + button width (same as caption buttons)
    const gap_w: f32 = 42; // breathing room between + and caption buttons
    const show_plus = g_tab_count > 1;
    const num_tabs = g_tab_count;

    // Calculate space: tabs fill remaining width after + button, gap, and caption buttons
    const plus_total: f32 = if (show_plus) plus_btn_w else 0;
    const right_reserved: f32 = caption_area_w + gap_w + plus_total;
    const tab_area_w: f32 = window_width - right_reserved;
    const tab_w: f32 = if (num_tabs > 0) tab_area_w / @as(f32, @floatFromInt(num_tabs)) else tab_area_w;

    // --- Tab bar background (same as terminal bg) ---
    renderQuad(0, tb_top, window_width, titlebar_h, bg);

    // --- Tabs ---
    var cursor_x: f32 = 0;
    const bdr: f32 = 1; // border thickness

    for (0..num_tabs) |tab_idx| {
        const is_active = (tab_idx == g_active_tab);

        // Inactive tabs: slightly lighter bg with 1px darker inset border
        // Active tab: no border, same as terminal bg (merges with content)
        if (!is_active) {
            // Check hover
            const tab_hovered = blk: {
                if (!build_options.use_win32) break :blk false;
                const win = g_window orelse break :blk false;
                if (win.mouse_y < 0 or win.mouse_y >= @as(i32, @intFromFloat(titlebar_h))) break :blk false;
                const fx: f32 = @floatFromInt(win.mouse_x);
                break :blk fx >= cursor_x and fx < cursor_x + tab_w;
            };

            // Fill — slightly lighter on hover
            const tab_bg = if (tab_hovered) [3]f32{
                @min(1.0, inactive_tab_bg[0] + 0.04),
                @min(1.0, inactive_tab_bg[1] + 0.04),
                @min(1.0, inactive_tab_bg[2] + 0.04),
            } else inactive_tab_bg;
            renderQuad(cursor_x, tb_top, tab_w, titlebar_h, tab_bg);

            // 1px inset border — left border only (skip on first tab), bottom
            renderQuad(cursor_x, tb_top, tab_w, bdr, border_color); // bottom
            if (tab_idx > 0) {
                renderQuad(cursor_x, tb_top, bdr, titlebar_h, border_color); // left
            }
        }

        // Tab title text — centered, scaled down to ~75% of terminal font
        // Shortcut label (^1 through ^0) rendered right-aligned, only for tabs 1–10 in multi-tab
        const title = if (g_tabs[tab_idx]) |t| t.getTitle() else "New Tab";
        if (title.len > 0) {
            const text_color = if (is_active) text_active else text_inactive;
            const shortcut_color = [3]f32{ 0.45, 0.45, 0.45 };
            // Fixed 14pt for tab titles regardless of terminal font size
            // At 96 DPI, 14pt ≈ 18.7px. Scale factor = target / actual.
            const target_height: f32 = 14.0 * 96.0 / 72.0; // 14pt at 96 DPI
            const text_scale: f32 = target_height / cell_height;
            const scaled_height = target_height;
            const tab_pad: f32 = 18;

            // Shortcut label: "^1" through "^9", "^0" for tab 10
            const has_shortcut = num_tabs > 1 and tab_idx < 10;
            const shortcut_digit: u8 = if (has_shortcut)
                (if (tab_idx == 9) '0' else @as(u8, @intCast('1' + tab_idx)))
            else
                0;

            // Measure shortcut width
            var shortcut_w: f32 = 0;
            if (has_shortcut) {
                shortcut_w += glyphAdvanceScaled('^', text_scale);
                shortcut_w += glyphAdvanceScaled(@intCast(shortcut_digit), text_scale);
            }

            const shortcut_gap: f32 = if (has_shortcut) 6 else 0;
            const shortcut_reserved = if (has_shortcut) shortcut_w + shortcut_gap else 0;

            const center_region = if (num_tabs == 1) window_width else tab_w;
            const center_offset = if (num_tabs == 1) @as(f32, 0) else cursor_x;
            const avail_w = center_region - tab_pad * 2 - shortcut_reserved;

            // Decode title into codepoints for proper UTF-8 handling
            var codepoints: [256]u32 = undefined;
            var cp_count: usize = 0;
            var text_width: f32 = 0;
            {
                const view = std.unicode.Utf8View.initUnchecked(title);
                var it = view.iterator();
                while (it.nextCodepoint()) |cp| {
                    if (cp_count >= 256) break;
                    codepoints[cp_count] = cp;
                    text_width += glyphAdvanceScaled(cp, text_scale);
                    cp_count += 1;
                }
            }

            const text_y = tb_top + (titlebar_h - scaled_height) / 2;

            if (text_width <= avail_w) {
                // Fits — center it
                const text_area = center_region - shortcut_reserved;
                var text_x = center_offset + (text_area - text_width) / 2;
                for (codepoints[0..cp_count]) |cp| {
                    renderCharScaled(cp, text_x, text_y, text_color, text_scale);
                    text_x += glyphAdvanceScaled(cp, text_scale);
                }
            } else {
                // Middle truncation
                const ellipsis_char: u32 = 0x2026;
                const ellipsis_w = glyphAdvanceScaled(ellipsis_char, text_scale);
                const text_budget = avail_w - ellipsis_w;
                const half_budget = text_budget / 2;

                // Measure codepoints from start
                var start_w: f32 = 0;
                var start_end: usize = 0;
                for (codepoints[0..cp_count], 0..) |cp, idx| {
                    const char_w = glyphAdvanceScaled(cp, text_scale);
                    if (start_w + char_w > half_budget) break;
                    start_w += char_w;
                    start_end = idx + 1;
                }

                // Measure codepoints from end
                var end_w: f32 = 0;
                var end_start: usize = cp_count;
                var j: usize = cp_count;
                while (j > start_end) {
                    j -= 1;
                    const char_w = glyphAdvanceScaled(codepoints[j], text_scale);
                    if (end_w + char_w > half_budget) break;
                    end_w += char_w;
                    end_start = j;
                }

                var text_x = center_offset + tab_pad;
                for (codepoints[0..start_end]) |cp| {
                    renderCharScaled(cp, text_x, text_y, text_color, text_scale);
                    text_x += glyphAdvanceScaled(cp, text_scale);
                }
                renderCharScaled(ellipsis_char, text_x, text_y, text_color, text_scale);
                text_x += ellipsis_w;
                for (codepoints[end_start..cp_count]) |cp| {
                    renderCharScaled(cp, text_x, text_y, text_color, text_scale);
                    text_x += glyphAdvanceScaled(cp, text_scale);
                }
            }

            // Render shortcut label right-aligned
            if (has_shortcut) {
                const sc_color = if (is_active) text_active else shortcut_color;
                var sc_x = center_offset + center_region - tab_pad - shortcut_w;
                renderCharScaled('^', sc_x, text_y, sc_color, text_scale);
                sc_x += glyphAdvanceScaled('^', text_scale);
                renderCharScaled(@intCast(shortcut_digit), sc_x, text_y, sc_color, text_scale);
            }
        }

        cursor_x += tab_w;
    }

    // --- + (new tab) button — transparent bg, inactive_tab_bg on hover ---
    if (show_plus) {
        // Check if mouse is hovering the + button
        const plus_hovered = blk: {
            if (!build_options.use_win32) break :blk false;
            const win = g_window orelse break :blk false;
            const mouse_x = win.mouse_x;
            const mouse_y = win.mouse_y;
            if (mouse_y < 0 or mouse_y >= @as(i32, @intFromFloat(titlebar_h))) break :blk false;
            const fx: f32 = @floatFromInt(mouse_x);
            break :blk fx >= cursor_x and fx < cursor_x + plus_btn_w;
        };

        if (plus_hovered) {
            renderQuad(cursor_x, tb_top, plus_btn_w, titlebar_h, inactive_tab_bg);
            renderQuad(cursor_x, tb_top, plus_btn_w, bdr, border_color); // bottom
        }

        // Left border — skip when last tab is active (no visual break needed)
        if (g_active_tab != num_tabs - 1) {
            renderQuad(cursor_x, tb_top, bdr, titlebar_h, border_color);
        }

        // + icon — same font/color as caption buttons, scaled up 15% to match stroke weight
        const plus_icon_color = [3]f32{ 0.75, 0.75, 0.75 };
        const plus_scale: f32 = 1.15;
        if (icon_face != null) {
            if (loadIconGlyph(0xE948)) |ch| {
                const gw = @as(f32, @floatFromInt(ch.size_x)) * plus_scale;
                const gh = @as(f32, @floatFromInt(ch.size_y)) * plus_scale;
                const gx = cursor_x + (plus_btn_w - gw) / 2;
                const gy = tb_top + (titlebar_h + gh) / 2 - @as(f32, @floatFromInt(ch.bearing_y)) * plus_scale;

                const vertices = [6][4]f32{
                    .{ gx, gy + gh, 0.0, 0.0 },
                    .{ gx, gy, 0.0, 1.0 },
                    .{ gx + gw, gy, 1.0, 1.0 },
                    .{ gx, gy + gh, 0.0, 0.0 },
                    .{ gx + gw, gy, 1.0, 1.0 },
                    .{ gx + gw, gy + gh, 1.0, 0.0 },
                };

                gl.Uniform3f.?(gl.GetUniformLocation.?(shader_program, "textColor"), plus_icon_color[0], plus_icon_color[1], plus_icon_color[2]);
                gl.BindTexture.?(c.GL_TEXTURE_2D, ch.texture_id);
                gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
                gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
                gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
                gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
            }
        } else {
            const plus_cx = cursor_x + plus_btn_w / 2;
            const plus_cy = tb_top + titlebar_h / 2;
            const arm: f32 = 5;
            const t: f32 = 1.0;
            renderQuad(plus_cx - arm, plus_cy - t / 2, arm * 2, t, plus_icon_color);
            renderQuad(plus_cx - t / 2, plus_cy - arm, t, arm * 2, plus_icon_color);
        }
        // Sync plus button position for double-click suppression in WndProc
        if (build_options.use_win32) {
            if (g_window) |w| {
                w.plus_btn_x_start = @intFromFloat(cursor_x);
                w.plus_btn_x_end = @intFromFloat(cursor_x + plus_btn_w);
            }
        }
        cursor_x += plus_btn_w;
    }

    // --- Caption buttons (minimize, maximize, close) ---
    const btn_h: f32 = titlebar_h;
    const hovered: win32_backend.CaptionButton = if (build_options.use_win32)
        (if (g_window) |w| w.hovered_button else .none)
    else
        .none;

    const caption_start = window_width - caption_area_w;
    renderCaptionButton(caption_start, tb_top, caption_btn_w, btn_h, .minimize, hovered == .minimize);
    renderCaptionButton(caption_start + caption_btn_w, tb_top, caption_btn_w, btn_h, .maximize, hovered == .maximize);
    renderCaptionButton(caption_start + caption_btn_w * 2, tb_top, caption_btn_w, btn_h, .close, hovered == .close);

    // --- Focus border: 1px accent border when window is focused (matches Explorer/DWM) ---
    if (build_options.use_win32) {
        const is_focused = if (g_window) |w| w.focused else false;
        const is_maximized = if (g_window) |w| win32_backend.IsZoomed(w.hwnd) != 0 else false;
        if (is_focused and !is_maximized) {
            // Same color as active tab (terminal background)
            const accent = bg;
            const b: f32 = 1; // 1px border
            renderQuad(0, 0, window_width, b, accent); // bottom
            renderQuad(0, window_height - b, window_width, b, accent); // top
            renderQuad(0, 0, b, window_height, accent); // left
            renderQuad(window_width - b, 0, b, window_height, accent); // right
        }
    }
}

const CaptionButtonType = enum { minimize, maximize, close };

/// Draw a Windows Terminal-style caption button with hover support.
/// Each button is 46×40px with a 10×10 icon centered inside.
/// Matches Windows Terminal's visual style:
///   - Normal: transparent bg, light gray icon
///   - Hover (min/max): subtle light fill bg, white icon
///   - Hover (close): red #C42B1C bg, white icon
fn renderCaptionButton(x: f32, y: f32, w: f32, h: f32, btn_type: CaptionButtonType, hovered: bool) void {
    // Draw hover background, respecting the 1px focus border on edges
    if (hovered) {
        const hover_bg = switch (btn_type) {
            .close => [3]f32{ 0.77, 0.17, 0.11 }, // #C42B1C
            else => [3]f32{
                @min(1.0, g_theme.background[0] + 0.05),
                @min(1.0, g_theme.background[1] + 0.05),
                @min(1.0, g_theme.background[2] + 0.05),
            },
        };
        // Close button is at the window edge — inset by 1px on top/right
        // to respect the focus border (matches Explorer behavior)
        if (btn_type == .close) {
            const is_focused = if (build_options.use_win32)
                (if (g_window) |win| win.focused else false)
            else
                false;
            const is_maximized = if (build_options.use_win32)
                (if (g_window) |win| win32_backend.IsZoomed(win.hwnd) != 0 else false)
            else
                false;
            const b: f32 = if (is_focused and !is_maximized) 1 else 0;
            renderQuad(x, y + b, w - b, h - b, hover_bg);
        } else {
            renderQuad(x, y, w, h, hover_bg);
        }
    }

    // Icon color: white when hovered, light gray otherwise
    const icon_color: [3]f32 = if (hovered) .{ 1.0, 1.0, 1.0 } else .{ 0.75, 0.75, 0.75 };

    // Check if window is maximized or fullscreen (for restore icon)
    const is_maximized = if (build_options.use_win32)
        (if (g_window) |win| win32_backend.IsZoomed(win.hwnd) != 0 else false)
    else
        false;
    const is_fullscreen = if (build_options.use_win32)
        (if (g_window) |win| win.is_fullscreen else false)
    else
        false;

    // Segoe MDL2 Assets glyph codepoints (same as Windows Terminal)
    const icon_codepoint: u32 = switch (btn_type) {
        .close => 0xE8BB,
        .maximize => if (is_maximized or is_fullscreen) @as(u32, 0xE923) else @as(u32, 0xE922),
        .minimize => 0xE921,
    };

    // Try rendering from Segoe MDL2 Assets icon font
    if (icon_face != null) {
        if (loadIconGlyph(icon_codepoint)) |ch| {
            const gw = @as(f32, @floatFromInt(ch.size_x));
            const gh = @as(f32, @floatFromInt(ch.size_y));
            // Center the glyph bitmap in the button (ignore baseline positioning)
            const gx = x + (w - gw) / 2;
            const gy = y + (h - gh) / 2;

            const vertices = [6][4]f32{
                .{ gx, gy + gh, 0.0, 0.0 },
                .{ gx, gy, 0.0, 1.0 },
                .{ gx + gw, gy, 1.0, 1.0 },
                .{ gx, gy + gh, 0.0, 0.0 },
                .{ gx + gw, gy, 1.0, 1.0 },
                .{ gx + gw, gy + gh, 1.0, 0.0 },
            };

            gl.Uniform3f.?(gl.GetUniformLocation.?(shader_program, "textColor"), icon_color[0], icon_color[1], icon_color[2]);
            gl.BindTexture.?(c.GL_TEXTURE_2D, ch.texture_id);
            gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
            gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
            gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
            gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
            return;
        }
    }

    // Fallback: quad-based icons
    const cx = x + w / 2;
    const cy = y + h / 2;

    switch (btn_type) {
        .close => {
            const size: f32 = 5;
            const steps: usize = 32;
            const t: f32 = 1.5;
            for (0..steps) |i| {
                const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps - 1));
                const px = cx - size + frac * size * 2;
                const py1 = cy + size - frac * size * 2;
                renderQuad(px - t / 2, py1 - t / 2, t, t, icon_color);
                const py2 = cy - size + frac * size * 2;
                renderQuad(px - t / 2, py2 - t / 2, t, t, icon_color);
            }
        },
        .maximize => {
            const size: f32 = 5;
            const t: f32 = 1;
            renderQuad(cx - size, cy + size - t, size * 2, t, icon_color); // top
            renderQuad(cx - size, cy - size, size * 2, t, icon_color); // bottom
            renderQuad(cx - size, cy - size, t, size * 2, icon_color); // left
            renderQuad(cx + size - t, cy - size, t, size * 2, icon_color); // right
        },
        .minimize => {
            const size: f32 = 5;
            const t: f32 = 1;
            renderQuad(cx - size, cy - t / 2, size * 2, t, icon_color);
        },
    }
}

fn getGlyphInfo(codepoint: u32) ?Character {
    return glyph_cache.get(codepoint);
}

/// Load a glyph from the Segoe MDL2 Assets icon font.
fn loadIconGlyph(codepoint: u32) ?Character {
    if (icon_cache.get(codepoint)) |ch| return ch;

    const face = icon_face orelse return null;
    const alloc = g_allocator orelse return null;

    const glyph_index = face.getCharIndex(codepoint) orelse return null;
    if (glyph_index == 0) return null;

    // Use mono hinting for crisp icon rendering (snaps to pixel grid)
    face.loadGlyph(@intCast(glyph_index), .{ .target = .normal }) catch return null;
    face.renderGlyph(.normal) catch return null;

    const glyph = face.handle.*.glyph;
    const bitmap = glyph.*.bitmap;

    var texture: c.GLuint = 0;
    gl.GenTextures.?(1, &texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, texture);

    if (bitmap.width > 0 and bitmap.rows > 0) {
        gl.TexImage2D.?(
            c.GL_TEXTURE_2D, 0, c.GL_RED,
            @intCast(bitmap.width), @intCast(bitmap.rows),
            0, c.GL_RED, c.GL_UNSIGNED_BYTE, bitmap.buffer,
        );
    } else {
        const empty: [1]u8 = .{0};
        gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, c.GL_RED, 1, 1, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, &empty);
    }

    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);

    const ch = Character{
        .texture_id = texture,
        .size_x = @intCast(bitmap.width),
        .size_y = @intCast(bitmap.rows),
        .bearing_x = @intCast(glyph.*.bitmap_left),
        .bearing_y = @intCast(glyph.*.bitmap_top),
        .advance = @intCast(glyph.*.advance.x),
    };

    icon_cache.put(alloc, codepoint, ch) catch return null;
    return ch;
}

/// Render placeholder content for tabs that don't have a terminal yet.
fn renderPlaceholderTab(window_width: f32, window_height: f32, top_pad: f32) void {
    gl.UseProgram.?(shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(vao);

    const msg = "Tabs not yet implemented";
    const hint = "Press Ctrl+Shift+T to open, Ctrl+W to close";
    const text_color = [3]f32{ 0.4, 0.4, 0.4 };

    // Center the message vertically and horizontally
    const content_h = window_height - top_pad;
    const center_y = content_h / 2;

    // Measure and draw main message
    var msg_width: f32 = 0;
    for (msg) |ch| {
        if (getGlyphInfo(@intCast(ch))) |g| {
            msg_width += @as(f32, @floatFromInt(g.advance >> 6));
        } else {
            msg_width += cell_width;
        }
    }
    var x = (window_width - msg_width) / 2;
    var y = center_y + cell_height / 2;
    for (msg) |ch| {
        renderChar(@intCast(ch), x, y, text_color);
        if (getGlyphInfo(@intCast(ch))) |g| {
            x += @as(f32, @floatFromInt(g.advance >> 6));
        } else {
            x += cell_width;
        }
    }

    // Measure and draw hint below
    var hint_width: f32 = 0;
    for (hint) |ch| {
        if (getGlyphInfo(@intCast(ch))) |g| {
            hint_width += @as(f32, @floatFromInt(g.advance >> 6));
        } else {
            hint_width += cell_width;
        }
    }
    x = (window_width - hint_width) / 2;
    y = center_y - cell_height;
    const hint_color = [3]f32{ 0.3, 0.3, 0.3 };
    for (hint) |ch| {
        renderChar(@intCast(ch), x, y, hint_color);
        if (getGlyphInfo(@intCast(ch))) |g| {
            x += @as(f32, @floatFromInt(g.advance >> 6));
        } else {
            x += cell_width;
        }
    }
}

fn renderTerminal(terminal: *ghostty_vt.Terminal, window_height: f32, offset_x: f32, offset_y: f32) void {
    gl.UseProgram.?(shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(vao);

    const screen = terminal.screens.active;

    // Get cursor position - only show cursor when viewport is at the bottom
    const cursor_x = screen.cursor.x;
    const cursor_y = screen.cursor.y;
    const viewport_at_bottom = screen.pages.viewport == .active;

    // Get terminal-controlled cursor style (set by DECSCUSR escape sequence)
    // This is what programs like vim use to change cursor shape
    const terminal_cursor_style: TerminalCursorStyle = switch (screen.cursor.cursor_style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };

    // Get terminal-controlled cursor blink mode (also set by DECSCUSR)
    // Steady styles (2, 4, 6) set this to false, blinking styles (1, 3, 5) set it to true
    const terminal_cursor_blink = terminal.modes.get(.cursor_blinking);

    // Use terminal's actual dimensions for rendering (not global vars which may be out of sync)
    const render_rows = terminal.rows;
    const render_cols = terminal.cols;

    for (0..render_rows) |row_idx| {
        // Row 0 is at the top, so we start from (window_height - offset) and go down
        const y = window_height - offset_y - ((@as(f32, @floatFromInt(row_idx)) + 1) * cell_height);

        for (0..render_cols) |col_idx| {
            const x = offset_x + @as(f32, @floatFromInt(col_idx)) * cell_width;

            // Check if this is the cursor position (only when viewport is at bottom)
            const is_cursor = viewport_at_bottom and (col_idx == cursor_x and row_idx == cursor_y);

            // Get cell from the page list
            const cell_data = screen.pages.getCell(.{ .viewport = .{
                .x = @intCast(col_idx),
                .y = @intCast(row_idx),
            } });
            


            // Get foreground color from cell style
            var fg_color: [3]f32 = g_theme.foreground; // Default from theme
            var bg_color: ?[3]f32 = null;

            if (cell_data) |cd| {
                const cell = cd.cell;

                // Check for background-only cells (used by erase operations like \e[K)
                // These cells have no text but store a background color directly
                switch (cell.content_tag) {
                    .bg_color_palette => {
                        bg_color = indexToRgb(cell.content.color_palette);
                    },
                    .bg_color_rgb => {
                        const rgb = cell.content.color_rgb;
                        bg_color = .{
                            @as(f32, @floatFromInt(rgb.r)) / 255.0,
                            @as(f32, @floatFromInt(rgb.g)) / 255.0,
                            @as(f32, @floatFromInt(rgb.b)) / 255.0,
                        };
                    },
                    else => {},
                }

                // Get style if available (for text cells with styling)
                if (cell.hasStyling()) {
                    const style = cd.node.data.styles.get(
                        cd.node.data.memory,
                        cell.style_id,
                    );
                    // Foreground color
                    switch (style.fg_color) {
                        .none => {},
                        .palette => |idx| fg_color = indexToRgb(idx),
                        .rgb => |rgb| fg_color = .{
                            @as(f32, @floatFromInt(rgb.r)) / 255.0,
                            @as(f32, @floatFromInt(rgb.g)) / 255.0,
                            @as(f32, @floatFromInt(rgb.b)) / 255.0,
                        },
                    }
                    // Background color from style (overrides bg-only cell color)
                    switch (style.bg_color) {
                        .none => {},
                        .palette => |idx| bg_color = indexToRgb(idx),
                        .rgb => |rgb| bg_color = .{
                            @as(f32, @floatFromInt(rgb.r)) / 255.0,
                            @as(f32, @floatFromInt(rgb.g)) / 255.0,
                            @as(f32, @floatFromInt(rgb.b)) / 255.0,
                        },
                    }
                }
            }

            // Check if cell is selected
            const is_selected = isCellSelected(col_idx, row_idx);

            // Draw cursor (with style and blink support like Ghostty)
            if (is_cursor) {
                const cursor_result = renderCursor(x, y, cell_width, cell_height, terminal_cursor_style, terminal_cursor_blink);
                if (cursor_result.invert_fg) {
                    // Use cursor_text if defined, otherwise use background color (inverted)
                    fg_color = g_theme.cursor_text orelse g_theme.background;
                }
            } else if (is_selected) {
                renderQuad(x, y, cell_width, cell_height, g_theme.selection_background);
                fg_color = g_theme.selection_foreground orelse g_theme.foreground;
            } else if (bg_color) |bg| {
                renderQuad(x, y, cell_width, cell_height, bg);
            }

            // Render character if present
            if (cell_data) |cd| {
                const char = cd.cell.codepoint();
                if (char != 0 and char != ' ') {
                    renderChar(char, x, y, fg_color);
                }
            }
        }
    }

    gl.BindVertexArray.?(0);
    gl.BindTexture.?(c.GL_TEXTURE_2D, 0);
}

// Solid white texture for drawing filled quads
var solid_texture: c.GLuint = 0;

fn initSolidTexture() void {
    const white_pixel = [_]u8{ 255 };
    gl.GenTextures.?(1, &solid_texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, solid_texture);
    gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, c.GL_RED, 1, 1, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, &white_pixel);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
}

// ============================================================================
// Post-Processing Custom Shader System (Ghostty-compatible)
// ============================================================================
//
// Ghostty custom shaders use Shadertoy-style conventions:
//   - iResolution: vec3 (viewport resolution in pixels, z=1.0)
//   - iTime: float (elapsed time in seconds)
//   - iTimeDelta: float (time since last frame)
//   - iFrame: int (frame counter)
//   - iChannel0: sampler2D (the terminal framebuffer)
//   - iChannelResolution[0]: vec3 (texture resolution)
//
// The shader must define: void mainImage(out vec4 fragColor, in vec2 fragCoord)

/// Vertex shader for the fullscreen post-processing quad
const post_vertex_source: [*c]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec2 aPos;
    \\layout (location = 1) in vec2 aTexCoord;
    \\out vec2 vTexCoord;
    \\void main() {
    \\    gl_Position = vec4(aPos, 0.0, 1.0);
    \\    vTexCoord = aTexCoord;
    \\}
;

/// Build the post-processing fragment shader by wrapping a Ghostty/Shadertoy-style
/// mainImage shader with our uniform declarations and main() entry point.
fn buildPostFragmentSource(allocator: std.mem.Allocator, user_shader: []const u8) ![:0]const u8 {
    const preamble =
        \\#version 330 core
        \\out vec4 _fragColor;
        \\in vec2 vTexCoord;
        \\
        \\uniform vec3 iResolution;
        \\uniform float iTime;
        \\uniform float iTimeDelta;
        \\uniform int iFrame;
        \\uniform sampler2D iChannel0;
        \\uniform vec3 iChannelResolution[1];
        \\
        \\// Provide textureLod via extension or fallback
        \\
    ;
    const epilogue =
        \\
        \\void main() {
        \\    vec2 fragCoord = vTexCoord * iResolution.xy;
        \\    mainImage(_fragColor, fragCoord);
        \\}
    ;

    const total_len = preamble.len + user_shader.len + epilogue.len;
    const buf = try allocator.alloc(u8, total_len + 1); // +1 for sentinel
    @memcpy(buf[0..preamble.len], preamble);
    @memcpy(buf[preamble.len..][0..user_shader.len], user_shader);
    @memcpy(buf[preamble.len + user_shader.len ..][0..epilogue.len], epilogue);
    buf[total_len] = 0; // null-terminate

    return buf[0..total_len :0];
}

/// Load and compile a custom post-processing shader from a file
fn initPostShader(allocator: std.mem.Allocator, shader_path: []const u8) bool {
    // Read shader source file
    const file = std.fs.cwd().openFile(shader_path, .{}) catch |err| {
        std.debug.print("Failed to open shader file '{s}': {}\n", .{ shader_path, err });
        return false;
    };
    defer file.close();

    const user_source = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("Failed to read shader file: {}\n", .{err});
        return false;
    };
    defer allocator.free(user_source);

    // Build complete fragment shader
    const frag_source = buildPostFragmentSource(allocator, user_source) catch |err| {
        std.debug.print("Failed to build shader source: {}\n", .{err});
        return false;
    };
    defer allocator.free(frag_source);

    // Compile vertex shader
    const vert = compileShader(c.GL_VERTEX_SHADER, post_vertex_source) orelse return false;
    defer gl.DeleteShader.?(vert);

    // Compile fragment shader
    const frag = compileShader(c.GL_FRAGMENT_SHADER, frag_source.ptr) orelse return false;
    defer gl.DeleteShader.?(frag);

    // Link program
    g_post_program = gl.CreateProgram.?();
    gl.AttachShader.?(g_post_program, vert);
    gl.AttachShader.?(g_post_program, frag);
    gl.LinkProgram.?(g_post_program);

    var success: c.GLint = 0;
    gl.GetProgramiv.?(g_post_program, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = undefined;
        gl.GetProgramInfoLog.?(g_post_program, 512, null, &info_log);
        std.debug.print("Post shader linking failed: {s}\n", .{&info_log});
        return false;
    }

    // Set up fullscreen quad VAO/VBO
    // Two triangles covering [-1,1] NDC with tex coords [0,1]
    const quad_verts = [_]f32{
        // pos      // tex
        -1.0, -1.0, 0.0, 0.0,
        1.0,  -1.0, 1.0, 0.0,
        -1.0, 1.0,  0.0, 1.0,

        1.0,  -1.0, 1.0, 0.0,
        1.0,  1.0,  1.0, 1.0,
        -1.0, 1.0,  0.0, 1.0,
    };

    gl.GenVertexArrays.?(1, &g_post_vao);
    gl.GenBuffers.?(1, &g_post_vbo);
    gl.BindVertexArray.?(g_post_vao);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, g_post_vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad_verts)), &quad_verts, c.GL_STATIC_DRAW);
    // position (location 0)
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), null);
    // texcoord (location 1)
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
    gl.BindVertexArray.?(0);

    std.debug.print("Custom shader loaded: {s}\n", .{shader_path});
    return true;
}

/// Create or resize the off-screen framebuffer for post-processing
fn ensurePostFBO(width: c_int, height: c_int) void {
    if (width == g_post_fb_width and height == g_post_fb_height and g_post_fbo != 0) return;

    // Delete old FBO/texture if resizing
    if (g_post_fbo != 0) {
        gl.DeleteFramebuffers.?(1, &g_post_fbo);
        gl.DeleteTextures.?(1, &g_post_texture);
    }

    // Create FBO
    gl.GenFramebuffers.?(1, &g_post_fbo);
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, g_post_fbo);

    // Create color texture
    gl.GenTextures.?(1, &g_post_texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, g_post_texture);
    gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, width, height, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

    // Attach to FBO
    gl.FramebufferTexture2D.?(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, g_post_texture, 0);

    if (gl.CheckFramebufferStatus.?(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
        std.debug.print("Post-processing FBO is incomplete!\n", .{});
    }

    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
    g_post_fb_width = width;
    g_post_fb_height = height;
}

/// Render the fullscreen quad with post-processing shader applied
fn renderPostProcess(width: c_int, height: c_int) void {
    // Bind default framebuffer (screen)
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
    gl.Viewport.?(0, 0, width, height);
    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);

    // Disable blending for the fullscreen quad - shader output is final color
    gl.Disable.?(c.GL_BLEND);

    gl.UseProgram.?(g_post_program);

    // Set uniforms (Ghostty/Shadertoy conventions)
    const w_f: f32 = @floatFromInt(width);
    const h_f: f32 = @floatFromInt(height);
    const now_ms = std.time.milliTimestamp();
    const elapsed: f32 = @floatCast(@as(f64, @floatFromInt(now_ms - g_start_time)) / 1000.0);

    // iResolution
    gl.Uniform3f.?(gl.GetUniformLocation.?(g_post_program, "iResolution"), w_f, h_f, 1.0);
    // iTime
    gl.Uniform1f.?(gl.GetUniformLocation.?(g_post_program, "iTime"), elapsed);
    // iTimeDelta (approximate ~16ms)
    gl.Uniform1f.?(gl.GetUniformLocation.?(g_post_program, "iTimeDelta"), 0.016);
    // iFrame
    gl.Uniform1i.?(gl.GetUniformLocation.?(g_post_program, "iFrame"), @intCast(g_frame_count));
    // iChannel0 = texture unit 0
    gl.Uniform1i.?(gl.GetUniformLocation.?(g_post_program, "iChannel0"), 0);
    // iChannelResolution[0]
    gl.Uniform3f.?(gl.GetUniformLocation.?(g_post_program, "iChannelResolution[0]"), w_f, h_f, 1.0);

    // Bind the terminal framebuffer texture
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindTexture.?(c.GL_TEXTURE_2D, g_post_texture);

    // Draw fullscreen quad
    gl.BindVertexArray.?(g_post_vao);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
    gl.BindVertexArray.?(0);

    // Re-enable blending for next terminal render pass
    gl.Enable.?(c.GL_BLEND);

    g_frame_count +%= 1;
}

/// Helper: render a frame to FBO, then apply post-processing to screen
fn renderFrameWithPost(width: c_int, height: c_int, terminal: *ghostty_vt.Terminal, padding: f32) void {
    ensurePostFBO(width, height);

    // 1. Render terminal to FBO
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, g_post_fbo);
    gl.Viewport.?(0, 0, width, height);
    setProjection(@floatFromInt(width), @floatFromInt(height));
    gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
    updateCursorBlink();
    renderTerminal(terminal, @floatFromInt(height), padding, padding);

    // 2. Apply post-processing shader to screen
    renderPostProcess(width, height);
}

fn renderQuad(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    const vertices = [6][4]f32{
        .{ x, y + h, 0.0, 0.0 },
        .{ x, y, 0.0, 1.0 },
        .{ x + w, y, 1.0, 1.0 },
        .{ x, y + h, 0.0, 0.0 },
        .{ x + w, y, 1.0, 1.0 },
        .{ x + w, y + h, 1.0, 0.0 },
    };

    gl.Uniform3f.?(gl.GetUniformLocation.?(shader_program, "textColor"), color[0], color[1], color[2]);
    gl.BindTexture.?(c.GL_TEXTURE_2D, solid_texture);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
}

/// Terminal cursor style (matches ghostty's terminal/cursor.zig)
/// Set by DECSCUSR escape sequence from programs like vim
const TerminalCursorStyle = enum {
    bar,
    block,
    underline,
    block_hollow,
};

/// Render the cursor with style and blink support (like Ghostty)
/// Returns whether foreground should be inverted (for block cursor)
/// terminal_style is the style requested by the terminal (via DECSCUSR escape sequence)
/// terminal_blink is the blink mode from the terminal (set by DECSCUSR steady/blinking variants)
fn renderCursor(x: f32, y: f32, w: f32, h: f32, terminal_style: TerminalCursorStyle, terminal_blink: bool) struct { invert_fg: bool } {
    const cursor_color = g_theme.cursor_color;
    // Cursor thickness defaults to 1 pixel like Ghostty (metrics.cursor_thickness = 1)
    const cursor_thickness: f32 = 1.0;

    // Determine effective cursor style (like Ghostty's cursor.zig logic)
    // Priority: unfocused -> blink off -> terminal-controlled style -> configured style
    const effective_style: CursorStyle = blk: {
        // If not focused, always show hollow block
        if (!window_focused) break :blk .block_hollow;

        // Check if cursor should blink:
        // - terminal_blink: controlled by DECSCUSR (steady vs blinking variants)
        // - g_cursor_blink: user's --cursor-style-blink setting
        // Cursor blinks if BOTH are true (terminal wants blink AND user hasn't disabled it)
        const should_blink = terminal_blink and g_cursor_blink;
        if (should_blink and !g_cursor_blink_visible) {
            return .{ .invert_fg = false }; // Don't render cursor (blink off phase)
        }

        // Use terminal-controlled style (from DECSCUSR escape sequence)
        // This allows programs like vim to change cursor shape
        break :blk switch (terminal_style) {
            .block => .block,
            .bar => .bar,
            .underline => .underline,
            .block_hollow => .block_hollow,
        };
    };

    switch (effective_style) {
        .block => {
            // Solid filled block
            renderQuad(x, y, w, h, cursor_color);
            return .{ .invert_fg = true };
        },
        .block_hollow => {
            // Hollow rectangle - fill then hollow out the inside (like Ghostty)
            // Draw outer rect
            renderQuad(x, y, w, h, cursor_color);
            // Hollow out inside with background color from theme
            renderQuad(
                x + cursor_thickness,
                y + cursor_thickness,
                w - cursor_thickness * 2,
                h - cursor_thickness * 2,
                g_theme.background,
            );
            return .{ .invert_fg = false };
        },
        .bar => {
            // Vertical bar on left side of cell
            // Ghostty places bar cursor half thickness over left edge for centering
            renderQuad(x, y, cursor_thickness, h, cursor_color);
            return .{ .invert_fg = false };
        },
        .underline => {
            // Horizontal line at bottom of cell
            renderQuad(x, y, w, cursor_thickness, cursor_color);
            return .{ .invert_fg = false };
        },
    }
}

/// Update cursor blink state based on time (call once per frame)
fn updateCursorBlink() void {
    if (!g_cursor_blink) {
        g_cursor_blink_visible = true;
        return;
    }

    const now = std.time.milliTimestamp();
    if (now - g_last_blink_time >= CURSOR_BLINK_INTERVAL_MS) {
        g_cursor_blink_visible = !g_cursor_blink_visible;
        g_last_blink_time = now;
    }
}

/// Clear all GL textures from the glyph cache and reset it.
fn clearGlyphCache(allocator: std.mem.Allocator) void {
    var it = glyph_cache.iterator();
    while (it.next()) |entry| {
        gl.DeleteTextures.?(1, &entry.value_ptr.texture_id);
    }
    glyph_cache.deinit(allocator);
    glyph_cache = .empty;
}

/// Clear fallback font faces.
fn clearFallbackFaces(allocator: std.mem.Allocator) void {
    var it = g_fallback_faces.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit();
    }
    g_fallback_faces.deinit(allocator);
    g_fallback_faces = .empty;
}

/// Try to load a font face from config, returning the face or null on failure.
fn loadFontFromConfig(
    allocator: std.mem.Allocator,
    font_family: []const u8,
    weight: directwrite.DWRITE_FONT_WEIGHT,
    font_size: u32,
    ft_lib: freetype.Library,
) ?freetype.Face {
    // Try system font via DirectWrite
    if (font_family.len > 0) {
        if (g_font_discovery) |dw| {
            if (dw.findFontFilePath(allocator, font_family, weight, .NORMAL) catch null) |result| {
                var r = result;
                defer r.deinit();
                if (ft_lib.initFace(r.path, @intCast(r.face_index))) |face| {
                    face.setCharSize(0, @as(i32, @intCast(font_size)) * 64, 96, 96) catch {
                        face.deinit();
                        return null;
                    };
                    std.debug.print("Reload: loaded system font '{s}'\n", .{font_family});
                    return face;
                } else |_| {}
            }
        }
        std.debug.print("Reload: font '{s}' not found, using embedded fallback\n", .{font_family});
    }

    // Fall back to embedded font
    const face = ft_lib.initMemoryFace(embedded.regular, 0) catch return null;
    face.setCharSize(0, @as(i32, @intCast(font_size)) * 64, 96, 96) catch {
        face.deinit();
        return null;
    };
    return face;
}

/// Resize the window to fit the current terminal grid and cell dimensions.
fn resizeWindowToGrid() void {
    const padding: f32 = 10;
    const tb: f32 = if (build_options.use_win32) @floatFromInt(win32_backend.TITLEBAR_HEIGHT) else 0;
    const content_w: f32 = cell_width * @as(f32, @floatFromInt(term_cols));
    const content_h: f32 = cell_height * @as(f32, @floatFromInt(term_rows));
    const win_w: i32 = @intFromFloat(content_w + padding * 2);
    const win_h: i32 = @intFromFloat(content_h + padding + (padding + tb));
    if (build_options.use_win32) {
        if (g_window) |w| w.setSize(win_w, win_h);
    } else {
        c.glfwSetWindowSize(g_window, win_w, win_h);
    }
}

/// Check if the config file has changed (via ReadDirectoryChangesW) and reload if so.
fn checkConfigReload(allocator: std.mem.Allocator, watcher: *ConfigWatcher) void {
    if (!watcher.hasChanged()) return;

    std.debug.print("Config file changed, reloading...\n", .{});

    const cfg = Config.load(allocator) catch |err| {
        std.debug.print("Failed to reload config: {}\n", .{err});
        return;
    };
    defer cfg.deinit(allocator);

    if (g_window == null) return;
    const ft_lib = g_ft_lib orelse return;

    // --- Theme, cursor ---
    g_theme = cfg.resolved_theme;
    g_cursor_style = cfg.@"cursor-style";
    g_cursor_blink = cfg.@"cursor-style-blink";

    // Sync cursor style to all tabs' terminals (rendering reads from terminal state)
    for (0..g_tab_count) |ti| {
        if (g_tabs[ti]) |tab| {
            tab.terminal.screens.active.cursor.cursor_style = switch (g_cursor_style) {
                .bar => .bar,
                .block => .block,
                .underline => .underline,
                .block_hollow => .block_hollow,
            };
        }
    }

    // --- Font ---
    const new_font_size = cfg.@"font-size";
    const new_weight = cfg.@"font-style".toDwriteWeight();
    const new_family = cfg.@"font-family";

    // Reload font: clear caches, load new face, recalculate metrics
    if (loadFontFromConfig(allocator, new_family, new_weight, new_font_size, ft_lib)) |new_face| {
        // Clean up old font state
        if (glyph_face) |old| old.deinit();
        clearGlyphCache(allocator);
        clearFallbackFaces(allocator);

        g_font_size = new_font_size;
        preloadCharacters(new_face);
        // glyph_face is set inside preloadCharacters

        // --- Window size ---
        // If window size is configured, apply it; then resize window to match new cell dims
        if (cfg.@"window-width" > 0) term_cols = cfg.@"window-width";
        if (cfg.@"window-height" > 0) term_rows = cfg.@"window-height";
        resizeWindowToGrid();

        // Resize ALL tabs' terminals and PTYs to match
        for (0..g_tab_count) |ti| {
            if (g_tabs[ti]) |tab| {
                tab.terminal.resize(allocator, term_cols, term_rows) catch {};
                tab.pty.resize(term_cols, term_rows);
            }
        }
    } else {
        std.debug.print("Reload: failed to load font, keeping current font\n", .{});
    }

    std.debug.print("Config reloaded successfully\n", .{});
}

/// Reset cursor blink to visible state (call on keypress like Ghostty)
fn resetCursorBlink() void {
    g_cursor_blink_visible = true;
    g_last_blink_time = std.time.milliTimestamp();
}

// ============================================================================
// Shared helpers (used by both backends)
// ============================================================================

// Convert mouse position to terminal cell coordinates
fn mouseToCell(xpos: f64, ypos: f64) struct { col: usize, row: usize } {
    const padding_d: f64 = 10;
    const tb_d: f64 = if (build_options.use_win32) @floatFromInt(win32_backend.TITLEBAR_HEIGHT) else 0;
    const col_f = (xpos - padding_d) / @as(f64, cell_width);
    const row_f = (ypos - padding_d - tb_d) / @as(f64, cell_height);

    const col = if (col_f < 0) 0 else if (col_f >= @as(f64, @floatFromInt(term_cols))) term_cols - 1 else @as(usize, @intFromFloat(col_f));
    const row = if (row_f < 0) 0 else if (row_f >= @as(f64, @floatFromInt(term_rows))) term_rows - 1 else @as(usize, @intFromFloat(row_f));

    return .{ .col = col, .row = row };
}

// Check if a cell is within the current selection
fn isCellSelected(col: usize, row: usize) bool {
    if (!activeSelection().active) return false;

    var start_row = activeSelection().start_row;
    var start_col = activeSelection().start_col;
    var end_row = activeSelection().end_row;
    var end_col = activeSelection().end_col;

    // Normalize
    if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
        std.mem.swap(usize, &start_row, &end_row);
        std.mem.swap(usize, &start_col, &end_col);
    }

    if (row < start_row or row > end_row) return false;
    if (row == start_row and row == end_row) {
        return col >= start_col and col <= end_col;
    }
    if (row == start_row) return col >= start_col;
    if (row == end_row) return col <= end_col;
    return true;
}

// ============================================================================
// GLFW-specific callbacks (only compiled for GLFW backend)
// ============================================================================

const glfw_callbacks = if (!build_options.use_win32) struct {
    pub fn charCallback(_: ?*c.GLFWwindow, codepoint: c_uint) callconv(.c) void {
        if (activePty()) |pty| {
            resetCursorBlink();
            if (activeTerminal()) |term| {
                term.scrollViewport(.bottom) catch {};
            }
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return;
            _ = pty.write(buf[0..len]) catch {};
        }
    }

    pub fn mouseButtonCallback(window: ?*c.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.c) void {
        if (button == c.GLFW_MOUSE_BUTTON_LEFT) {
            var xpos: f64 = 0;
            var ypos: f64 = 0;
            c.glfwGetCursorPos(window, &xpos, &ypos);
            const cell = mouseToCell(xpos, ypos);

            if (action == c.GLFW_PRESS) {
                activeSelection().start_col = cell.col;
                activeSelection().start_row = cell.row;
                activeSelection().end_col = cell.col;
                activeSelection().end_row = cell.row;
                activeSelection().active = false;
                g_selecting = true;
                g_click_x = xpos;
                g_click_y = ypos;
            } else if (action == c.GLFW_RELEASE) {
                g_selecting = false;
            }
        }
    }

    pub fn cursorPosCallback(_: ?*c.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
        if (g_selecting) {
            const cell = mouseToCell(xpos, ypos);
            activeSelection().end_col = cell.col;
            activeSelection().end_row = cell.row;

            const threshold = cell_width * 0.6;
            const padding_d: f64 = 10;
            const click_cell_x = g_click_x - padding_d - @as(f64, @floatFromInt(activeSelection().start_col)) * @as(f64, cell_width);
            const drag_cell_x = xpos - padding_d - @as(f64, @floatFromInt(cell.col)) * @as(f64, cell_width);

            const same_cell = (activeSelection().start_col == cell.col and activeSelection().start_row == cell.row);
            if (same_cell) {
                const moved_right = drag_cell_x >= threshold and click_cell_x < threshold;
                const moved_left = drag_cell_x < threshold and click_cell_x >= threshold;
                activeSelection().active = moved_right or moved_left;
            } else {
                activeSelection().active = true;
            }
        }
    }

    pub fn copySelectionToClipboard() void {
        const terminal = activeTerminal() orelse return;
        const window = g_window orelse return;
        const allocator = g_allocator orelse return;

        if (!activeSelection().active) return;

        var start_row = activeSelection().start_row;
        var start_col = activeSelection().start_col;
        var end_row = activeSelection().end_row;
        var end_col = activeSelection().end_col;

        if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
            std.mem.swap(usize, &start_row, &end_row);
            std.mem.swap(usize, &start_col, &end_col);
        }

        var text: std.ArrayListUnmanaged(u8) = .empty;
        defer text.deinit(allocator);

        const screen = terminal.screens.active;
        var row: usize = start_row;
        while (row <= end_row) : (row += 1) {
            const row_start_col = if (row == start_row) start_col else 0;
            const row_end_col = if (row == end_row) end_col else term_cols - 1;

            var col: usize = row_start_col;
            while (col <= row_end_col) : (col += 1) {
                const cell_data = screen.pages.getCell(.{ .viewport = .{
                    .x = @intCast(col),
                    .y = @intCast(row),
                } }) orelse continue;

                const cp = cell_data.cell.codepoint();
                if (cp == 0 or cp == ' ') {
                    text.append(allocator, ' ') catch continue;
                } else {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch continue;
                    text.appendSlice(allocator, buf[0..len]) catch continue;
                }
            }
            if (row < end_row) {
                text.append(allocator, '\n') catch {};
            }
        }

        if (text.items.len > 0) {
            text.append(allocator, 0) catch return;
            const str: [*:0]const u8 = @ptrCast(text.items.ptr);
            c.glfwSetClipboardString(window, str);
            std.debug.print("Copied {} bytes to clipboard\n", .{text.items.len - 1});
        }
    }

    pub fn pasteFromClipboard() void {
        const pty = activePty() orelse return;
        const window = g_window orelse return;

        const clipboard = c.glfwGetClipboardString(window);
        if (clipboard) |str| {
            var len: usize = 0;
            while (str[len] != 0) : (len += 1) {}
            std.debug.print("Pasting {} bytes from clipboard\n", .{len});
            if (len > 0) {
                _ = pty.write(str[0..len]) catch {};
            }
        } else {
            std.debug.print("Clipboard is empty or unavailable\n", .{});
        }
    }

    pub fn windowFocusCallback(_: ?*c.GLFWwindow, focused: c_int) callconv(.c) void {
        window_focused = focused != 0;
    }

    pub fn framebufferSizeCallback(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
        const padding_f: f32 = 10;
        const content_width = @as(f32, @floatFromInt(width)) - padding_f * 2;
        const content_height = @as(f32, @floatFromInt(height)) - padding_f * 2;

        const new_cols: u16 = @intFromFloat(@max(1, content_width / cell_width));
        const new_rows: u16 = @intFromFloat(@max(1, content_height / cell_height));

        if (new_cols != term_cols or new_rows != term_rows) {
            g_pending_resize = true;
            g_pending_cols = new_cols;
            g_pending_rows = new_rows;
            g_last_resize_time = std.time.milliTimestamp();
        }

        if (!g_resize_in_progress) {
            if (activeTerminal()) |terminal| {
                if (g_post_enabled) {
                    renderFrameWithPost(width, height, terminal, padding_f);
                } else {
                    gl.Viewport.?(0, 0, width, height);
                    setProjection(@floatFromInt(width), @floatFromInt(height));
                    gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
                    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
                    updateCursorBlink();
                    renderTerminal(terminal, @floatFromInt(height), padding_f, padding_f);
                }
            } else {
                gl.Viewport.?(0, 0, width, height);
                gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
                gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
            }
        }

        c.glfwSwapBuffers(window);
    }

    pub fn scrollCallback(_: ?*c.GLFWwindow, _: f64, yoffset: f64) callconv(.c) void {
        if (activeTerminal()) |terminal| {
            const delta: isize = @intFromFloat(-yoffset * 3);
            terminal.scrollViewport(.{ .delta = delta }) catch {};
        }
    }

    pub fn toggleFullscreen() void {
        const window = g_window orelse return;

        if (g_is_fullscreen) {
            c.glfwSetWindowMonitor(window, null, g_windowed_x, g_windowed_y, g_windowed_width, g_windowed_height, c.GLFW_DONT_CARE);
            g_is_fullscreen = false;
            std.debug.print("Exited fullscreen (restored {}x{} at {},{})\n", .{ g_windowed_width, g_windowed_height, g_windowed_x, g_windowed_y });
        } else {
            c.glfwGetWindowPos(window, &g_windowed_x, &g_windowed_y);
            c.glfwGetWindowSize(window, &g_windowed_width, &g_windowed_height);
            const monitor = c.glfwGetPrimaryMonitor() orelse return;
            const mode = c.glfwGetVideoMode(monitor) orelse return;
            c.glfwSetWindowMonitor(window, monitor, 0, 0, mode.*.width, mode.*.height, mode.*.refreshRate);
            g_is_fullscreen = true;
            std.debug.print("Entered fullscreen ({}x{} @{}Hz)\n", .{ mode.*.width, mode.*.height, mode.*.refreshRate });
        }
    }

    pub fn keyCallback(_: ?*c.GLFWwindow, key: c_int, _: c_int, action: c_int, mods: c_int) callconv(.c) void {
        if (action != c.GLFW_PRESS and action != c.GLFW_REPEAT) return;

        const ctrl = (mods & c.GLFW_MOD_CONTROL) != 0;
        const shift = (mods & c.GLFW_MOD_SHIFT) != 0;

        if (ctrl and shift and key == c.GLFW_KEY_C) { copySelectionToClipboard(); return; }
        if (ctrl and shift and key == c.GLFW_KEY_V) { pasteFromClipboard(); return; }
        if (ctrl and shift and key == c.GLFW_KEY_T) { _ = spawnTab(g_allocator orelse return); return; }
        if (ctrl and key == c.GLFW_KEY_W) {
            if (g_tab_count <= 1) {
                g_should_close = true;
            } else {
                closeTab(g_active_tab);
            }
            return;
        }
        if (ctrl and key == c.GLFW_KEY_TAB) {
            if (shift) {
                if (g_active_tab > 0) switchTab(g_active_tab - 1) else switchTab(g_tab_count - 1);
            } else {
                switchTab((g_active_tab + 1) % g_tab_count);
            }
            return;
        }
        if (ctrl and key == c.GLFW_KEY_COMMA) {
            std.debug.print("[keybind] Ctrl+, pressed\n", .{});
            if (g_allocator) |alloc| Config.openConfigInEditor(alloc);
            return;
        }

        const alt = (mods & c.GLFW_MOD_ALT) != 0;
        if (alt and key == c.GLFW_KEY_ENTER) { toggleFullscreen(); return; }

        if (activePty()) |pty| {
            const is_scroll_key = shift and (key == c.GLFW_KEY_PAGE_UP or key == c.GLFW_KEY_PAGE_DOWN);
            const is_modifier = key == c.GLFW_KEY_LEFT_SHIFT or key == c.GLFW_KEY_RIGHT_SHIFT or
                key == c.GLFW_KEY_LEFT_CONTROL or key == c.GLFW_KEY_RIGHT_CONTROL or
                key == c.GLFW_KEY_LEFT_ALT or key == c.GLFW_KEY_RIGHT_ALT or
                key == c.GLFW_KEY_LEFT_SUPER or key == c.GLFW_KEY_RIGHT_SUPER;
            if (!is_scroll_key and !is_modifier) {
                resetCursorBlink();
                if (activeTerminal()) |term| term.scrollViewport(.bottom) catch {};
            }

            const seq: ?[]const u8 = switch (key) {
                c.GLFW_KEY_ENTER => "\r",
                c.GLFW_KEY_BACKSPACE => "\x7f",
                c.GLFW_KEY_TAB => "\t",
                c.GLFW_KEY_ESCAPE => "\x1b",
                c.GLFW_KEY_UP => "\x1b[A",
                c.GLFW_KEY_DOWN => "\x1b[B",
                c.GLFW_KEY_RIGHT => "\x1b[C",
                c.GLFW_KEY_LEFT => "\x1b[D",
                c.GLFW_KEY_HOME => "\x1b[H",
                c.GLFW_KEY_END => "\x1b[F",
                c.GLFW_KEY_PAGE_UP => blk: {
                    if (shift) {
                        if (activeTerminal()) |term| term.scrollViewport(.{ .delta = -@as(isize, term_rows / 2) }) catch {};
                        break :blk null;
                    }
                    break :blk "\x1b[5~";
                },
                c.GLFW_KEY_PAGE_DOWN => blk: {
                    if (shift) {
                        if (activeTerminal()) |term| term.scrollViewport(.{ .delta = @as(isize, term_rows / 2) }) catch {};
                        break :blk null;
                    }
                    break :blk "\x1b[6~";
                },
                c.GLFW_KEY_INSERT => "\x1b[2~",
                c.GLFW_KEY_DELETE => "\x1b[3~",
                else => blk: {
                    if (ctrl and key >= c.GLFW_KEY_A and key <= c.GLFW_KEY_Z) {
                        const ctrl_char: u8 = @intCast(key - c.GLFW_KEY_A + 1);
                        _ = pty.write(&[_]u8{ctrl_char}) catch {};
                    }
                    break :blk null;
                },
            };

            if (seq) |s| _ = pty.write(s) catch {};
        }
    }
} else struct {};

// ============================================================================
// Win32-specific input processing (only compiled for Win32 backend)
// ============================================================================

const win32_input = if (build_options.use_win32) struct {

    /// Process all queued Win32 input events. Called once per frame from the main loop.
    pub fn processEvents(win: *win32_backend.Window) void {
        processKeyEvents(win);
        processCharEvents(win);
        processMouseButtonEvents(win);
        processMouseMoveEvents(win);
        processMouseWheelEvents(win);
        processSizeChange(win);
    }

    fn processKeyEvents(win: *win32_backend.Window) void {
        while (win.key_events.pop()) |ev| {
            handleKey(ev);
        }
    }

    fn processCharEvents(win: *win32_backend.Window) void {
        while (win.char_events.pop()) |ev| {
            handleChar(ev);
        }
    }

    fn processMouseButtonEvents(win: *win32_backend.Window) void {
        while (win.mouse_button_events.pop()) |ev| {
            handleMouseButton(ev);
        }
    }

    fn processMouseMoveEvents(win: *win32_backend.Window) void {
        // Only process the latest move event (coalesce)
        var latest: ?win32_backend.MouseMoveEvent = null;
        while (win.mouse_move_events.pop()) |ev| {
            latest = ev;
        }
        if (latest) |ev| {
            handleMouseMove(ev);
        }
    }

    fn processMouseWheelEvents(win: *win32_backend.Window) void {
        while (win.mouse_wheel_events.pop()) |ev| {
            handleMouseWheel(ev);
        }
    }

    fn processSizeChange(win: *win32_backend.Window) void {
        if (!win.size_changed) return;
        win.size_changed = false;

        const width = win.width;
        const height = win.height;
        const padding_f: f32 = 10;
        const tb_offset: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
        const content_width = @as(f32, @floatFromInt(width)) - padding_f * 2;
        const content_height = @as(f32, @floatFromInt(height)) - padding_f - (padding_f + tb_offset);

        const new_cols: u16 = @intFromFloat(@max(1, content_width / cell_width));
        const new_rows: u16 = @intFromFloat(@max(1, content_height / cell_height));

        if (new_cols != term_cols or new_rows != term_rows) {
            g_pending_resize = true;
            g_pending_cols = new_cols;
            g_pending_rows = new_rows;
            g_last_resize_time = std.time.milliTimestamp();
        }
    }

    fn handleChar(ev: win32_backend.CharEvent) void {
        if (!isActiveTabTerminal()) return;
        const pty = activePty() orelse return;
        resetCursorBlink();
        if (activeTerminal()) |term| {
            term.scrollViewport(.bottom) catch {};
        }
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(ev.codepoint, &buf) catch return;
        _ = pty.write(buf[0..len]) catch {};
    }

    fn handleKey(ev: win32_backend.KeyEvent) void {
        // Ctrl+Shift+C = copy
        if (ev.ctrl and ev.shift and ev.vk == 0x43) { // 'C'
            copySelectionToClipboard();
            return;
        }
        // Ctrl+Shift+V = paste
        if (ev.ctrl and ev.shift and ev.vk == 0x56) { // 'V'
            pasteFromClipboard();
            return;
        }
        // Ctrl+Shift+T = new tab
        if (ev.ctrl and ev.shift and ev.vk == 0x54) { // 'T'
            _ = spawnTab(g_allocator orelse return);
            return;
        }
        // Ctrl+W = close tab, or close app if only 1 tab
        if (ev.ctrl and ev.vk == 0x57) { // 'W'
            if (g_tab_count <= 1) {
                g_should_close = true;
            } else {
                closeTab(g_active_tab);
            }
            return;
        }
        // Ctrl+Tab = next tab
        if (ev.ctrl and ev.vk == win32_backend.VK_TAB) {
            if (ev.shift) {
                // Ctrl+Shift+Tab = previous tab
                if (g_active_tab > 0) switchTab(g_active_tab - 1) else switchTab(g_tab_count - 1);
            } else {
                switchTab((g_active_tab + 1) % g_tab_count);
            }
            return;
        }
        // Ctrl+1-9 = switch to tab N
        if (ev.ctrl and !ev.shift and ev.vk >= 0x31 and ev.vk <= 0x39) { // '1'-'9'
            const tab_idx = @as(usize, @intCast(ev.vk - 0x31));
            if (tab_idx < g_tab_count) switchTab(tab_idx);
            return;
        }
        // Ctrl+, = open config
        if (ev.ctrl and ev.vk == win32_backend.VK_OEM_COMMA) {
            std.debug.print("[keybind] Ctrl+, pressed\n", .{});
            if (g_allocator) |alloc| Config.openConfigInEditor(alloc);
            return;
        }
        // Alt+Enter = toggle fullscreen
        if (ev.alt and ev.vk == win32_backend.VK_RETURN) {
            toggleFullscreen();
            return;
        }

        // Don't send input to PTY if active tab isn't the terminal
        if (!isActiveTabTerminal()) return;

        const pty = activePty() orelse return;

        // Don't reset blink / scroll-to-bottom for scroll keys or pure modifiers
        const is_scroll_key = ev.shift and (ev.vk == win32_backend.VK_PRIOR or ev.vk == win32_backend.VK_NEXT);
        const is_modifier = ev.vk == win32_backend.VK_SHIFT or ev.vk == win32_backend.VK_CONTROL or ev.vk == win32_backend.VK_MENU;
        if (!is_scroll_key and !is_modifier) {
            resetCursorBlink();
            if (activeTerminal()) |term| term.scrollViewport(.bottom) catch {};
        }

        const seq: ?[]const u8 = switch (ev.vk) {
            win32_backend.VK_RETURN => "\r",
            win32_backend.VK_BACK => "\x7f",
            win32_backend.VK_TAB => "\t",
            win32_backend.VK_ESCAPE => "\x1b",
            win32_backend.VK_UP => "\x1b[A",
            win32_backend.VK_DOWN => "\x1b[B",
            win32_backend.VK_RIGHT => "\x1b[C",
            win32_backend.VK_LEFT => "\x1b[D",
            win32_backend.VK_HOME => "\x1b[H",
            win32_backend.VK_END => "\x1b[F",
            win32_backend.VK_PRIOR => blk: { // Page Up
                if (ev.shift) {
                    if (activeTerminal()) |term| term.scrollViewport(.{ .delta = -@as(isize, term_rows / 2) }) catch {};
                    break :blk null;
                }
                break :blk "\x1b[5~";
            },
            win32_backend.VK_NEXT => blk: { // Page Down
                if (ev.shift) {
                    if (activeTerminal()) |term| term.scrollViewport(.{ .delta = @as(isize, term_rows / 2) }) catch {};
                    break :blk null;
                }
                break :blk "\x1b[6~";
            },
            win32_backend.VK_INSERT => "\x1b[2~",
            win32_backend.VK_DELETE => "\x1b[3~",
            win32_backend.VK_F11 => blk: {
                toggleFullscreen();
                break :blk null;
            },
            else => blk: {
                // Ctrl+A through Ctrl+Z
                if (ev.ctrl and ev.vk >= 0x41 and ev.vk <= 0x5A) {
                    // Don't send Ctrl+C/V when shift is held (those are copy/paste)
                    if (!ev.shift) {
                        const ctrl_char: u8 = @intCast(ev.vk - 0x41 + 1);
                        _ = pty.write(&[_]u8{ctrl_char}) catch {};
                    }
                }
                break :blk null;
            },
        };

        if (seq) |s| _ = pty.write(s) catch {};
    }

    var plus_btn_pressed: bool = false;

    fn handleMouseButton(ev: win32_backend.MouseButtonEvent) void {
        // Middle-click on tab to close it
        if (ev.button == .middle and ev.action == .release) {
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            const titlebar_h: f64 = if (g_window) |w| @floatFromInt(w.titlebar_height) else 40;
            if (ypos < titlebar_h) {
                if (hitTestTab(xpos)) |tab_idx| {
                    if (g_tab_count <= 1) {
                        g_should_close = true;
                    } else {
                        closeTab(tab_idx);
                    }
                }
            }
            return;
        }

        if (ev.button == .left) {
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            const titlebar_h: f64 = if (g_window) |w| @floatFromInt(w.titlebar_height) else 40;

            if (ev.action == .press) {
                // Check if click is in the titlebar (tab bar area)
                if (ypos < titlebar_h) {
                    handleTabBarPress(xpos);
                    return;
                }

                const cell_pos = mouseToCell(xpos, ypos);
                activeSelection().start_col = cell_pos.col;
                activeSelection().start_row = cell_pos.row;
                activeSelection().end_col = cell_pos.col;
                activeSelection().end_row = cell_pos.row;
                activeSelection().active = false;
                g_selecting = true;
                g_click_x = xpos;
                g_click_y = ypos;
            } else {
                // Mouse up
                if (plus_btn_pressed) {
                    plus_btn_pressed = false;
                    // Only fire if still in the + button area
                    if (ypos < titlebar_h and hitTestPlusButton(xpos)) {
                        _ = spawnTab(g_allocator orelse return);
                    }
                    return;
                }
                g_selecting = false;
            }
        }
    }

    fn handleTabBarPress(xpos: f64) void {
        const win = g_window orelse return;
        const window_width: f64 = blk: {
            var rect: win32_backend.RECT = undefined;
            _ = win32_backend.GetClientRect(win.hwnd, &rect);
            break :blk @floatFromInt(rect.right);
        };

        const caption_area_w: f64 = 46 * 3;
        const gap_w: f64 = 42;
        const plus_btn_w: f64 = 46;
        const show_plus = g_tab_count > 1;
        const num_tabs = g_tab_count;

        const plus_total: f64 = if (show_plus) plus_btn_w else 0;
        const right_reserved: f64 = caption_area_w + gap_w + plus_total;
        const tab_area_w: f64 = window_width - right_reserved;
        const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

        // Check which tab was clicked
        var cursor: f64 = 0;
        for (0..num_tabs) |tab_idx| {
            if (xpos >= cursor and xpos < cursor + tab_w) {
                switchTab(tab_idx);
                return;
            }
            cursor += tab_w;
        }

        // Check if + button was pressed
        if (show_plus and xpos >= cursor and xpos < cursor + plus_btn_w) {
            plus_btn_pressed = true;
        }
    }

    fn hitTestTab(xpos: f64) ?usize {
        const win = g_window orelse return null;
        const window_width: f64 = blk: {
            var rect: win32_backend.RECT = undefined;
            _ = win32_backend.GetClientRect(win.hwnd, &rect);
            break :blk @floatFromInt(rect.right);
        };

        const caption_area_w: f64 = 46 * 3;
        const gap_w: f64 = 42;
        const plus_btn_w: f64 = 46;
        const show_plus = g_tab_count > 1;
        const num_tabs = g_tab_count;

        const plus_total: f64 = if (show_plus) plus_btn_w else 0;
        const right_reserved: f64 = caption_area_w + gap_w + plus_total;
        const tab_area_w: f64 = window_width - right_reserved;
        const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

        var cursor: f64 = 0;
        for (0..num_tabs) |tab_idx| {
            if (xpos >= cursor and xpos < cursor + tab_w) {
                return tab_idx;
            }
            cursor += tab_w;
        }
        return null;
    }

    fn hitTestPlusButton(xpos: f64) bool {
        const win = g_window orelse return false;
        const window_width: f64 = blk: {
            var rect: win32_backend.RECT = undefined;
            _ = win32_backend.GetClientRect(win.hwnd, &rect);
            break :blk @floatFromInt(rect.right);
        };

        const caption_area_w: f64 = 46 * 3;
        const gap_w: f64 = 42;
        const plus_btn_w: f64 = 46;
        if (g_tab_count <= 1) return false;

        const right_reserved: f64 = caption_area_w + gap_w + plus_btn_w;
        const tab_area_w: f64 = window_width - right_reserved;
        const tab_w: f64 = tab_area_w / @as(f64, @floatFromInt(g_tab_count));
        const plus_x = tab_w * @as(f64, @floatFromInt(g_tab_count));

        return xpos >= plus_x and xpos < plus_x + plus_btn_w;
    }

    fn handleMouseMove(ev: win32_backend.MouseMoveEvent) void {
        if (!g_selecting) return;

        const xpos: f64 = @floatFromInt(ev.x);
        const ypos: f64 = @floatFromInt(ev.y);
        const cell_pos = mouseToCell(xpos, ypos);
        activeSelection().end_col = cell_pos.col;
        activeSelection().end_row = cell_pos.row;

        const threshold = cell_width * 0.6;
        const padding_d: f64 = 10;
        const click_cell_x = g_click_x - padding_d - @as(f64, @floatFromInt(activeSelection().start_col)) * @as(f64, cell_width);
        const drag_cell_x = xpos - padding_d - @as(f64, @floatFromInt(cell_pos.col)) * @as(f64, cell_width);

        const same_cell = (activeSelection().start_col == cell_pos.col and activeSelection().start_row == cell_pos.row);
        if (same_cell) {
            const moved_right = drag_cell_x >= threshold and click_cell_x < threshold;
            const moved_left = drag_cell_x < threshold and click_cell_x >= threshold;
            activeSelection().active = moved_right or moved_left;
        } else {
            activeSelection().active = true;
        }
    }

    fn handleMouseWheel(ev: win32_backend.MouseWheelEvent) void {
        if (activeTerminal()) |terminal| {
            // WHEEL_DELTA is 120 per notch. Convert to lines (3 lines per notch, like GLFW).
            const notches = @as(f64, @floatFromInt(ev.delta)) / 120.0;
            const delta: isize = @intFromFloat(-notches * 3);
            terminal.scrollViewport(.{ .delta = delta }) catch {};
        }
    }

    // --- Clipboard (Win32 native) ---

    fn copySelectionToClipboard() void {
        const terminal = activeTerminal() orelse return;
        const allocator = g_allocator orelse return;
        const win = g_window orelse return;

        if (!activeSelection().active) return;

        var start_row = activeSelection().start_row;
        var start_col = activeSelection().start_col;
        var end_row = activeSelection().end_row;
        var end_col = activeSelection().end_col;

        if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
            std.mem.swap(usize, &start_row, &end_row);
            std.mem.swap(usize, &start_col, &end_col);
        }

        var text: std.ArrayListUnmanaged(u8) = .empty;
        defer text.deinit(allocator);

        const screen = terminal.screens.active;
        var row: usize = start_row;
        while (row <= end_row) : (row += 1) {
            const row_start_col = if (row == start_row) start_col else 0;
            const row_end_col = if (row == end_row) end_col else term_cols - 1;

            var col: usize = row_start_col;
            while (col <= row_end_col) : (col += 1) {
                const cell_data = screen.pages.getCell(.{ .viewport = .{
                    .x = @intCast(col),
                    .y = @intCast(row),
                } }) orelse continue;

                const cp = cell_data.cell.codepoint();
                if (cp == 0 or cp == ' ') {
                    text.append(allocator, ' ') catch continue;
                } else {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch continue;
                    text.appendSlice(allocator, buf[0..len]) catch continue;
                }
            }
            if (row < end_row) {
                text.append(allocator, '\n') catch {};
            }
        }

        if (text.items.len == 0) return;

        // Win32 clipboard: OpenClipboard → EmptyClipboard → SetClipboardData → CloseClipboard
        if (win32_backend.OpenClipboard(win.hwnd) == 0) return;
        defer _ = win32_backend.CloseClipboard();
        _ = win32_backend.EmptyClipboard();

        // Clipboard wants a GlobalAlloc'd GMEM_MOVEABLE buffer with null-terminated data
        const size = text.items.len + 1;
        const hmem = win32_backend.GlobalAlloc(0x0002, size) orelse return; // GMEM_MOVEABLE
        const ptr = win32_backend.GlobalLock(hmem) orelse return;
        const dest: [*]u8 = @ptrCast(ptr);
        @memcpy(dest[0..text.items.len], text.items);
        dest[text.items.len] = 0;
        _ = win32_backend.GlobalUnlock(hmem);

        _ = win32_backend.SetClipboardData(1, hmem); // CF_TEXT = 1
        std.debug.print("Copied {} bytes to clipboard\n", .{text.items.len});
    }

    fn pasteFromClipboard() void {
        const pty = activePty() orelse return;
        const win = g_window orelse return;

        if (win32_backend.OpenClipboard(win.hwnd) == 0) return;
        defer _ = win32_backend.CloseClipboard();

        const hmem = win32_backend.GetClipboardData(1) orelse return; // CF_TEXT
        const ptr = win32_backend.GlobalLock(hmem) orelse return;
        defer _ = win32_backend.GlobalUnlock(hmem);

        const data: [*]const u8 = @ptrCast(ptr);
        var len: usize = 0;
        while (data[len] != 0) : (len += 1) {}

        if (len > 0) {
            std.debug.print("Pasting {} bytes from clipboard\n", .{len});
            _ = pty.write(data[0..len]) catch {};
        }
    }

    // --- Fullscreen toggle (Win32 native) ---

    var saved_style: win32_backend.DWORD = 0;
    var saved_rect: win32_backend.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var is_fullscreen: bool = false;

    fn toggleFullscreen() void {
        const win = g_window orelse return;

        if (is_fullscreen) {
            // Restore windowed mode
            _ = win32_backend.SetWindowLongW(win.hwnd, -16, @bitCast(saved_style)); // GWL_STYLE
            _ = win32_backend.SetWindowPos(
                win.hwnd, null,
                saved_rect.left, saved_rect.top,
                saved_rect.right - saved_rect.left,
                saved_rect.bottom - saved_rect.top,
                0x0020 | 0x0040, // SWP_FRAMECHANGED | SWP_SHOWWINDOW
            );
            is_fullscreen = false;
            if (g_window) |w| w.is_fullscreen = false;
            std.debug.print("Exited fullscreen\n", .{});
        } else {
            // Save current state
            _ = win32_backend.GetWindowRect(win.hwnd, &saved_rect);
            saved_style = @bitCast(win32_backend.GetWindowLongW(win.hwnd, -16));

            // Set borderless style
            const new_style = saved_style & ~@as(u32, 0x00CF0000); // remove WS_OVERLAPPEDWINDOW
            _ = win32_backend.SetWindowLongW(win.hwnd, -16, @bitCast(new_style));

            // Get monitor info for the monitor containing this window
            const monitor = win32_backend.MonitorFromWindow(win.hwnd, 0x00000002) orelse return; // MONITOR_DEFAULTTONEAREST
            var mi = win32_backend.MONITORINFO{ .cbSize = @sizeOf(win32_backend.MONITORINFO) };
            if (win32_backend.GetMonitorInfoW(monitor, &mi) != 0) {
                _ = win32_backend.SetWindowPos(
                    win.hwnd, null,
                    mi.rcMonitor.left, mi.rcMonitor.top,
                    mi.rcMonitor.right - mi.rcMonitor.left,
                    mi.rcMonitor.bottom - mi.rcMonitor.top,
                    0x0020 | 0x0040, // SWP_FRAMECHANGED | SWP_SHOWWINDOW
                );
            }
            is_fullscreen = true;
            if (g_window) |w| w.is_fullscreen = true;
            std.debug.print("Entered fullscreen\n", .{});
        }
    }
} else struct {};

fn setProjection(width: f32, height: f32) void {
    const projection = [16]f32{
        2.0 / width, 0.0,          0.0,  0.0,
        0.0,         2.0 / height, 0.0,  0.0,
        0.0,         0.0,          -1.0, 0.0,
        -1.0,        -1.0,         0.0,  1.0,
    };

    gl.UseProgram.?(shader_program);
    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(shader_program, "projection"), 1, c.GL_FALSE, &projection);
}

pub fn main() !void {
    std.debug.print("Phantty starting...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Handle special commands before loading full config
    if (Config.hasCommand(allocator, "help") or Config.hasCommand(allocator, "h")) {
        Config.printHelp();
        return;
    }
    if (Config.hasCommand(allocator, "list-fonts")) {
        try listSystemFonts(allocator);
        return;
    }
    if (Config.hasCommand(allocator, "list-themes")) {
        Config.listThemes();
        return;
    }
    if (Config.hasCommand(allocator, "test-font-discovery")) {
        try testFontDiscovery(allocator);
        return;
    }
    if (Config.hasCommand(allocator, "show-config-path")) {
        Config.printConfigPath(allocator);
        return;
    }

    // Load configuration: defaults → config file → CLI flags
    const cfg = try Config.load(allocator);
    defer cfg.deinit(allocator);

    // Apply config to globals
    g_theme = cfg.resolved_theme;
    g_cursor_style = cfg.@"cursor-style";
    g_cursor_blink = cfg.@"cursor-style-blink";
    // Apply window size from config (0 = auto, use defaults)
    if (cfg.@"window-width" > 0) term_cols = cfg.@"window-width";
    if (cfg.@"window-height" > 0) term_rows = cfg.@"window-height";

    const requested_font = cfg.@"font-family";
    const requested_weight = cfg.@"font-style".toDwriteWeight();
    const font_size = cfg.@"font-size";
    const shader_path = cfg.@"custom-shader";

    if (cfg.config_path) |path| {
        std.debug.print("Config loaded from: {s}\n", .{path});
    } else {
        std.debug.print("No config file found, using defaults\n", .{});
    }

    // Store allocator and config globals (needed by spawnTab, closeTab, etc.)
    g_allocator = allocator;
    g_scrollback_limit = cfg.@"scrollback-limit";

    // Resolve shell command from config and store globally for tab spawning
    {
        const cmd = cfg.shell;
        if (std.mem.eql(u8, cmd, "cmd")) {
            const lit = std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
            @memcpy(g_shell_cmd_buf[0..lit.len], lit);
            g_shell_cmd_buf[lit.len] = 0;
            g_shell_cmd_len = lit.len;
        } else if (std.mem.eql(u8, cmd, "powershell")) {
            const lit = std.unicode.utf8ToUtf16LeStringLiteral("powershell.exe");
            @memcpy(g_shell_cmd_buf[0..lit.len], lit);
            g_shell_cmd_buf[lit.len] = 0;
            g_shell_cmd_len = lit.len;
        } else if (std.mem.eql(u8, cmd, "pwsh")) {
            const lit = std.unicode.utf8ToUtf16LeStringLiteral("pwsh.exe");
            @memcpy(g_shell_cmd_buf[0..lit.len], lit);
            g_shell_cmd_buf[lit.len] = 0;
            g_shell_cmd_len = lit.len;
        } else if (std.mem.eql(u8, cmd, "wsl")) {
            const lit = std.unicode.utf8ToUtf16LeStringLiteral("wsl.exe");
            @memcpy(g_shell_cmd_buf[0..lit.len], lit);
            g_shell_cmd_buf[lit.len] = 0;
            g_shell_cmd_len = lit.len;
        } else {
            const len = std.unicode.utf8ToUtf16Le(&g_shell_cmd_buf, cmd) catch 0;
            g_shell_cmd_buf[len] = 0;
            g_shell_cmd_len = len;
        }
        std.debug.print("Shell command resolved: '{s}'\n", .{cfg.shell});
    }

    // Spawn the initial tab (PTY + terminal)
    if (!spawnTab(allocator)) {
        std.debug.print("Failed to spawn initial tab\n", .{});
        return error.SpawnFailed;
    }

    // ================================================================
    // Initialize windowing backend
    // Defers MUST be at function scope so the window/GL context
    // stays alive for the rest of main().
    // ================================================================

    // --- Win32 backend state (only used when use_win32=true) ---
    var win32_window: if (build_options.use_win32) win32_backend.Window else void = undefined;
    if (build_options.use_win32) {
        const title = std.unicode.utf8ToUtf16LeStringLiteral("Phantty [win32]");
        win32_window = win32_backend.Window.init(800, 600, title) catch |err| {
            std.debug.print("Failed to create Win32 window: {}\n", .{err});
            return err;
        };
        win32_backend.setGlobalWindow(&win32_window);
        g_window = &win32_window;
    }
    defer if (build_options.use_win32) {
        win32_window.deinit();
    };

    // --- GLFW backend state (only used when use_win32=false) ---
    if (!build_options.use_win32) {
        if (c.glfwInit() == 0) {
            std.debug.print("Failed to initialize GLFW\n", .{});
            return error.GLFWInitFailed;
        }
    }
    defer if (!build_options.use_win32) {
        c.glfwTerminate();
    };

    // GLFW window handle — needs to be at function scope so the defer works
    var glfw_window: if (build_options.use_win32) void else ?*c.GLFWwindow = if (build_options.use_win32) {} else null;
    if (!build_options.use_win32) {
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 3);
        c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);

        glfw_window = c.glfwCreateWindow(800, 600, "Phantty [glfw]", null, null);
        if (glfw_window == null) {
            std.debug.print("Failed to create GLFW window\n", .{});
            return error.WindowCreationFailed;
        }

        c.glfwMakeContextCurrent(glfw_window);

        // Set up input callbacks
        _ = c.glfwSetCharCallback(glfw_window, glfw_callbacks.charCallback);
        _ = c.glfwSetKeyCallback(glfw_window, glfw_callbacks.keyCallback);
        _ = c.glfwSetScrollCallback(glfw_window, glfw_callbacks.scrollCallback);
        _ = c.glfwSetMouseButtonCallback(glfw_window, glfw_callbacks.mouseButtonCallback);
        _ = c.glfwSetCursorPosCallback(glfw_window, glfw_callbacks.cursorPosCallback);
        _ = c.glfwSetFramebufferSizeCallback(glfw_window, glfw_callbacks.framebufferSizeCallback);
        _ = c.glfwSetWindowFocusCallback(glfw_window, glfw_callbacks.windowFocusCallback);

        g_window = glfw_window;
    }
    defer if (!build_options.use_win32) {
        if (glfw_window) |w| c.glfwDestroyWindow(w);
    };

    // --- Load OpenGL via GLAD ---
    {
        const version = if (build_options.use_win32)
            c.gladLoadGLContext(&gl, @ptrCast(&win32_backend.glGetProcAddress))
        else
            c.gladLoadGLContext(&gl, @ptrCast(&c.glfwGetProcAddress));

        if (version == 0) {
            std.debug.print("Failed to initialize GLAD\n", .{});
            return error.GLADInitFailed;
        }
        const backend_tag = if (build_options.use_win32) " (Win32 backend)" else "";
        std.debug.print("OpenGL {}.{}{s}\n", .{ c.GLAD_VERSION_MAJOR(version), c.GLAD_VERSION_MINOR(version), backend_tag });
    }

    // Initialize FreeType
    const ft_lib = freetype.Library.init() catch |err| {
        std.debug.print("Failed to initialize FreeType: {}\n", .{err});
        return err;
    };
    defer ft_lib.deinit();

    // Store globally for fallback font loading
    g_ft_lib = ft_lib;
    defer g_ft_lib = null;

    std.debug.print("Requested font: {s} (weight: {})\n", .{ requested_font, @intFromEnum(requested_weight) });
    std.debug.print("Cursor style: {s}, blink: {}\n", .{ @tagName(g_cursor_style), g_cursor_blink });

    // Initialize DirectWrite for font discovery (keep alive for fallback lookups)
    var dw_discovery: ?directwrite.FontDiscovery = directwrite.FontDiscovery.init() catch |err| blk: {
        std.debug.print("DirectWrite init failed: {}\n", .{err});
        break :blk null;
    };
    defer if (dw_discovery) |*dw| dw.deinit();

    // Store globally for fallback font lookups
    g_font_discovery = if (dw_discovery) |*dw| dw else null;
    defer g_font_discovery = null;

    // Fallback faces are cleaned up in the main defer block (with glyph_face)

    // Try to find the requested font via DirectWrite
    var font_result: ?directwrite.FontDiscovery.FontResult = null;

    if (dw_discovery) |*dw| {
        if (requested_font.len > 0) {
            if (dw.findFontFilePath(allocator, requested_font, requested_weight, .NORMAL) catch null) |result| {
                font_result = result;
                std.debug.print("Found system font: {s}\n", .{result.path});
            } else {
                std.debug.print("Font '{s}' not found, will use embedded fallback\n", .{requested_font});
            }
        } else {
            std.debug.print("No font-family set, will use embedded fallback\n", .{});
        }
    }

    defer if (font_result) |*fr| fr.deinit();

    // Load the font with FreeType
    const face: freetype.Face = blk: {
        // Try system font first
        if (font_result) |fr| {
            if (ft_lib.initFace(fr.path, @intCast(fr.face_index))) |f| {
                break :blk f;
            } else |err| {
                std.debug.print("Failed to load system font: {}, using embedded fallback\n", .{err});
            }
        }

        // Fall back to embedded JetBrains Mono
        std.debug.print("Using embedded JetBrains Mono as fallback\n", .{});
        break :blk ft_lib.initMemoryFace(embedded.regular, 0) catch |err| {
            std.debug.print("Failed to load embedded font: {}\n", .{err});
            return err;
        };
    };
    // Don't defer face.deinit() here — glyph_face owns it and may be
    // replaced by hot-reload. Cleanup is in the defer block below.

    face.setCharSize(0, @as(i32, @intCast(font_size)) * 64, 96, 96) catch |err| {
        std.debug.print("Failed to set font size: {}\n", .{err});
        return err;
    };

    // Store font size globally for fallback fonts
    g_font_size = font_size;

    if (!initShaders()) {
        std.debug.print("Failed to initialize shaders\n", .{});
        return error.ShaderInitFailed;
    }
    initBuffers();
    preloadCharacters(face);

    // Load Segoe MDL2 Assets for caption button icons (Windows system font)
    // Size is DPI-dependent: 10px at 96 DPI, scales proportionally
    if (ft_lib.initFace("C:\\Windows\\Fonts\\segmdl2.ttf", 0)) |iface| {
        const dpi: u32 = if (build_options.use_win32)
            (if (g_window) |w| win32_backend.GetDpiForWindow(w.hwnd) else 96)
        else
            96;
        // 10px at 96 DPI = 10pt at 72 DPI. Scale for actual DPI.
        const icon_size_26_6: i32 = @intCast(10 * 64 * dpi / 96);
        iface.setCharSize(0, icon_size_26_6, 72, 72) catch {};
        icon_face = iface;
        std.debug.print("Loaded Segoe MDL2 Assets for caption icons (dpi={})\n", .{dpi});
    } else |_| {
        std.debug.print("Segoe MDL2 Assets not found, using quad-based caption icons\n", .{});
    }

    defer {
        // Clean up icon font
        if (icon_face) |f| {
            f.deinit();
            icon_face = null;
        }
        // Clean up the current font face (may have been replaced by hot-reload)
        if (glyph_face) |f| f.deinit();
        glyph_face = null;
        // Clean up glyph cache textures
        clearGlyphCache(allocator);
        clearFallbackFaces(allocator);
        // Clean up icon cache
        var icon_it = icon_cache.iterator();
        while (icon_it.next()) |entry| {
            gl.DeleteTextures.?(1, &entry.value_ptr.texture_id);
        }
        icon_cache.deinit(allocator);
    }
    initSolidTexture();

    // Initialize custom post-processing shader if requested
    if (shader_path) |sp| {
        if (initPostShader(allocator, sp)) {
            g_post_enabled = true;
            g_start_time = std.time.milliTimestamp();
        } else {
            std.debug.print("Warning: custom shader failed to load, continuing without it\n", .{});
        }
    }
    defer {
        if (g_post_enabled) {
            gl.DeleteProgram.?(g_post_program);
            gl.DeleteVertexArrays.?(1, &g_post_vao);
            gl.DeleteBuffers.?(1, &g_post_vbo);
            if (g_post_fbo != 0) {
                gl.DeleteFramebuffers.?(1, &g_post_fbo);
                gl.DeleteTextures.?(1, &g_post_texture);
            }
        }
    }

    // Calculate window size based on cell dimensions (small padding for aesthetics)
    const padding: f32 = 10;
    // Extra top offset for custom title bar (Win32 backend only)
    const titlebar_offset: f32 = if (build_options.use_win32) @floatFromInt(win32_backend.TITLEBAR_HEIGHT) else 0;
    const top_padding: f32 = padding + titlebar_offset;

    const content_width: f32 = cell_width * @as(f32, @floatFromInt(term_cols));
    const content_height: f32 = cell_height * @as(f32, @floatFromInt(term_rows));
    const window_width: i32 = @intFromFloat(content_width + padding * 2);
    const window_height: i32 = @intFromFloat(content_height + padding + top_padding);
    if (build_options.use_win32) {
        if (g_window) |w| w.setSize(window_width, window_height);
    } else {
        c.glfwSetWindowSize(glfw_window, window_width, window_height);
    }

    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    std.debug.print("Ready! Cell size: {d:.1}x{d:.1}\n", .{ cell_width, cell_height });

    // Ensure config directory + file exist so the watcher can observe from startup
    Config.ensureConfigExists(allocator);

    // Set up config file watcher (ReadDirectoryChangesW)
    var config_watcher = ConfigWatcher.init(allocator);
    if (config_watcher == null) {
        std.debug.print("Config watcher not available (config directory may not exist)\n", .{});
    }
    defer if (config_watcher) |*w| w.deinit();

    // Buffer for reading PTY output
    var pty_buffer: [4096]u8 = undefined;

    // Main loop — shared logic with backend-specific window management
    var running = true;
    while (running) {
        // Check for config file changes
        if (config_watcher) |*w| checkConfigReload(allocator, w);

        // Process pending resize (coalesced, like Ghostty)
        // We wait for RESIZE_COALESCE_MS after last resize event before applying
        if (g_pending_resize) {
            const now = std.time.milliTimestamp();
            if (now - g_last_resize_time >= RESIZE_COALESCE_MS) {
                g_pending_resize = false;

                if (g_pending_cols != term_cols or g_pending_rows != term_rows) {
                    // Mark resize in progress to prevent rendering with inconsistent state
                    g_resize_in_progress = true;
                    defer g_resize_in_progress = false;

                    term_cols = g_pending_cols;
                    term_rows = g_pending_rows;

                    // Resize ALL tabs' terminals and PTYs
                    for (0..g_tab_count) |ti| {
                        if (g_tabs[ti]) |tab| {
                            tab.terminal.resize(allocator, term_cols, term_rows) catch |err| {
                                std.debug.print("Terminal resize error (tab {}): {}\n", .{ ti, err });
                            };
                            tab.pty.resize(term_cols, term_rows);
                        }
                    }

                    // Scroll active tab to bottom after resize
                    if (activeTerminal()) |term| {
                        term.scrollViewport(.{ .bottom = {} }) catch {};
                    }
                }
            }
        }

        // Read from ALL tabs' PTYs (drain background tabs so they don't block)
        for (0..g_tab_count) |ti| {
            if (g_tabs[ti]) |tab| {
                resetOscBatch(tab);
                var stream = tab.terminal.vtStream();
                while (tab.pty.dataAvailable() > 0) {
                    const bytes_read = tab.pty.read(&pty_buffer) catch break;
                    if (bytes_read == 0) break;
                    scanForOscTitle(tab, pty_buffer[0..bytes_read]);
                    stream.nextSlice(pty_buffer[0..bytes_read]) catch {};
                }
            }
        }

        // Get framebuffer size and render
        if (build_options.use_win32) {
            const win = g_window orelse break;

            // Poll Win32 messages (fills event queues + checks WM_QUIT)
            running = win.pollEvents() and !g_should_close;

            // Sync tab count to win32 for hit-testing
            win.tab_count = g_tab_count;

            // Process all queued input events (keyboard, mouse, resize)
            win32_input.processEvents(win);

            // Update focus state
            window_focused = win.focused;

            const fb = win.getFramebufferSize();
            const fb_width: c_int = fb.width;
            const fb_height: c_int = fb.height;

            if (g_post_enabled) {
                if (activeTerminal()) |term| {
                    renderFrameWithPost(fb_width, fb_height, term, padding);
                }
            } else {
                gl.Viewport.?(0, 0, fb_width, fb_height);
                setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
                gl.Clear.?(c.GL_COLOR_BUFFER_BIT);

                // Draw titlebar background
                renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);

                if (activeTerminal()) |term| {
                    updateCursorBlink();
                    renderTerminal(term, @floatFromInt(fb_height), padding, top_padding);
                }
            }

            win.swapBuffers();
        } else {
            var fb_width: c_int = 0;
            var fb_height: c_int = 0;
            c.glfwGetFramebufferSize(glfw_window, &fb_width, &fb_height);

            if (g_post_enabled) {
                if (activeTerminal()) |term| {
                    renderFrameWithPost(fb_width, fb_height, term, padding);
                }
            } else {
                gl.Viewport.?(0, 0, fb_width, fb_height);
                setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
                gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
                if (activeTerminal()) |term| {
                    updateCursorBlink();
                    renderTerminal(term, @floatFromInt(fb_height), padding, padding);
                }
            }

            c.glfwSwapBuffers(glfw_window);
            c.glfwPollEvents();
            running = c.glfwWindowShouldClose(glfw_window) == 0 and !g_should_close;
        }
    }

    // Clean up all tabs
    for (0..g_tab_count) |ti| {
        if (g_tabs[ti]) |tab| {
            tab.deinit(allocator);
            allocator.destroy(tab);
            g_tabs[ti] = null;
        }
    }
    g_tab_count = 0;

    std.debug.print("Phantty exiting...\n", .{});
}
