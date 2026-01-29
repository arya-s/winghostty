.PHONY: debug release clean update-ghostty

debug:
	zig build

release:
	zig build -Doptimize=ReleaseFast

clean:
	rm -rf zig-out .zig-cache

update-ghostty:
	zig fetch --save=ghostty https://github.com/ghostty-org/ghostty/archive/main.tar.gz
