# Ghostty UI Architecture Research

Research notes from reading the Ghostty source (v1.3.0-dev) to understand how it handles tabs, surfaces, and the terminal lifecycle.

## Hierarchy: Window → Tab → SplitTree → Surface

```
Window (adw.ApplicationWindow)
├── adw.TabView (manages tab bar + tab pages)
│   ├── Tab 1 (GhosttyTab — gtk.Box)
│   │   └── SplitTree (GhosttySplitTree — gtk.Box)
│   │       └── Surface.Tree (binary tree of splits)
│   │           ├── Surface A (focused)
│   │           └── Split
│   │               ├── Surface B
│   │               └── Surface C
│   ├── Tab 2
│   │   └── SplitTree
│   │       └── Surface D (single pane, no splits)
│   └── ...
```

## Window (`src/apprt/gtk/class/window.zig`)

- Owns an `adw.TabView` (libadwaita's tab widget)
- Tab bar rendering is handled by GTK/libadwaita — Ghostty does **not** custom-draw it
- Key functions:
  - `newTab(parent)` → creates a `Tab` GObject, inserts it into the `TabView`
  - `selectTab(n)` → switches to tab by index, relative (next/prev/last), or absolute
  - `moveTab(direction)` → reorders tabs left/right
  - `toggleTabOverview()` → libadwaita tab overview (grid view of all tabs)
- Tab insertion position is configurable: `window-new-tab-position = current | end`
- Property bindings wire tab title/tooltip to the `TabView` page title/tooltip
- Close confirmation is handled via `CloseConfirmationDialog` checking if surfaces have running processes

## Tab (`src/apprt/gtk/class/tab.zig`)

- A `GhosttyTab` is a `gtk.Box` containing a single `SplitTree`
- Created via GObject instantiation with a config reference
- **Computed title** logic (in `closureComputedTitle`):
  1. Title override (user-set via dialog) — highest priority
  2. Terminal title (from OSC sequences)
  3. Config-level title (`title` config key)
  4. `"Ghostty"` — default fallback
  - Prefixed with 🔔 if bell is ringing (configurable via `bell-features`)
  - Prefixed with 🔍 if a split pane is zoomed
- Tooltip is bound to the active surface's `pwd` (working directory)
- Emits `close-request` signal when the split tree becomes empty (all surfaces in the tab closed)
- Tab actions: `close` (this/other/right), `ring-bell`
- "Needs attention" indicator: set when bell rings on an unfocused tab, cleared on select

## SplitTree (`src/apprt/gtk/class/split_tree.zig`)

- Manages the split pane layout within a single tab
- Contains a `Surface.Tree` — a binary tree where leaves are surfaces and nodes are splits
- Tracks:
  - Active surface (receives input)
  - Last focused surface (for restore after dialog/overlay)
- `newSplit(direction, parent)`:
  - Creates a new `Surface` GObject
  - If no tree exists yet (fresh tab), the surface becomes the root
  - Otherwise, splits the active pane 50/50 in the given direction
  - Inherits parent surface's config/working directory
- Navigation: `goto(direction)` moves focus between split panes (up/down/left/right/prev/next)
- Zoom: can zoom a single pane to fill the tab (shows 🔍 in title)
- Equalize: can reset all split ratios to equal
- Close confirmation per-surface (checks for running child processes)

## Surface (`src/Surface.zig`)

The core unit — each Surface is a fully independent terminal session.

### What each Surface owns:
- `termio.Termio` — I/O handler (PTY management, read/write, shell integration)
- `terminal.Terminal` — the VT state machine (same `ghostty_vt.Terminal` we use via libghostty-vt)
- `Renderer` — its own renderer instance (OpenGL/Metal, with glyph atlas)
- `rendererpkg.State` — shared renderer state (protected by mutex)
- `font_grid` — reference-counted font grid (shared across surfaces with same font config)
- `size` — screen size, cell size, padding
- `DerivedConfig` — surface-specific config snapshot
- Mouse state, keyboard state, selection, search state, inspector

### Threading model:
Each Surface spawns **two dedicated threads**:
1. **I/O thread** (`termio.Thread`) — reads from PTY, feeds VT parser, handles shell integration
2. **Renderer thread** (`rendererpkg.Thread`) — renders the terminal grid to the GPU

Communication between threads:
- I/O → Renderer: wakeup signal + shared `renderer_state` (mutex-protected)
- Main → I/O: `termio.Mailbox` (SPSC queue for key input, resize, etc.)
- Main → Renderer: `rendererpkg.Thread.mailbox`
- Surface → App: `surface_mailbox` for app-level actions (title change, bell, etc.)

### Initialization flow (`Surface.init`):
1. Apply conditional config state (e.g., color theme based on OS dark/light mode)
2. Derive surface-specific config
3. Initialize renderer, get content scale/DPI
4. Set up font grid (reference-counted, shared if same font config)
5. Calculate size (screen size, cell size, padding)
6. Create `termio.Exec` backend (resolves shell command, working directory, env, shell integration)
7. Initialize `termio.Termio` (creates terminal, PTY, etc.)
8. Spawn renderer thread
9. Spawn I/O thread
10. Recompute initial window size if configured

### Shutdown flow (`Surface.deinit`):
1. Signal I/O thread to stop, join it
2. Signal renderer thread to stop, join it
3. Deinit termio (closes PTY, destroys terminal)
4. Deinit renderer
5. Release font grid reference
6. Free all owned state

## Key Design Patterns

### No global state
There is no `g_terminal` or `g_pty`. Each Surface is fully self-contained. The window asks the active tab's active surface for things. Input goes to the focused surface. Rendering is per-surface.

### Platform abstraction via `apprt`
`Surface` is platform-agnostic. The `apprt` (app runtime) layer handles platform differences:
- `src/apprt/gtk/` — GTK/libadwaita on Linux
- `src/apprt/embedded.zig` — for embedding (macOS AppKit/SwiftUI wraps this)
The tab/window management lives entirely in the apprt layer.

### Reference-counted font grids
`App.font_grid_set` is a reference-counted set. Surfaces with the same font config share a font grid. This saves memory when many tabs use the same font.

### Config inheritance
New tabs/surfaces can inherit the parent surface's working directory. `setParent()` propagates this. The config is also conditionally applied (e.g., different themes for light/dark mode).

### Title flow
```
Terminal (OSC 0/2) → Surface.title property
                   ↓ (GObject property binding)
                SplitTree.active-surface.title
                   ↓ (GObject property binding)
                Tab computed_title (with bell/zoom prefixes)
                   ↓ (GObject property binding)
                adw.TabPage.title (rendered by libadwaita)
```

### Bell handling
When a surface rings the bell:
1. Surface emits action
2. Tab's `actionRingBell` checks if the tab page is selected
3. If not selected, sets `needsAttention` on the `TabPage` (libadwaita shows an indicator)
4. Title gets 🔔 prefix via `closureComputedTitle`

## Comparison with Phantty

| Aspect | Ghostty | Phantty (current) |
|--------|---------|-------------------|
| Tab widget | libadwaita `TabView` (native GTK) | Custom-drawn OpenGL tab bar |
| Tab data | GObject `Tab` → `SplitTree` → `Surface` | `TabState` (PTY + Terminal + OSC state) |
| Split panes | Full binary tree (`Surface.Tree`) | Not yet |
| Threading | 2 threads per surface (IO + renderer) | Single main thread, polls all PTYs |
| PTY reads | Dedicated I/O thread per surface | Main loop drains all PTYs round-robin |
| Renderer | Per-surface renderer thread | Single renderer, draws active tab only |
| Font sharing | Reference-counted `font_grid_set` | Single global font state |
| Title | GObject property binding chain | Direct buffer in TabState |
| Platform | apprt abstraction (GTK, AppKit) | Win32-only (with GLFW build flag) |

## Implications for Phantty

### Should adopt:
- **Per-tab I/O threads**: Move PTY reads off the main thread. A tab running `cat /dev/urandom` currently starves all other tabs. Each tab should have its own reader thread that feeds the VT parser and signals the main thread to re-render.
- **Config inheritance for new tabs**: New tab inherits working directory from active tab (Ghostty does this via `setParent`)
- **Bell attention indicator**: Mark unfocused tabs when their shell rings the bell

### Nice to have later:
- **Split panes**: Binary tree of surfaces within a tab (Phase 6 in UI_PLAN)
- **Reference-counted font grids**: Not needed until split panes (multiple surfaces visible simultaneously)
- **Per-surface renderer threads**: Overkill until split panes exist — we only render one tab at a time
