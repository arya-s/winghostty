# Multi-Window Support for Phantty

## Build Instructions

**Always use `make debug`** for all builds during development of this feature. Debug builds compile faster and provide better error messages. Use `make release` only for final testing before committing.

## Context

Phantty is a single-window terminal emulator. The user wants Ctrl+Shift+N to open a new independent window that starts instantly and never blocks the original. We follow Ghostty's architecture: single process, multi-thread, with an `App` coordinating multiple windows.

**The core problem**: ~80 global `var g_*` declarations in `main.zig` (4939 lines) cover ALL state — window, GL context, shaders, font faces, glyph caches, atlases, tabs, render buffers, input state, etc. These must be extracted into structs before a second window can exist.

**Ghostty's model** (from GitHub source investigation):
- `App` struct owns a list of surfaces + shared `font_grid_set` (ref-counted fonts)
- Each Surface spawns 2 threads (renderer + IO)
- `new_window` flow: keybind → `App.newWindow()` → `apprt.performAction(.new_window)` → platform creates window
- Per-surface: own renderer, terminal, PTY. Shared: font grids (ref-counted), config

**Our model**:
- `App` struct owns shared config + window list
- Each window is a thread with its own Win32 HWND, GL context, fonts, atlases, tabs
- First window runs on main thread; new windows spawn on new threads
- Thread-per-window because: Win32 message queues are per-thread, GL contexts are per-thread, complete isolation = zero blocking

## Plan

### Step 1: Threading proof-of-concept — validate non-blocking window spawn

**Goal**: Prove that spawning a second Win32 window on a new thread works and never blocks the original. No refactoring of main.zig — just add ~150 lines.

