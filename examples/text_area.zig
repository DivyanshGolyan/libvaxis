//! Multi-line editing with borrowed storage. Enter inserts a line; Ctrl-S
//! explicitly submits, and Ctrl-C quits. Paste routing stays with this editor.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Model = struct {
    storage: [4096]u8 = undefined,
    editor: vxfw.TextArea = undefined,
    pasting: bool = false,

    fn widget(self: *Model) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
    }

    fn event(raw: *anyopaque, ctx: *vxfw.EventContext, ev: vxfw.Event) !void {
        const self: *Model = @ptrCast(@alignCast(raw));
        switch (ev) {
            .init, .focus_in => try ctx.requestFocus(self.editor.widget()),
            .paste_start => self.pasting = true,
            .paste_end, .focus_out => self.pasting = false,
            .key_press => |key| {
                // Capture application bindings, rather than altering defaults.
                if (ctx.phase != .capturing or self.pasting) return;
                if (key.matchExact('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    ctx.consume_event = true;
                } else if (key.matchExact('s', .{ .ctrl = true })) {
                    _ = try self.editor.dispatch(ctx, .submit);
                }
            },
            else => {},
        }
    }

    fn submitted(_: ?*anyopaque, ctx: *vxfw.EventContext, _: []const u8) !void {
        // Applications can copy/enqueue the borrowed value here. This example
        // simply finishes, leaving the editor untouched during notification.
        ctx.quit = true;
    }

    fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(raw));
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.editor.draw(ctx) };
        return .{ .size = ctx.max.size(), .widget = self.widget(), .buffer = &.{}, .children = children };
    }
};

pub fn main(init: std.process.Init) !void {
    var tty_buffer: [1024]u8 = undefined;
    var app = try vxfw.App.init(init.io, init.gpa, init.environ_map, &tty_buffer);
    defer app.deinit();
    // Initialize self-references only after the model has its final address.
    var model: Model = .{};
    model.editor = vxfw.TextArea.init(&model.storage);
    model.editor.onSubmit = Model.submitted;
    const initial = "A multi-line TextArea\nEnter adds a line. Ctrl-S submits; Ctrl-C quits.";
    _ = model.editor.setText(initial, initial.len);
    try app.run(model.widget(), .{});
}

test {
    std.testing.refAllDecls(@This());
}

test "application shortcuts do not interpret pasted controls" {
    var model: Model = .{};
    model.editor = vxfw.TextArea.init(&model.storage);
    var ctx: vxfw.EventContext = .{
        .io = std.testing.io,
        .alloc = std.testing.allocator,
        .cmds = .empty,
        .phase = .capturing,
    };
    defer ctx.cmds.deinit(std.testing.allocator);
    try Model.event(&model, &ctx, .paste_start);
    try Model.event(&model, &ctx, .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } });
    try std.testing.expect(!ctx.quit and !ctx.consume_event);
    try Model.event(&model, &ctx, .paste_end);
    try Model.event(&model, &ctx, .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } });
    try std.testing.expect(ctx.quit and ctx.consume_event);
}
