const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

pub fn main(init: std.process.Init) !void {
    var output: [4096]u8 = undefined;
    var app = try vxfw.App.init(init.io, std.heap.page_allocator, init.environ_map, &output);
    defer app.deinit();
    var leaf: Node = .{ .name = "leaf" };
    var screen: Node = .{ .name = "screen", .child = &leaf };
    var root: Node = .{ .name = "root", .child = &screen };
    try app.run(root.widget(), .{});
}

const Node = struct {
    name: []const u8,
    child: ?*Node = null,

    fn widget(self: *Node) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
    }

    fn event(raw: *anyopaque, ctx: *vxfw.EventContext, value: vxfw.Event) !void {
        const self: *Node = @ptrCast(@alignCast(raw));
        switch (value) {
            .init, .focus_in => if (self.child) |child| {
                try ctx.requestFocus(child.widget());
            },
            .key_press => {
                if (ctx.phase != .at_target) return;
                std.debug.print("target={s}\n", .{self.name});
                ctx.consumeEvent();
                ctx.quit = true;
            },
            else => {},
        }
    }

    fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Node = @ptrCast(@alignCast(raw));
        if (self.child) |child| {
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try child.widget().draw(ctx) };
            return .{ .widget = self.widget(), .size = ctx.max.size(), .buffer = &.{}, .children = children };
        }
        const text: vxfw.Text = .{ .text = "Focus probe ready" };
        var surface = try text.widget().draw(ctx);
        surface.widget = self.widget();
        return surface;
    }
};
