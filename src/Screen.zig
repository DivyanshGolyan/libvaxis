const std = @import("std");
const assert = std.debug.assert;

const Cell = @import("Cell.zig");
const Shape = @import("Mouse.zig").Shape;
const Image = @import("Image.zig");
const Winsize = @import("main.zig").Winsize;
const Method = @import("gwidth").Method;

const Screen = @This();
pub const Cursor = struct { row: u16 = 0, col: u16 = 0 };

width: u16 = 0,
height: u16 = 0,

width_pix: u16 = 0,
height_pix: u16 = 0,

buf: []Cell = &.{},

// Individual arena allocations remain stable as more images are drawn. The
// arena owns placements, not image pixels, and is released with a full clear.
image_arena: ?std.heap.ArenaAllocator = null,

cursor: Cursor = .{},
cursor_vis: bool = false,
cursor_secondary: []Cursor = &.{},

width_method: Method = .wcwidth,

mouse_shape: Shape = .default,
cursor_shape: Cell.CursorShape = .default,

pub fn init(alloc: std.mem.Allocator, winsize: Winsize) std.mem.Allocator.Error!Screen {
    const w = winsize.cols;
    const h = winsize.rows;
    const self = Screen{
        .buf = try alloc.alloc(Cell, @as(usize, @intCast(w)) * h),
        .image_arena = .init(alloc),
        .width = w,
        .height = h,
        .width_pix = winsize.x_pixel,
        .height_pix = winsize.y_pixel,
    };
    const base_cell: Cell = .{};
    @memset(self.buf, base_cell);
    return self;
}

pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
    if (self.image_arena) |*arena| arena.deinit();
    alloc.free(self.buf);
}

/// Copy a cell's image placement into this screen. Text and links remain
/// borrowed, as with writeCell. The returned image reference is valid until a
/// full clear or deinit of this screen, independently of the source cell.
pub fn copyCell(self: *Screen, cell: Cell) std.mem.Allocator.Error!Cell {
    var copy = cell;
    if (cell.image) |image| {
        const arena = if (self.image_arena) |*arena| arena else return error.OutOfMemory;
        const placement = try arena.allocator().create(Image.Placement);
        placement.* = image.*;
        copy.image = placement;
    }
    return copy;
}

/// Writes a borrowed cell to a location. 0 indexed. Referenced data must remain
/// valid until the cell is overwritten or the screen is cleared.
/// Window.writeCellOwned copies image placements instead.
pub fn writeCell(self: *Screen, col: u16, row: u16, cell: Cell) void {
    if (col >= self.width or
        row >= self.height)
        return;
    const i = (@as(usize, @intCast(row)) * self.width) + col;
    assert(i < self.buf.len);
    self.buf[i] = cell;
}

pub fn readCell(self: *const Screen, col: u16, row: u16) ?Cell {
    if (col >= self.width or
        row >= self.height)
        return null;
    const i = (@as(usize, @intCast(row)) * self.width) + col;
    assert(i < self.buf.len);
    return self.buf[i];
}

/// Fill the screen, releasing old image placements when the fill has no image.
pub fn fill(self: *Screen, cell: Cell) void {
    @memset(self.buf, cell);
    if (cell.image == null) {
        if (self.image_arena) |*arena| _ = arena.reset(.free_all);
    }
}

pub fn clear(self: *Screen) void {
    self.fill(.{});
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}

test {
    std.testing.refAllDecls(@This());
}
