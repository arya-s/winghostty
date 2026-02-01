# Phantty UI Framework Plan

## Status: Phase 1 nearly complete, Phase 4 partially done

## Development Workflow

- **Build environment**: WSL (Linux) cross-compiling to `x86_64-windows`
- **Build command**: `make debug` builds `phantty.exe` (Win32 backend only). Never `make release` (that's for humans shipping).
- **Running**: The built `.exe` is accessible directly from Windows (WSL filesystem) — no copy step needed
- **Build-and-validate cadence**: Build often, validate often. **Every build must run without crashing.** After any meaningful change, do `make debug` and confirm the exe launches and renders correctly on Windows. Prompt for a build test regularly — don't let changes pile up untested.
- **No big bangs**: If a change touches rendering, input, or windowing, build and test before moving on. Small steps.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| UI framework | **Win32 + Direct2D/D3D11** | Pure Zig, no runtime deps, proven (Flow, Tuple, refterm). |
| Migration strategy | **Incremental** | Keep GLFW working behind build flag during transition. |
| Phase 1 renderer | **OpenGL (temporary)** | Bridge via `wglCreateContext` on Win32 HWND. Swap to D3D11 in Phase 2. |
| Target renderer | **Direct3D 11** | D3D12 is overkill for a terminal — explicit memory/barrier management with no benefit. Windows Terminal, refterm, and Flow all use D3D11. |
| Min Windows version | **Win10 2004+ (build 19041)** | Same baseline as Windows Terminal. Mica/Acrylic runtime-detected for Win11. |
| Custom title bar | **Early (Phase 1)** | Establish visual identity upfront. Chrome/Windows Terminal-style tab experience. |
| Settings UI | **External editor** | `Ctrl+,` opens config in editor, hot-reload on save. Matches Ghostty. In-app settings is a future follow-up. |
| Reference code | **Vendor from Flow** | Vendor relevant pieces from [neurocyte/flow](https://github.com/neurocyte/flow/tree/master/src/win32) with attribution. |

---

## Context

Phantty is currently a single-window terminal emulator using GLFW (windowing) + OpenGL (rendering) + FreeType (font rasterization) + DirectWrite (font discovery). This is the cross-platform bootstrap stack that Ghostty recommends as step one (see [Ghostty #2563](https://github.com/ghostty-org/ghostty/discussions/2563)).

We are moving to a native Windows UI shell that:
- Feels at home on Windows 10/11 (like Windows Terminal / Chrome)
- Is highly performant (tile-based glyph rendering — see [refterm](https://github.com/cmuratori/refterm))
- Stays in Zig (no .NET runtime, no C++ COM chaos, no managed code)
- Supports tabs, split panes, custom title bar, context menus

## Research Summary

### What Windows Terminal Does
Windows Terminal is a **Win32 app** that uses **XAML Islands** to embed WinUI 2 controls for its chrome (tabs, title bar, settings page). The actual terminal content is rendered by their custom **AtlasEngine** which uses **DirectWrite + Direct3D 11** with a tile-based glyph cache. This is the same architecture refterm demonstrated — a simple tile renderer with a glyph cache can be orders of magnitude faster than naive approaches.

Key takeaway: Even Microsoft's flagship terminal is fundamentally a Win32 app with custom GPU rendering. The WinUI parts are a thin overlay for chrome only.

### Framework Landscape (from Ghostty #2563 discussion, experienced devs)

| Framework | Verdict | Why |
|-----------|---------|-----|
| **Win32 + Direct2D/D3D** | ✅ **Best fit** | Pure native, no runtime deps, proven in Zig (Flow editor, Tuple app, direct2d-zig). Full control over rendering + native window feel. |
| **WinUI 3** | ❌ Avoid | Slow, buggy, semi-abandoned per community. Tight SDK version coupling. Would need C++/C# interop. |
| **WPF** | ❌ Avoid | Requires .NET runtime (~100MB self-contained). No native AOT. Wrong language ecosystem for a Zig project. |
| **WinForms** | ❌ Avoid | Dated look, no AOT, requires .NET. |
| **Qt/GTK/wx** | ❌ Avoid | Cross-platform frameworks never feel native on Windows. Integration issues are endemic. |
| **XAML Islands** | ⚠️ Not needed | What Windows Terminal uses for tab bar chrome. Complex COM interop — we'll custom-draw instead. |

### Why Win32 Is Sufficient for a Terminal

A terminal has very few traditional UI controls:

| UI Element | Approach | Native? |
|-----------|----------|---------|
| Terminal grid | Custom D3D11 tile renderer | N/A (always custom) |
| Title bar | Custom via DWM extend | ✅ DWM-native |
| Tab bar | Custom-drawn (Direct2D) | Custom in every terminal |
| Context menu | `TrackPopupMenu` | ✅ 100% native, dark-mode-aware |
| Scrollbar | Custom-drawn | Standard for terminals |
| File dialogs | `IFileOpenDialog` | ✅ 100% native |
| Message boxes | `MessageBoxW` | ✅ 100% native |
| Dark mode | `DwmSetWindowAttribute` | ✅ OS-level |
| Mica/Acrylic | `DWMWA_SYSTEMBACKDROP_TYPE` | ✅ Compositor-level (Win11) |

### Proven Zig Precedent
- **[Flow editor](https://github.com/neurocyte/flow/tree/master/src/win32)**: Win32 + D3D11 + DirectWrite. Full terminal-style grid renderer in Zig. **We will vendor relevant pieces from this.**
- **[direct2d-zig](https://github.com/marler8997/direct2d-zig)**: Clean Zig example of Win32 + Direct2D rendering.
- **[Tuple](https://tuple.app)**: Commercial app using Win32 + Direct2D. "Much easier to reason about than the window hierarchy."
- **[refterm](https://github.com/cmuratori/refterm)**: Reference terminal renderer. D3D11 + DirectWrite tile renderer. Orders of magnitude faster than Windows Terminal.

---

## Architecture

```
┌──────────────────────────────────────────────────┐
│              Win32 Window (HWND)                  │
│  ┌────────────────────────────────────────────┐  │
│  │  Custom Title Bar (DWM extended frame)     │  │
│  │  ┌──────┐ ┌──────┐ ┌──────┐    [─][□][✕]  │  │ ◄── Direct2D drawn tabs
│  │  │ Tab 1│ │ Tab 2│ │  +   │               │  │     Chrome/WinTerm style
│  │  └──────┘ └──────┘ └──────┘               │  │
│  ├────────────────────────────────────────────┤  │
│  │                                            │  │
│  │     Terminal Content (D3D11)               │  │ ◄── Tile-based glyph renderer
│  │     DirectWrite for text shaping           │  │     Glyph atlas texture cache
│  │     Glyph atlas texture cache              │  │
│  │                                            │  │
│  └────────────────────────────────────────────┘  │
│                                                  │
│  Context menus: Win32 TrackPopupMenu             │ ◄── Native OS menus
│  Dialogs: Win32 common dialogs                   │ ◄── Native file/message dialogs
│  Backdrop: DWM Mica/Acrylic (Win11, optional)    │ ◄── Runtime-detected
└──────────────────────────────────────────────────┘
```

### Component Breakdown

| Component | Technology | Notes |
|-----------|-----------|-------|
| **Windowing** | Win32 `CreateWindowExW` | Replace GLFW. Direct message loop, DPI-aware, DWM integration. |
| **Terminal rendering** | Direct3D 11 + HLSL | Tile-based glyph renderer with atlas cache (Phase 2). OpenGL bridge in Phase 1. |
| **Text shaping & rasterization** | DirectWrite | Replace FreeType (Phase 3). Matches Windows-native text. Already have DW for discovery. |
| **UI chrome (tabs, title bar)** | Direct2D | Custom-drawn. Fluent-style with DWM Mica/Acrylic. Chrome/WinTerm tab feel. |
| **Context menus** | Win32 `TrackPopupMenu` | Native dark-mode-aware context menus. |
| **Dialogs** | Win32 common dialogs | File open/save, message boxes. |
| **DPI awareness** | Per-Monitor DPI V2 | `SetProcessDpiAwarenessContext` + `WM_DPICHANGED` |
| **Dark/light mode** | DWM attributes + system color queries | `DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)` |
| **Acrylic/Mica** | DWM backdrop APIs | `DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE)` (Win11 22H2+, runtime-detected) |

---

## Phased Implementation Plan

### Phase 1: Win32 Windowing + Custom Title Bar
> **Goal**: Native Win32 window with custom title bar and tab strip. OpenGL rendering preserved via wgl bridge. GLFW kept behind build flag.

**Win32 Window**
- [x] Create Win32 window with `CreateWindowExW`
- [x] Implement Win32 message loop (`PeekMessageW`-based `pollEvents`)
- [x] Handle keyboard input via `WM_KEYDOWN`/`WM_CHAR`/`WM_SYSKEYDOWN` (event queue + processing)
- [x] Handle mouse input via `WM_MOUSEMOVE`/`WM_LBUTTONDOWN`/`WM_MOUSEWHEEL` (selection, scroll)
- [x] Handle window resize via `WM_SIZE` → terminal cols/rows recalc + resize coalescing
- [x] Clipboard (copy/paste via Win32 native clipboard API)
- [x] Fullscreen toggle (Alt+Enter / F11 via Win32 borderless fullscreen)
- [ ] Per-Monitor DPI V2 awareness (`WM_DPICHANGED`)
- [x] Dark mode via `DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)`
- [ ] Mica/Acrylic backdrop (Win11 22H2+, graceful no-op on Win10) — **deferred, cosmetic only, untestable on Win10**

**OpenGL Bridge (temporary)**
- [x] Set up OpenGL 3.3 core context on Win32 HWND via WGL bootstrap (dummy window → `wglCreateContextAttribsARB`)
- [x] Port existing GLFW render loop to Win32 message pump (shared rendering code works)
- [x] Verify existing rendering works identically

**Custom Title Bar**
- [x] Extend frame into client area via `DwmExtendFrameIntoClientArea` (cyTopHeight=-1)
- [x] Handle `WM_NCCALCSIZE` to remove default title bar (preserves resize borders, proper maximized inset)
- [x] Handle `WM_NCHITTEST` for resize borders, caption area, min/max/close buttons (snap layouts)
- [x] Terminal content offset below titlebar area (34px, matches Explorer)
- [x] Titlebar background + active tab indicator (OpenGL quads)
- [x] Tab title text rendering with UTF-8 support, fixed 14pt size
- [x] 1px focus border (terminal bg color) when window is active
- [x] Caption buttons: Segoe MDL2 Assets icon font (minimize, maximize, restore, close) with DPI-aware sizing
- [x] Caption button hover states (subtle fill for min/max, red #C42B1C for close, 1px inset on close for focus border)
- [x] Caption buttons fire on mouse-up, drag-away cancels
- [x] Maximize button shows restore icon when maximized or fullscreen; click exits fullscreen
- [x] Ghostty-style tab bar: equal-width tabs, active = terminal bg, inactive = bg+0.05 with bottom border
- [x] Tab shortcuts (^1–^9, ^0) right-aligned, dimmed on inactive tabs
- [x] New-tab (+) button with Segoe MDL2 AddBold icon, same size/color as caption buttons
- [x] Middle-click tab to close
- [x] Double-click tab to maximize/restore (suppressed on + button)
- [x] Single-tab titlebar: drag to move, double-click to maximize
- [x] Multi-tab titlebar: tab area clickable, gap area draggable
- [x] Tab title from OSC 0/2/7 with shell-friendly names and middle ellipsis truncation
- [ ] Chrome/Windows Terminal-style rounded tab appearance (deferred to Direct2D phase)

**Build System**
- [x] Win32-only build (`make debug` produces `phantty.exe`). GLFW backend removed.
- [ ] Vendor Flow editor Win32/D3D11 pieces with attribution (deferred to Phase 2)

**Config**
- [x] `shell` setting: cmd (default), powershell, pwsh, wsl, or custom path

**Deliverable**: Phantty runs on a native Win32 window with custom title bar, Ghostty-style tab bar, and Segoe MDL2 caption button icons. Explorer-matching chrome. ~~GLFW still works as fallback.~~

### Phase 2: Direct3D 11 Renderer (Replace OpenGL)
> **Goal**: GPU-accelerated tile-based terminal rendering.

- [ ] Initialize D3D11 device + swap chain on the Win32 HWND
- [ ] Implement glyph atlas texture (hash map: font+codepoint → atlas rect)
- [ ] Write HLSL vertex/pixel shaders for tile-based cell rendering
- [ ] Port background color rendering
- [ ] Port cursor rendering (block, bar, underline, blinking)
- [ ] Port selection rendering
- [ ] Port underline/strikethrough/overline rendering
- [ ] Port custom post-processing shader support (Ghostty-compatible)
- [ ] Handle swap chain resize on `WM_SIZE`
- [ ] Remove OpenGL dependency

**Deliverable**: Terminal rendered via D3D11 tile-based atlas. Faster. No OpenGL.

### Phase 3: DirectWrite Rasterization (Replace FreeType)
> **Goal**: Windows-native font rendering. Text looks like every other Windows app.

- [ ] Use DirectWrite for glyph rasterization (not just discovery)
- [ ] Implement DirectWrite text analysis for complex script shaping
- [ ] Render glyphs to atlas via `ID2D1RenderTarget` → D3D11 shared texture
- [ ] Handle font fallback chains via DirectWrite
- [ ] Support colored emoji (DirectWrite color glyph layers)
- [ ] Render tab bar title text with Segoe UI via DirectWrite (currently uses terminal monospace font via FreeType — looks blurry and wrong)
- [ ] Remove FreeType dependency

**Deliverable**: Text matches native Windows rendering. Emoji support. Tab bar uses native Segoe UI. Smaller binary.

### Phase 4: Tab Management
> **Goal**: Full tabbed terminal experience matching Chrome/Windows Terminal.

**Done (implemented early in Phase 1):**
- [x] Tab model: each tab owns its own PTY + terminal + OSC state + selection (TabState struct, max 16)
- [x] New tab: `Ctrl+Shift+T` or click (+) button — spawns real PTY + terminal
- [x] Close tab: `Ctrl+W`, middle-click, or close any tab (deinits PTY/terminal, adjusts active index)
- [x] Switch tabs: `Ctrl+Tab` / `Ctrl+Shift+Tab` / `Ctrl+1-9`
- [x] Tab title from shell (per-tab OSC 0/2/7 sequences, shell-friendly names, ~/ substitution)
- [x] Each tab owns its own terminal instance + PTY (all tabs are real terminals)
- [x] Main loop drains all tabs' PTYs (background tabs don't block)
- [x] Resize applies to all tabs' terminals and PTYs
- [x] Config reload (cursor style, font, etc.) applies to all tabs

**Remaining:**
- [ ] Per-tab I/O threads: move PTY reads off the main thread so a busy tab (e.g. `cat /dev/urandom`) can't starve others. Each tab gets a reader thread that feeds the VT parser and signals the main thread to re-render. (See [ghostty_ui_research.md](ghostty_ui_research.md) — Ghostty uses 2 threads per surface: I/O + renderer.)
- [ ] New tab inherits working directory from active tab (Ghostty does this via `Surface.setParent`)
- [ ] Bell attention indicator: mark unfocused tabs when their shell rings the bell (Ghostty sets `needsAttention` on the tab page + 🔔 title prefix)
- [ ] Reorder tabs: drag and drop
- [ ] Tab overflow: scroll or dropdown when too many tabs
- [ ] Right-click tab context menu (close, close others, duplicate, rename)
- [ ] New tab shell picker (cmd, powershell, WSL profiles)
- [ ] Confirm close if process running

**Deliverable**: Full tabbed terminal. Multiple concurrent sessions.

### Phase 5: Context Menus & Polish
> **Goal**: Right-click menus, system integration, visual polish.

- [ ] Right-click context menu in terminal area (copy, paste, select all, search, settings)
- [ ] System tray icon (optional, configurable)
- [ ] Window transparency / opacity setting
- [ ] Smooth resize (no flicker during `WM_SIZE`)
- [ ] Window state persistence (size, position, maximized state)
- [ ] Jump list integration (pinned shells)
- [ ] Proper `WM_CLOSE` handling (confirm if tabs have running processes)

### Phase 6: Split Panes & Advanced Features
> **Goal**: Power-user features.

- [ ] Split panes (horizontal/vertical) within a tab
- [ ] Pane resize with drag handles
- [ ] Command palette (`Ctrl+Shift+P`)
- [ ] Search in terminal output (`Ctrl+Shift+F`)
- [ ] Clickable URLs
- [ ] Shell integration (CWD tracking, jump-to-prompt)

---

## Vendored Code Attribution

Portions of the Win32 windowing, Direct3D 11, and DirectWrite integration are derived from:
- **[Flow editor](https://github.com/neurocyte/flow)** by neurocyte (MIT License) — `src/win32/` directory
- **[direct2d-zig](https://github.com/marler8997/direct2d-zig)** by marler8997

---

## References

- [Ghostty #2563 — Windows Support discussion](https://github.com/ghostty-org/ghostty/discussions/2563)
- [Windows Terminal source](https://github.com/microsoft/terminal) — especially `src/renderer/atlas/` and `src/cascadia/WindowsTerminal/`
- [Windows Terminal WinUI blog post](https://blogs.windows.com/windowsdeveloper/2020/09/08/building-windows-terminal-with-winui/)
- [refterm](https://github.com/cmuratori/refterm) — Casey Muratori's reference terminal renderer (D3D11+DirectWrite)
- [Flow editor win32 backend](https://github.com/neurocyte/flow/tree/master/src/win32) — Zig Win32+D3D11+DirectWrite
- [direct2d-zig](https://github.com/marler8997/direct2d-zig) — Zig Direct2D example
- [AtlasEngine README](https://github.com/microsoft/terminal/blob/main/src/renderer/atlas/README.md) — Windows Terminal's D3D11 renderer architecture
- [Microsoft UI framework comparison](https://learn.microsoft.com/en-us/windows/apps/get-started/#app-development-framework-feature-comparison)
- [WinUI 3 community concerns](https://github.com/microsoft/microsoft-ui-xaml/discussions/9417)
