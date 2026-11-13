const std = @import("std");
const vaxis = @import("main.zig");
const Image = @import("Image.zig");
const Vaxis = @import("Vaxis.zig");
const Screen = @import("Screen.zig");
const View = @import("widgets/View.zig");
const vxfw = @import("vxfw/vxfw.zig");
const testing = std.testing;

test "image references: several placements retain independent options and emit unchanged" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var vx = try Vaxis.init(testing.io, testing.allocator, &env, .{});
    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    defer vx.deinit(testing.allocator, &writer.writer);
    try vx.resize(testing.allocator, &writer.writer, .{ .cols = 16, .rows = 8, .x_pixel = 160, .y_pixel = 80 });
    const win = vx.window();
    win.clear();

    // Enough placements to grow the arena, without invalidating earlier cells.
    for (0..128) |i| {
        const child = win.child(.{ .x_off = @intCast(i % 16), .y_off = @intCast(i / 16) });
        const image = Image.init(@intCast(i + 1), 10, 10);
        try image.draw(child, .{ .z_index = @intCast(i) });
    }
    const first = Image.init(901, 10, 10);
    try first.draw(win, .{
        .pixel_offset = .{ .x = 2, .y = 3 },
        .clip_region = .{ .x = 4, .y = 5, .width = 6, .height = 7 },
        .size = .{ .rows = 2, .cols = 3 },
        .z_index = -4,
    });
    const second = Image.init(902, 10, 10);
    try second.draw(win.child(.{ .x_off = 1 }), .{ .scale = .fill });
    try testing.expectEqual(@as(u32, 901), win.readCell(0, 0).?.image.?.img_id);
    try testing.expectEqual(@as(u32, 902), win.readCell(1, 0).?.image.?.img_id);
    try testing.expectEqual(@as(u32, 128), win.readCell(15, 7).?.image.?.img_id);

    const start = writer.written().len;
    try vx.render(&writer.writer);
    const output = writer.written()[start..];
    try testing.expect(std.mem.indexOf(u8, output, "\x1b_Ga=p,i=901,X=2,Y=3,x=4,y=5,w=6,h=7,r=2,c=3,z=-4,C=1\x1b\\") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b_Ga=p,i=902,r=8,c=15,C=1\x1b\\") != null);
    try testing.expectEqual(@as(usize, 128), std.mem.count(u8, output, "\x1b_Ga=p,i="));
}

test "image references: redraw, full clear and resize release placements" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var vx = try Vaxis.init(testing.io, testing.allocator, &env, .{});
    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    defer vx.deinit(testing.allocator, &writer.writer);
    try vx.resize(testing.allocator, &writer.writer, .{ .cols = 2, .rows = 1, .x_pixel = 20, .y_pixel = 10 });
    const image = Image.init(42, 10, 10);
    for (0..3) |frame| {
        vx.window().clear();
        try testing.expectEqual(@as(usize, 0), vx.screen.image_arena.?.queryCapacity());
        try image.draw(vx.window(), .{ .z_index = @intCast(frame) });
        const start = writer.written().len;
        try vx.render(&writer.writer);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, writer.written()[start..], "\x1b_Ga=p,i=42"));
        try testing.expectEqual(@as(i32, @intCast(frame)), vx.screen.readCell(0, 0).?.image.?.options.z_index.?);
        // Images are deliberately emitted again even when the cached text matches.
        const again = writer.written().len;
        try vx.render(&writer.writer);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, writer.written()[again..], "\x1b_Ga=p,i=42"));
    }
    vx.screen.clear();
    try testing.expect(vx.screen.readCell(0, 0).?.image == null);
    try testing.expectEqual(@as(usize, 0), vx.screen.image_arena.?.queryCapacity());
    const start = writer.written().len;
    try vx.render(&writer.writer);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, writer.written()[start..], "\x1b_Ga=p,i="));
    try image.draw(vx.window(), .{});
    try vx.resize(testing.allocator, &writer.writer, .{ .cols = 3, .rows = 2, .x_pixel = 30, .y_pixel = 20 });
    try testing.expect(vx.screen.readCell(0, 0).?.image == null);
    try testing.expectEqual(@as(usize, 0), vx.screen.image_arena.?.queryCapacity());
    try image.draw(vx.window().child(.{ .x_off = 2, .y_off = 1 }), .{});
    try testing.expectEqual(@as(u32, 42), vx.screen.readCell(2, 1).?.image.?.img_id);
}

test "image references: surface copies survive release of the source arena" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var vx = try Vaxis.init(testing.io, testing.allocator, &env, .{});
    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    defer vx.deinit(testing.allocator, &writer.writer);
    try vx.resize(testing.allocator, &writer.writer, .{ .cols = 2, .rows = 1, .x_pixel = 20, .y_pixel = 10 });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text: vxfw.Text = .{ .text = "" };
    const surface = try vxfw.Surface.init(arena.allocator(), text.widget(), .{ .width = 2, .height = 1 });
    const placement = try arena.allocator().create(Image.Placement);
    placement.* = .{ .img_id = 73, .options = .{ .z_index = 5 } };
    surface.writeCell(0, 0, .{ .image = placement });
    try surface.render(vx.window(), text.widget());
    try testing.expect(vx.screen.readCell(0, 0).?.image.? != placement);
    _ = arena.reset(.free_all);
    try testing.expectEqual(@as(u32, 73), vx.screen.readCell(0, 0).?.image.?.img_id);
    const start = writer.written().len;
    try vx.render(&writer.writer);
    try testing.expect(std.mem.indexOf(u8, writer.written()[start..], "\x1b_Ga=p,i=73,z=5,C=1\x1b\\") != null);
}

test "image references: view copies survive clearing the source screen" {
    var screen = try Screen.init(testing.allocator, .{ .cols = 2, .rows = 1, .x_pixel = 20, .y_pixel = 10 });
    defer screen.deinit(testing.allocator);
    var view = try View.init(testing.allocator, .{ .width = 2, .height = 1 });
    defer view.deinit();
    const image = Image.init(86, 10, 10);
    try image.draw(view.window(), .{ .z_index = 9 });
    const win: vaxis.Window = .{ .screen = &screen, .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 2, .height = 1 };
    try view.draw(win, .{});
    try testing.expect(screen.readCell(0, 0).?.image.? != view.screen.readCell(0, 0).?.image.?);
    view.window().clear();
    try testing.expectEqual(@as(u32, 86), screen.readCell(0, 0).?.image.?.img_id);
}

test "image references: allocation failure preserves the destination cell" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    var screen = try Screen.init(failing.allocator(), .{ .cols = 1, .rows = 1, .x_pixel = 10, .y_pixel = 10 });
    defer screen.deinit(failing.allocator());
    failing.fail_index = failing.alloc_index;
    const win: vaxis.Window = .{ .screen = &screen, .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 1, .height = 1 };
    const image = Image.init(1, 10, 10);
    try testing.expectError(error.OutOfMemory, image.draw(win, .{}));
    try testing.expect(screen.readCell(0, 0).?.image == null);
    // Clipped images do not allocate, even if the allocator would fail.
    try image.draw(win.child(.{ .width = 0 }), .{});
}
