const std = @import("std");
const vaxis = @import("vaxis");

pub fn main(init: std.process.Init) !void {
    var memory: std.testing.FailingAllocator = .init(std.heap.page_allocator, .{ .fail_index = 0 });
    var output: [4096]u8 = undefined;
    var app = vaxis.vxfw.App.init(init.io, memory.allocator(), init.environ_map, &output) catch |err| {
        if (err != error.OutOfMemory) return err;
        try std.Io.File.stderr().writeStreamingAll(init.io, "App.init: OutOfMemory\n");
        return;
    };
    app.deinit();
    return error.ExpectedAllocationFailure;
}
