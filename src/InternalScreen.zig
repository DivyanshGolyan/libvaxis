const std = @import("std");
const assert = std.debug.assert;
const Style = @import("Cell.zig").Style;
const Cell = @import("Cell.zig");
const MouseShape = @import("Mouse.zig").Shape;
const CursorShape = Cell.CursorShape;

const log = std.log.scoped(.vaxis);

const InternalScreen = @This();

/// Arena-backed cached bytes. Cell strings do not need usize-sized lengths or
/// ArrayList's pointer-stability bookkeeping in every cached cell.
pub const CachedBytes = struct {
    ptr: [*]u8 = @constCast((&[_]u8{}).ptr),
    len: u32 = 0,
    capacity: u32 = 0,

    pub const empty: CachedBytes = .{};

    pub fn slice(self: CachedBytes) []u8 {
        return self.ptr[0..self.len];
    }
};

pub const InternalCell = struct {
    char: CachedBytes = .empty,
    style: Style = .{},
    uri: CachedBytes = .empty,
    uri_id: CachedBytes = .empty,
    // if we got skipped because of a wide character
    skipped: bool = false,
    default: bool = true,

    // If we should skip rendering *this* round due to being printed over previously (from a scaled
    // cell, for example)
    skip: bool = false,

    scale: Cell.Scale = .{},

    pub fn eql(self: *const InternalCell, cell: *const Cell) bool {

        // fastpath when both cells are default
        if (self.default and cell.default) return true;

        return std.mem.eql(u8, self.char.slice(), cell.char.grapheme) and
            Style.eql(self.style, cell.style) and
            std.mem.eql(u8, self.uri.slice(), cell.link.uri) and
            std.mem.eql(u8, self.uri_id.slice(), cell.link.params);
    }
};

arena: *std.heap.ArenaAllocator,
width: u16 = 0,
height: u16 = 0,

buf: []InternalCell,

cursor_vis: bool = false,
cursor_shape: CursorShape = .default,

mouse_shape: MouseShape = .default,

/// sets each cell to the default cell
pub fn init(gpa: std.mem.Allocator, w: u16, h: u16) !InternalScreen {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    var screen = InternalScreen{
        .arena = arena,
        .buf = try arena.allocator().alloc(InternalCell, @as(usize, @intCast(w)) * h),
    };
    for (screen.buf, 0..) |_, i| {
        screen.buf[i] = .{};
        try setBytes(&screen.buf[i].char, arena.allocator(), " ");
    }
    screen.width = w;
    screen.height = h;
    return screen;
}

pub fn deinit(self: *InternalScreen, alloc: std.mem.Allocator) void {
    self.arena.deinit();
    alloc.destroy(self.arena);
    self.* = undefined;
}

/// writes a cell to a location. 0 indexed
pub fn writeCell(
    self: *InternalScreen,
    col: u16,
    row: u16,
    cell: Cell,
) void {
    if (self.width <= col) {
        // column out of bounds
        return;
    }
    if (self.height <= row) {
        // height out of bounds
        return;
    }
    const i = (@as(usize, @intCast(row)) * self.width) + col;
    assert(i < self.buf.len);
    setBytes(&self.buf[i].char, self.arena.allocator(), cell.char.grapheme) catch |err| {
        log.warn("couldn't write grapheme: {t}", .{err});
    };
    setBytes(&self.buf[i].uri, self.arena.allocator(), cell.link.uri) catch |err| {
        log.warn("couldn't write uri: {t}", .{err});
    };
    setBytes(&self.buf[i].uri_id, self.arena.allocator(), cell.link.params) catch |err| {
        log.warn("couldn't write uri_id: {t}", .{err});
    };
    self.buf[i].style = cell.style;
    self.buf[i].default = cell.default;
}

