# Phantty

A Windows terminal emulator written in Zig, powered by [libghostty-vt](https://github.com/ghostty-org/ghostty) for terminal emulation.

## Features

- **Ghostty's terminal emulation** - Uses libghostty-vt for VT parsing and terminal state
- **DirectWrite font discovery** - Find system fonts by name
- **FreeType rendering** - High-quality glyph rasterization
- **Per-glyph font fallback** - Automatic fallback for missing characters
- **Sprite rendering** - Box drawing, block elements, braille patterns, powerline symbols
- **Ghostty-style font metrics** - Proper ascent/descent/line_gap from hhea/OS2 tables
- **Theme support** - Ghostty-compatible theme files (default: Poimandres)

## Building

```bash
# Debug build (console subsystem, debug output visible)
make debug

# Release build (GUI subsystem, no background console window)
make release

# Clean build artifacts
make clean
```

Or directly with zig:
```bash
zig build                          # debug
zig build -Doptimize=ReleaseFast   # release
```

## Usage

```bash
phantty.exe [options]

Options:
  --font, -f <name>            Set font (default: embedded fallback)
  --font-style <style>         Font weight (default: regular)
                                Options: thin, extra-light, light, regular,
                                         medium, semi-bold, bold, extra-bold, black
  --cursor-style <style>       Cursor shape (default: block)
                                Options: block, bar, underline, block_hollow
  --cursor-style-blink <bool>  Enable cursor blinking (default: true)
  --theme <path>               Load a Ghostty theme file
  --window-height <rows>       Initial window height in cells (default: 0=auto, min: 4)
  --window-width <cols>        Initial window width in cells (default: 0=auto, min: 10)
  --list-fonts                 List available system fonts
  --test-font-discovery        Test DirectWrite font discovery
  --help                       Show help
```

## Configuration

Phantty uses a Ghostty-compatible config file format (`key = value` pairs). The config file is loaded from `%APPDATA%\phantty\config`.

Press `Ctrl+,` to open the config file in your default editor, or run `phantty.exe --show-config-path` to print the resolved path.

CLI flags override config file values (last wins).

### Example config

```
font-family = Cascadia Code
font-style = regular
font-size = 14
cursor-style = bar
cursor-style-blink = true
theme = Poimandres
window-height = 32
window-width = 120
scrollback-limit = 10000000
custom-shader = path/to/shader.glsl
config-file = extra.conf
```

### Available keys

| Key | Default | Description |
|-----|---------|-------------|
| `font-family` | *(none)* | Font family name (falls back to embedded font if unset) |
| `font-style` | `regular` | Font weight: `thin`, `extra-light`, `light`, `regular`, `medium`, `semi-bold`, `bold`, `extra-bold`, `black` |
| `font-size` | `12` | Font size in points |
| `cursor-style` | `block` | Cursor shape: `block`, `bar`, `underline`, `block_hollow` |
| `cursor-style-blink` | `true` | Enable cursor blinking |
| `theme` | *(none)* | Theme name or absolute path (453 Ghostty themes built-in) |
| `custom-shader` | *(none)* | Path to a GLSL post-processing shader |
| `window-height` | `0` (auto) | Initial height in cells (min: 4, 0 = auto 80×24) |
| `window-width` | `0` (auto) | Initial width in cells (min: 10, 0 = auto 80×24) |
| `scrollback-limit` | `10000000` | Scrollback buffer limit in bytes |
| `config-file` | *(none)* | Include another config file (prefix with `?` to make optional) |

## License

MIT
