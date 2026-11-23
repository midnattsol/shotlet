//! wl_shm pools: a memfd of the pool's size, mapped into our memory and
//! shared with the compositor, cut into wl_buffers. Every shm buffer
//! Shotlet shows or captures into is made here (window surfaces, the
//! drawn cursors, the drag icon, the clear closing frame, direct
//! capture).
//!
//! The memfd travels with the create_pool request (SCM_RIGHTS): create()
//! flushes the connection so it has left before the fd is closed; after
//! that the mapping alone holds the memory on our side.

const std = @import("std");
const sys = @import("../sys.zig");
const protocol = @import("protocol.zig");
const Connection = @import("../wayland.zig").Connection;

/// Largest pool: create_pool's size is an int.
pub const max_size: usize = std.math.maxInt(i32);

pub const Pool = struct {
    /// wl_shm_pool; 0 once dropped (its buffers stay valid)
    id: u32 = 0,
    mem: []align(std.heap.page_size_min) u8 = &.{},

    /// A pool of `size` bytes (zeroed). Flushes `conn`.
    pub fn create(conn: *Connection, shm: u32, size: usize) !Pool {
        if (size == 0 or size > max_size) return error.BadBufferSize;
        if (shm == 0) return error.NoShm;
        const fd = try sys.memfdCreate("shotlet-shm", sys.MFD_CLOEXEC);
        defer sys.close(fd);
        try sys.ftruncate(fd, size);
        const mem = try sys.mmapRw(fd, size);
        errdefer sys.munmap(mem);
        const id = conn.newId();
        try conn.request(shm, protocol.wl_shm.create_pool, &.{ .{ .new_id = id }, .{ .fd = fd }, .{ .int = @intCast(size) } });
        try conn.flush(); // the fd goes out with these bytes: before close
        return .{ .id = id, .mem = mem };
    }

    /// A w x h wl_buffer at `offset` of the pool.
    pub fn buffer(self: *const Pool, conn: *Connection, offset: usize, w: u32, h: u32, stride: u32, format: u32) !u32 {
        if (self.id == 0) return error.NoPool;
        if (w == 0 or !fits(self.mem.len, offset, h, stride)) return error.BadBufferSize;
        const id = conn.newId();
        try conn.request(self.id, protocol.wl_shm_pool.create_buffer, &.{
            .{ .new_id = id },       .{ .int = @intCast(offset) }, .{ .int = @intCast(w) },
            .{ .int = @intCast(h) }, .{ .int = @intCast(stride) }, .{ .uint = format },
        });
        return id;
    }

    /// The bytes of the buffer at `offset` (stride * h of them).
    pub fn bytes(self: *const Pool, offset: usize, len: usize) []u8 {
        return self.mem[offset..][0..len];
    }

    /// Destroy the wl_shm_pool object; the memory and the buffers made
    /// from it stay.
    pub fn drop(self: *Pool, conn: *Connection) void {
        if (self.id != 0) conn.request(self.id, protocol.wl_shm_pool.destroy, &.{}) catch {};
        self.id = 0;
    }

    /// Drop the pool and unmap its memory (after its buffers are
    /// destroyed).
    pub fn deinit(self: *Pool, conn: *Connection) void {
        self.drop(conn);
        if (self.mem.len > 0) sys.munmap(self.mem);
        self.* = .{};
    }
};

/// Whether h rows of `stride` bytes from `offset` fit in `len` bytes.
fn fits(len: usize, offset: usize, h: u32, stride: u32) bool {
    const size = @as(u64, stride) * h;
    return size > 0 and offset <= len and size <= len - offset;
}

test "buffers must fit their pool" {
    try std.testing.expect(fits(800, 0, 10, 80));
    try std.testing.expect(fits(1600, 800, 10, 80));
    try std.testing.expect(!fits(1600, 801, 10, 80));
    try std.testing.expect(!fits(800, 0, 0, 80));
    try std.testing.expect(!fits(800, 900, 1, 4));
}