/// Replaces a cached cell string. The list grows to a power of two, not by
/// ArrayList's policy, which adds a cache line: the arena never frees the old
/// block, so each cell that outgrew its first byte held ~64 unused bytes. On
/// error the string is left empty, which no frame matches, so the cell redraws.
fn setBytes(list: *CachedBytes, arena: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!void {
    list.len = 0;
    const len = std.math.cast(u32, bytes.len) orelse return error.OutOfMemory;
    if (len > list.capacity) {
        const capacity = std.math.cast(u32, std.math.ceilPowerOfTwo(usize, bytes.len) catch bytes.len) orelse return error.OutOfMemory;
        const old_memory = list.ptr[0..list.capacity];
        // Match ArrayList.ensureTotalCapacityPrecise: try remap first, then
        // allocate and free the old block only after allocation succeeds. The
        // cleared length means there are no old bytes to copy on either path.
        const memory = arena.remap(old_memory, capacity) orelse blk: {
            const memory = try arena.alloc(u8, capacity);
            arena.free(old_memory);
            break :blk memory;
        };
        list.ptr = memory.ptr;
        list.capacity = capacity;
    }
    @memcpy(list.ptr[0..len], bytes);
    list.len = len;
}

pub fn readCell(self: *InternalScreen, col: u16, row: u16) ?Cell {
    if (self.width <= col) {
        // column out of bounds
        return null;
    }
    if (self.height <= row) {
        // height out of bounds
        return null;
    }
    const i = (row * self.width) + col;
    assert(i < self.buf.len);
    const cell = self.buf[i];
    return .{
        .char = .{ .grapheme = cell.char.slice() },
        .style = cell.style,
        .link = .{
            .uri = cell.uri.slice(),
            .params = cell.uri_id.slice(),
        },
        .default = cell.default,
    };
}

test "InternalScreen: out-of-bounds read/write are ignored" {
    var screen = try InternalScreen.init(std.testing.allocator, 2, 2);
    defer screen.deinit(std.testing.allocator);

    const sentinel: Cell = .{ .char = .{ .grapheme = "A", .width = 1 } };
    screen.writeCell(0, 1, sentinel);

    const oob_cell: Cell = .{ .char = .{ .grapheme = "X", .width = 1 } };
    screen.writeCell(2, 0, oob_cell);
    const read_back = screen.readCell(0, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.eql(u8, read_back.char.grapheme, "A"));
    try std.testing.expect(screen.readCell(2, 0) == null);
}

test {
    std.testing.refAllDecls(@This());
}

test "InternalCell has compact cached string headers" {
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(usize, 16), @sizeOf(CachedBytes));
        try std.testing.expectEqual(@as(usize, 80), @sizeOf(InternalCell));
    }
}

test "cached bytes retain upstream growth, contents and in-place remapping" {
    var buffer: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    var bytes: CachedBytes = .empty;
    try setBytes(&bytes, fba.allocator(), "a");
    const first = bytes.ptr;
    try setBytes(&bytes, fba.allocator(), "abcdefg");
    try std.testing.expectEqual(first, bytes.ptr);
    try std.testing.expectEqual(@as(u32, 8), bytes.capacity);
    try std.testing.expectEqualStrings("abcdefg", bytes.slice());
    try setBytes(&bytes, fba.allocator(), "b");
    try std.testing.expectEqual(@as(u32, 8), bytes.capacity);
    try setBytes(&bytes, fba.allocator(), "");
    try std.testing.expectEqual(@as(u32, 0), bytes.len);
    try std.testing.expectEqual(@as(u32, 8), bytes.capacity);

    // Force the fallback path by putting another allocation after the string.
    _ = try fba.allocator().alloc(u8, 1);
    try setBytes(&bytes, fba.allocator(), "123456789");
    try std.testing.expect(first != bytes.ptr);
    try std.testing.expectEqual(@as(u32, 16), bytes.capacity);
    try std.testing.expectEqualStrings("123456789", bytes.slice());
}

test "cached bytes leave an empty string and retain storage on allocation failure" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .resize_fail_index = 0 });
    const allocator = failing.allocator();
    var bytes: CachedBytes = .empty;
    defer allocator.free(bytes.ptr[0..bytes.capacity]);
    try setBytes(&bytes, allocator, "old");
    const ptr = bytes.ptr;
    const capacity = bytes.capacity;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, setBytes(&bytes, allocator, "a longer value"));
    try std.testing.expectEqual(@as(u32, 0), bytes.len);
    try std.testing.expectEqual(ptr, bytes.ptr);
    try std.testing.expectEqual(capacity, bytes.capacity);
    failing.fail_index = std.math.maxInt(usize);
    try setBytes(&bytes, allocator, "a longer value");
    try std.testing.expectEqualStrings("a longer value", bytes.slice());
    try std.testing.expectEqual(@as(u32, 16), bytes.capacity);
}

test "InternalScreen copies and compares all three cached strings" {
    var screen = try InternalScreen.init(std.testing.allocator, 1, 1);
    defer screen.deinit(std.testing.allocator);
    const cell: Cell = .{
        .char = .{ .grapheme = "hello" },
        .link = .{ .uri = "https://example.com", .params = "id=test" },
        .style = .{ .bold = true },
    };
    screen.writeCell(0, 0, cell);
    try std.testing.expect(screen.buf[0].eql(&cell));
    const read = screen.readCell(0, 0).?;
    try std.testing.expectEqualStrings(cell.char.grapheme, read.char.grapheme);
    try std.testing.expectEqualStrings(cell.link.uri, read.link.uri);
    try std.testing.expectEqualStrings(cell.link.params, read.link.params);
    try std.testing.expectEqual(@as(u32, 8), screen.buf[0].char.capacity);
    try std.testing.expectEqual(@as(u32, 32), screen.buf[0].uri.capacity);
    try std.testing.expectEqual(@as(u32, 8), screen.buf[0].uri_id.capacity);
    screen.writeCell(0, 0, .{});
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("", screen.readCell(0, 0).?.link.uri);
}
