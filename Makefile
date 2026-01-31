.PHONY: debug debug-glfw debug-win32 release release-glfw release-win32 clean update-ghostty

# Default: build both backends
debug:
	zig build

# Individual backends
debug-glfw:
	zig build -Dbackend=glfw

debug-win32:
	zig build -Dbackend=win32

# Release builds (humans only)
release:
	zig build -Doptimize=ReleaseFast

release-glfw:
	zig build -Doptimize=ReleaseFast -Dbackend=glfw

release-win32:
	zig build -Doptimize=ReleaseFast -Dbackend=win32

clean:
	rm -rf zig-out .zig-cache

update-ghostty:
	zig fetch --save=ghostty https://github.com/ghostty-org/ghostty/archive/main.tar.gz
