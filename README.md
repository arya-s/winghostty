# Phantty

A Windows terminal emulator written in Zig, powered by [libghostty-vt](https://github.com/ghostty-org/ghostty) for terminal emulation.

## Features

- **Ghostty's terminal emulation** - Uses libghostty-vt for VT parsing and terminal state
- **DirectWrite font discovery** - Find system fonts by name
- **FreeType rendering** - High-quality glyph rasterization
- **Per-glyph font fallback** - Automatic fallback for missing characters
- **Sprite rendering** - Box drawing, block elements, braille patterns, powerline symbols
- **Ghostty-style font metrics** - Proper ascent/descent/line_gap from hhea/OS2 tables

## Building

```bash
zig build
```

## Usage

```bash
phantty.exe [options]

Options:
  --font <name>           Set font (default: Consolas)
  --list-fonts            List available system fonts
  --test-font-discovery   Test DirectWrite font discovery
  --help                  Show help
```

## License

MIT
