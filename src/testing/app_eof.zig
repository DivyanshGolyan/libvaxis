const std = @import("std");
const vaxis = @import("vaxis");

pub fn main(init: std.process.Init) !void {
    // Isolate reader EOF from the signal delivered by a real terminal hangup.
    const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(std.posix.SIG.HUP, &ignore, null);
    var output: [4096]u8 = undefined;
    var app = try vaxis.vxfw.App.init(init.io, std.heap.page_allocator, init.environ_map, &output);
    defer app.deinit();
    var probe: Probe = .{};
    try app.run(probe.widget(), .{});
    try std.Io.File.stderr().writeStreamingAll(init.io, "reader quit\n");
}

const Probe = struct {
    text: vaxis.vxfw.Text = .{ .text = "EOF probe ready" },

    fn widget(self: *Probe) vaxis.vxfw.Widget {
        return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
    }

    fn event(_: *anyopaque, _: *vaxis.vxfw.EventContext, input: vaxis.vxfw.Event) !void {
        if (input == .key_press) return error.EndOfStream;
    }

    fn draw(raw: *anyopaque, ctx: vaxis.vxfw.DrawContext) std.mem.Allocator.Error!vaxis.vxfw.Surface {
        const self: *Probe = @ptrCast(@alignCast(raw));
        var surface = try self.text.widget().draw(ctx);
        surface.widget = self.widget();
        return surface;
    }
};