**Create `src/window_thread.zig`** — a minimal module that can:
1. Spawn a new `std.Thread`
2. On that thread: create a Win32 window + WGL OpenGL 3.3 context (reuse `win32.zig`'s `Window.init`)
3. Load GLAD for the new GL context
4. Run its own `PeekMessage` loop, clearing to the terminal background color each frame
5. Handle `WM_CLOSE` to exit its loop and clean up

**Add Ctrl+Shift+N keybinding** in main.zig's `handleKey` (line ~3855):
```zig
// Ctrl+Shift+N = new window (proof of concept)
if (ev.ctrl and ev.shift and ev.vk == 0x4E) {
    window_thread.spawn(g_theme.background) catch {};
    return;
}
```

**What this validates**:
- Second Win32 window on a separate thread appears instantly
- Original window continues rendering, input works, no stutter
- WGL context creation per thread works
- Win32 message pump per thread works
- Closing second window doesn't affect the first
- Closing first window exits the process (second window is a detached thread for now)

**What this does NOT do**: No font loading, no terminal, no tabs — just a colored rectangle. That's the point: prove the threading model before investing in the big refactor.

**Files**: new `src/window_thread.zig` (~150 lines), small edit to `src/main.zig` (add keybinding + import)

**Verification**: `make debug`, launch, press Ctrl+Shift+N. A second window appears instantly. Spam keys in the first window — no lag. Close second window — first window unaffected. This should take ~1 session to implement and test.

---

### Step 2: Create `AppWindow` struct — move per-window state out of globals

Now that we've proven threading works, do the big extraction. Move every global into a struct so functions take `self: *AppWindow` instead of referencing file-level `var`s.

**Create `src/AppWindow.zig`** with fields for ALL current globals (see Appendix A for full field list).

**Method**:
1. Define `AppWindow` struct with all ~80 fields
2. Create `AppWindow.init(allocator, config)` — does what `main()` lines 4526-4793 do
3. Create `AppWindow.run(self)` — does what the main loop (lines 4799-4912) does
4. Create `AppWindow.deinit(self)` — cleanup
5. Move ALL functions that reference globals into methods on AppWindow
6. `main()` becomes: parse args → load config → create AppWindow → `appWindow.run()`

**Key technique**: Most functions just need `self: *AppWindow` added as first param, and `g_foo` replaced with `self.foo`. Shader source strings and type definitions (`CellBg`, `CellFg`, `SnapCell`, `Character`, etc.) stay as file-level constants.

**Files modified**: `src/main.zig` (gutted to ~100 lines), new `src/AppWindow.zig` (~4800 lines — mostly a move)

**Verification**: `make debug`, launch phantty.exe, confirm tabs/rendering/input/scrollbar/config-reload all work identically to before.

---

### Step 3: Create `App` struct + wire up real multi-window via Ctrl+Shift+N

Combine the threading from Step 1 with the AppWindow from Step 2. Replace the proof-of-concept `window_thread.zig` with the real thing.

**Create `src/App.zig`**:
```zig
const App = @This();

allocator: std.mem.Allocator,
shell_cmd_buf: [256]u16,       // Resolved shell command (UTF-16)
shell_cmd_len: usize,
scrollback_limit: u32,
font_family: []const u8,       // Config values (read-only after init)
font_weight: ...,
font_size: u32,
cursor_style: CursorStyle,
cursor_blink: bool,
theme: Theme,
shader_path: ?[]const u8,

// Window management
windows: std.ArrayList(*AppWindow),
mutex: std.Thread.Mutex,
window_threads: std.ArrayList(std.Thread),  // for join on shutdown
```

**Methods**:
- `App.init(allocator)` — parse CLI args, load config, resolve shell
- `App.requestNewWindow(self)` — spawns a new thread that creates+runs an AppWindow
- `App.removeWindow(self, window)` — thread-safe removal from list
- `App.deinit()` — joins all window threads, cleanup

**Ctrl+Shift+N** in AppWindow's `handleKey`:
```zig
if (ev.ctrl and ev.shift and ev.vk == 0x4E) {
    self.app.requestNewWindow();
    return;
}
```

**New thread entry point** (`App.windowThreadMain`):
1. `CoInitializeEx(null, COINIT_MULTITHREADED)` — COM for DirectWrite
2. `AppWindow.init(self.allocator, self)` — creates Win32 window + GL + fonts + shaders + initial tab
3. `app.addWindow(&window)`
4. `window.run()` — blocks until this window closes
5. `app.removeWindow(&window)` + `window.deinit()`
6. `CoUninitialize()`

**Thread safety**: Each AppWindow is fully independent. `App` fields are read-only after init. Window list protected by `App.mutex`.

**Window lifecycle**:
- Each window tracks its own `should_close` flag
- Ctrl+W with 1 tab closes THAT window only
- Main thread's `run()` blocks on first window; when it returns, join all window threads
- `PostQuitMessage` is per-thread, so closing one window only affects its own message pump

**Delete** `src/window_thread.zig` (replaced by App.requestNewWindow)

**Verification**:
- Launch phantty, Ctrl+Shift+N — fully functional second window appears
- Type in both windows simultaneously — no lag or blocking
- Run `cat /dev/urandom` in one window — other window unaffected
- Close either window — the other stays alive
- Close all windows — process exits cleanly

---

### Step 4: Polish — config reload, working directory inheritance, clean shutdown

**Config hot-reload across windows**:
- Config watcher moves to App (single watcher, not per-window)
- On config change, App sets an atomic flag on each window
- Each window checks the flag in its run loop and reloads

**Working directory inheritance**:
- `App.requestNewWindow(cwd: ?[]const u8)` passes the active tab's CWD
- New window's first tab starts in that directory

**Clean shutdown**:
- `App.requestShutdown()` posts `WM_CLOSE` to all window HWNDs via `PostMessage`
- Each window exits its run loop
- Main thread joins all window threads

**Window position**:
- New windows cascade from parent position (+30,+30)
- Each window saves position independently on close

**Verification**: Full end-to-end:
1. Open phantty, cd to `/tmp`
2. Ctrl+Shift+N — new window opens with shell in `/tmp`
3. Edit config — both windows update
4. Close windows in various orders — clean exit

## Key Files

| File | Role |
|------|------|
| `src/main.zig` | Entry point only (~100 lines): create App, create first AppWindow, run |
| `src/App.zig` | **NEW** (Step 3) — shared config, window list, thread spawning |
| `src/AppWindow.zig` | **NEW** (Step 2) — ALL per-window state + rendering + input (bulk of current main.zig) |
| `src/window_thread.zig` | **NEW** (Step 1, temporary) — minimal threading proof-of-concept, deleted in Step 3 |
| `src/Surface.zig` | Unchanged — still owns PTY + terminal + IO thread |
| `src/win32.zig` | Minor changes — need to support multiple windows (remove global window pointer) |
| `src/termio/Thread.zig` | Unchanged |

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Threading model doesn't work on Win32 | **Step 1 validates this first** before any big refactor |
| FreeType not thread-safe | Each AppWindow gets its own FT_Library + faces (small cost) |
| DirectWrite COM threading | Call `CoInitializeEx(COINIT_MULTITHREADED)` on each window thread |
| OpenGL context per thread | Each window creates its own WGL context — standard Win32 pattern |
| Global window pointer in win32.zig | Pass HWND→AppWindow mapping via `GWLP_USERDATA` |
| Massive refactor risk (Step 2) | Pure mechanical extraction (add `self.`, remove `g_`), verify with `make debug` |
| Config watcher thread safety | Config is read-only after load; hot-reload via atomic flag + re-read |

## Appendix A: AppWindow Fields (Step 2)

All current `g_*` globals plus non-prefixed globals that become AppWindow fields:

**Window/lifecycle**: `win32_window`, `should_close`, `allocator`, `app` (back-pointer)
**Tabs**: `tabs[16]`, `tab_count`, `active_tab`, `tab_close_opacity[16]`, `tab_close_pressed`
**GL**: `gl` (GladGLContext), `shader_program`, `vao`, `vbo`, `bg_shader`, `fg_shader`, `color_fg_shader`, `bg_vao`, `fg_vao`, `color_fg_vao`, `bg_instance_vbo`, `fg_instance_vbo`, `color_fg_instance_vbo`, `quad_vbo`
**Fonts**: `ft_lib`, `glyph_face`, `icon_face`, `titlebar_face`, `glyph_cache`, `grapheme_cache`, `icon_cache`, `titlebar_cache`, `font_discovery`, `fallback_faces`, `hb_buf`, `hb_font`, `hb_fallback_fonts`, `font_size`
**Atlases**: `atlas`, `color_atlas`, `icon_atlas`, `titlebar_atlas`, `atlas_texture`, `color_atlas_texture`, `icon_atlas_texture`, `titlebar_atlas_texture`, `atlas_modified`, `color_atlas_modified`, `icon_atlas_modified`, `titlebar_atlas_modified`
**Render buffers**: `snap[MAX_SNAP]`, `snap_rows`, `snap_cols`, `bg_cells[MAX_CELLS]`, `fg_cells[MAX_CELLS]`, `color_fg_cells[MAX_CELLS]`, `bg_cell_count`, `fg_cell_count`, `color_fg_cell_count`
**Dirty tracking**: `cells_valid`, `force_rebuild`, `last_cursor_blink_visible`, `cached_cursor_*`, `cached_viewport_at_bottom`, `last_viewport_*`, `last_cols`, `last_rows`, `last_selection_active`
**Cell metrics**: `cell_width`, `cell_height`, `cell_baseline`, `titlebar_cell_width/height/baseline`, `term_cols`, `term_rows`
**Input**: `selecting`, `click_x`, `click_y`, `scrollbar_hover`, `scrollbar_dragging`, `scrollbar_drag_offset`
**Theme/config**: `theme`, `cursor_style`, `cursor_blink`, `cursor_blink_visible`, `last_blink_time`, `shell_cmd_buf`, `shell_cmd_len`, `scrollback_limit`
**Fullscreen**: `is_fullscreen`, `windowed_x/y/width/height`
**Post-processing**: `post_fbo`, `post_texture`, `post_program`, `post_vao`, `post_vbo`, `post_enabled`, `post_fb_width/height`, `frame_count`, `start_time`
**Resize**: `pending_resize`, `pending_cols/rows`, `last_resize_time`, `resize_in_progress`
**Debug**: `debug_fps`, `debug_draw_calls`, `draw_call_count`, `fps_*`
**Timing**: `last_frame_time_ms`
