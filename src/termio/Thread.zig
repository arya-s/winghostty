/// IO reader thread — reads from PTY in a blocking loop.
///
/// Each Surface spawns one of these. The thread blocks on ReadFile(),
/// then briefly locks the Surface mutex to feed data through the VT
/// parser and OSC scanner.
///
/// Modeled after Ghostty's `src/termio/Exec.zig` ReadThread:
/// - 1KB read buffer (like Ghostty) to keep lock hold times short
/// - Lock acquired per read chunk
/// - dirty flag set inside the lock so the render thread can't miss it
///
/// Read coalescing: after the first blocking read, we drain any
/// additional data already buffered in the pipe (via PeekNamedPipe)
/// before releasing the lock. This reduces the chance of the render
/// thread snapshotting mid-sequence when ConPTY splits output across
/// multiple writes.

const std = @import("std");
const windows = std.os.windows;
const Surface = @import("../Surface.zig");

const Thread = @This();

const READ_BUF_SIZE = 1024;

extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpBuffer: ?*anyopaque,
    nBufferSize: windows.DWORD,
    lpBytesRead: ?*windows.DWORD,
    lpTotalBytesAvail: ?*windows.DWORD,
    lpBytesLeftThisMessage: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;

/// The thread entry point. Runs a blocking read loop on the Surface's PTY.
pub fn threadMain(surface: *Surface) void {
    var buf: [READ_BUF_SIZE]u8 = undefined;

    while (true) {
        if (surface.exited.load(.acquire)) return;

        // First read — blocks until data is available.
        const bytes_read = surface.pty.read(&buf) catch {
            surface.exited.store(true, .release);
            return;
        };

        if (bytes_read == 0) {
            surface.exited.store(true, .release);
            return;
        }

        {
            surface.render_state.mutex.lock();
            defer surface.render_state.mutex.unlock();

            surface.resetOscBatch();

            var stream = surface.terminal.vtStream();

            // Process the first chunk.
            const data = buf[0..bytes_read];
            stream.nextSlice(data) catch {};
            surface.scanForOscTitle(data);

            // Coalesce: drain any additional data already in the pipe
            // so we don't release the lock mid-sequence. This handles
            // the common case where ConPTY writes a batch of data as
            // multiple small pipe writes that arrive back-to-back.
            while (true) {
                var avail: windows.DWORD = 0;
                if (PeekNamedPipe(surface.pty.pipe_in_read, null, 0, null, &avail, null) == 0)
                    break;
                if (avail == 0) break;

                const extra = surface.pty.read(&buf) catch break;
                if (extra == 0) break;

                const extra_data = buf[0..extra];
                stream.nextSlice(extra_data) catch {};
                surface.scanForOscTitle(extra_data);
            }

            surface.dirty.store(true, .release);
        }
    }
}
