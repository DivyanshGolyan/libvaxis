const std = @import("std");
const testing = std.testing;
const T = @import("../TextArea.zig");
const vxfw = @import("../vxfw.zig");
const vaxis = @import("../../main.zig");

fn insert(area: *T, bytes: []const u8) T.Result {
    return area.apply(.{ .insert = .{ .bytes = bytes } });
}

fn expectText(area: *const T, bytes: []const u8, cursor: usize) !void {
    try testing.expectEqualStrings(bytes, area.text());
    try testing.expectEqual(cursor, area.byteOffsetToCursor());
}

fn context(allocator: std.mem.Allocator) vxfw.EventContext {
    return .{ .io = testing.io, .alloc = allocator, .cmds = .empty, .redraw = false };
}

fn drawContext(allocator: std.mem.Allocator, width: u16, height: u16) vxfw.DrawContext {
    if (@hasField(vxfw.DrawContext, "cell_arena")) return .{ .arena = allocator, .cell_arena = allocator, .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} };
    return .{ .arena = allocator, .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} };
}

test "grapheme deletion distinct word operations multiline paste and tabs" {
    var storage: [100]u8 = undefined;
    var area = T.init(&storage);
    _ = insert(&area, "A中e\u{301}🧑‍🌾");
    _ = area.apply(.delete_previous);
    try expectText(&area, "A中e\u{301}", "A中e\u{301}".len);
    _ = area.clear();
    _ = insert(&area, "ask src/foo-bar");
    _ = area.apply(.delete_word_part);
    try testing.expectEqualStrings("ask src/foo-", area.text());
    _ = area.clear();
    _ = insert(&area, "ask src/foo-bar");
    _ = area.apply(.delete_word);
    try testing.expectEqualStrings("ask ", area.text());
    _ = area.clear();
    _ = area.apply(.beginPaste);
    _ = area.apply(.{ .feedPaste = "line1\nline2" });
    _ = area.apply(.{ .endPaste = .marker });
    try testing.expectEqualStrings("line1\nline2", area.text());
    _ = area.clear();
    _ = insert(&area, "left\tright");
    try testing.expectEqualStrings("left\tright", area.text());
}

test "capacity is bytes and streaming overflow keeps a valid prefix without latching" {
    var storage: [4]u8 = undefined;
    var area = T.init(&storage);
    const result = insert(&area, "é中");
    try testing.expectEqual(T.Failure.capacity, result.failure.?);
    try testing.expectEqual(@as(usize, 1), result.edit_count);
    try expectText(&area, "é", 2);
    _ = area.apply(.delete_previous);
    try testing.expectEqual(@as(?T.Failure, null), insert(&area, "中a").failure);
    try expectText(&area, "中a", 4);
    try testing.expectEqual(T.Failure.capacity, insert(&area, "b").failure.?);
    _ = area.clear();
    try testing.expectEqual(@as(?T.Failure, null), insert(&area, "ok").failure);
    var empty: [0]u8 = .{};
    var zero = T.init(&empty);
    try testing.expectEqual(T.Failure.capacity, insert(&zero, "a").failure.?);
    try testing.expectEqual(@as(usize, 0), zero.clear().edit_count);
}

test "arbitrary storage sizes including more than one bank" {
    for ([_]usize{ 1, 7, 31, 65537, 70001 }) |capacity| {
        const storage = try testing.allocator.alloc(u8, capacity);
        defer testing.allocator.free(storage);
        const source = try testing.allocator.alloc(u8, capacity);
        defer testing.allocator.free(source);
        @memset(source, 'x');
        var area = T.init(storage);
        const restored = area.setText(source, source.len);
        try testing.expectEqual(@as(?T.Failure, null), restored.failure);
        try testing.expectEqual(capacity, area.text().len);
        try testing.expectEqual(T.Failure.capacity, insert(&area, "y").failure.?);
        try testing.expectEqual(@as(usize, 1), area.apply(.delete_previous).edit_count);
        try testing.expectEqual(@as(?T.Failure, null), insert(&area, "y").failure);
    }
}

test "inserted joiner repairs the caret before an emoji suffix" {
    var storage: [80]u8 = undefined;
    var area = T.init(&storage);
    _ = insert(&area, "🧑🌾");
    _ = area.apply(.left);
    _ = insert(&area, "\u{200d}");
    try expectText(&area, "🧑‍🌾", "🧑‍🌾".len);
    _ = area.apply(.delete_previous);
    try expectText(&area, "", 0);
}

test "separator deletion repairs the caret after adjacent graphemes join" {
    var storage: [80]u8 = undefined;
    var area = T.init(&storage);
    _ = insert(&area, "🧑\u{200d}\n🌾");
    _ = area.apply(.line_start);
    try testing.expectEqual("🧑\u{200d}\n".len, area.byteOffsetToCursor());
    _ = area.apply(.delete_previous);
    try expectText(&area, "🧑‍🌾", "🧑‍🌾".len);
    _ = area.apply(.delete_previous);
    try expectText(&area, "", 0);
}

test "flag and variation selector each delete as one grapheme" {
    var storage: [80]u8 = undefined;
    var area = T.init(&storage);
    _ = insert(&area, "⌚\u{fe0f}🇺🇸");
    _ = area.apply(.delete_previous);
    try testing.expectEqualStrings("⌚\u{fe0f}", area.text());
    _ = area.apply(.delete_previous);
    try expectText(&area, "", 0);
}

test "word movement skips separators and stops at original word edges" {
    var storage: [80]u8 = undefined;
    var area = T.init(&storage);
    _ = insert(&area, "one two/三");
    _ = area.apply(.word_left);
    try testing.expectEqualStrings("三", area.text()[area.byteOffsetToCursor()..]);
    _ = area.apply(.word_left);
    try testing.expectEqualStrings("two/三", area.text()[area.byteOffsetToCursor()..]);
    _ = area.apply(.word_left);
    try testing.expectEqualStrings("one two/三", area.text()[area.byteOffsetToCursor()..]);
    _ = area.apply(.word_right);
    try testing.expectEqualStrings(" two/三", area.text()[area.byteOffsetToCursor()..]);
    _ = area.apply(.word_right);
    try testing.expectEqualStrings("/三", area.text()[area.byteOffsetToCursor()..]);
    _ = area.setText("a\u{203f}b\u{3000}c", "a\u{203f}b\u{3000}c".len);
    _ = area.apply(.delete_word);
    try testing.expectEqualStrings("a\u{203f}b\u{3000}", area.text());
    _ = area.apply(.word_left);
    try testing.expectEqual("a\u{203f}".len, area.byteOffsetToCursor());
}

test "vertical movement counts hard-line graphemes not cell columns or wraps" {
    var storage: [80]u8 = undefined;
    var area = T.init(&storage);
    _ = area.setText("中e\u{301}x\na\nbcd", "中e\u{301}".len);
    try testing.expect(!area.apply(.up).handled);
    try testing.expect(area.apply(.down).handled);
    try testing.expectEqual("中e\u{301}x\na".len, area.byteOffsetToCursor());
    _ = area.apply(.down);
    try testing.expectEqual("中e\u{301}x\na\nb".len, area.byteOffsetToCursor());
    try testing.expect(!area.apply(.down).handled);
    _ = area.apply(.line_end);
    try testing.expectEqual(area.text().len, area.byteOffsetToCursor());
    _ = area.apply(.buffer_start);
    try testing.expectEqual(@as(usize, 0), area.byteOffsetToCursor());
}

test "checked restores and ranges reject interior grapheme offsets atomically" {
    var storage: [80]u8 = undefined;
    var area = T.init(&storage);
    _ = area.setText("ae\u{301}z", 0);
    for ([_]usize{ 2, 3, 99 }) |at| {
        try testing.expectEqual(T.Failure.invalid_range, area.setCursor(at).failure.?);
        try testing.expectEqual(T.Failure.invalid_range, area.setText("ae\u{301}z", at).failure.?);
        try testing.expectEqual(T.Failure.invalid_range, area.replace(.{ .start = 0, .end = at }, "x").failure.?);
        try expectText(&area, "ae\u{301}z", 0);
    }
    try testing.expectEqual(T.Failure.invalid_range, area.replace(.{ .start = 4, .end = 1 }, "x").failure.?);
    try testing.expectEqual(T.Failure.invalid_utf8, area.setText("\xff", 0).failure.?);
    try testing.expectEqual(T.Failure.invalid_scalar, area.setText("\x1b", 0).failure.?);
    try testing.expectEqual(T.Failure.unrenderable, area.setText("\u{301}", 0).failure.?);
    try expectText(&area, "ae\u{301}z", 0);
    // Same-text restore and overlapping sub-slice restore require no backup.
    try testing.expectEqual(@as(usize, 0), area.setText(area.text(), 4).edit_count);
    try testing.expectEqual(@as(usize, 0), area.setText(area.text(), 4).edit_count);
    _ = area.setText(area.text()[1..], 0);
    try expectText(&area, "e\u{301}z", 0);
    try testing.expectEqual(T.Failure.invalid_range, area.replace(.{ .start = 0, .end = 0 }, area.text()).failure.?);
}

test "replacement preflights size and leaves the caret after its accepted text" {
    var storage: [24]u8 = undefined;
    var area = T.init(&storage);
    _ = area.setText("use /re on it", "use /re".len);
    _ = area.replace(.{ .start = 4, .end = 7 }, "/review ");
    try expectText(&area, "use /review  on it", "use /review ".len);
    var small: [12]u8 = undefined;
    area = T.init(&small);
    _ = area.setText("go /re now", "go /re".len);
    const failed = area.replace(.{ .start = 3, .end = 6 }, "/review ");
    try testing.expectEqual(T.Failure.capacity, failed.failure.?);
    try testing.expectEqual(@as(usize, 0), failed.edit_count);
    try expectText(&area, "go /re now", "go /re".len);
    _ = area.replace(.{ .start = 3, .end = 6 }, "a\xff");
    try expectText(&area, "go a now", 4);
    area = T.init(&storage);
    _ = area.setText("🧑\n🌾", "🧑".len);
    _ = area.replace(.{ .start = "🧑".len, .end = "🧑\n".len }, "\u{200d}");
    try expectText(&area, "🧑‍🌾", "🧑‍🌾".len);
}

test "partial scalar staging malformed fragments and incomplete paste end" {
    var storage: [40]u8 = undefined;
    var area = T.init(&storage);
    try testing.expectEqual(@as(usize, 0), insert(&area, "\xe4").edit_count);
    try expectText(&area, "", 0);
    _ = insert(&area, "\xb8");
    try testing.expectEqual(@as(usize, 1), insert(&area, "\xad").edit_count);
    try expectText(&area, "中", 3);
    try testing.expectEqual(T.Failure.invalid_utf8, insert(&area, "\xc0\x80").failure.?);
    try testing.expectEqual(T.Failure.invalid_utf8, insert(&area, "\xed\xa0\x80").failure.?);
    _ = insert(&area, "\xe2");
    try testing.expectEqual(T.Failure.invalid_utf8, insert(&area, "(x").failure.?);
    try expectText(&area, "中", 3);
    _ = insert(&area, "ok");
    _ = area.apply(.beginPaste);
    _ = area.apply(.{ .feedPaste = "\xf0\x9f" });
    const ended = area.apply(.{ .endPaste = .marker });
    try testing.expectEqual(@as(?T.Failure, null), ended.failure);
    _ = insert(&area, "!");
    try expectText(&area, "中ok!", "中ok!".len);
}

test "standalone zero-width edits decline and unrenderable paste rolls back exactly" {
    var storage: [256]u8 = undefined;
    for ([_][]const u8{ "\u{301}", "\u{200d}", "\u{fe0f}" }) |scalar| {
        var area = T.init(&storage);
        _ = area.setText("kept", 0);
        try testing.expectEqual(T.Failure.unrenderable, insert(&area, scalar).failure.?);
        try expectText(&area, "kept", 0);
        _ = area.apply(.beginPaste);
        _ = area.apply(.{ .feedPaste = "pasted\n" });
        const rejected = area.apply(.{ .feedPaste = scalar });
        try testing.expectEqual(@as(usize, 1), rejected.edit_count);
        _ = area.apply(.{ .feedPaste = "discarded" });
        const ended = area.apply(.{ .endPaste = .marker });
        try testing.expectEqual(T.Failure.unrenderable, ended.failure.?);
        try testing.expect(ended.paste.?.rolled_back);
        try expectText(&area, "kept", 0);
        _ = insert(&area, "é🧑‍🌾");
        try testing.expectEqualStrings("é🧑‍🌾kept", area.text());
    }
}

test "paste capacity rollback preserves both suffix and prefix while invalid input keeps prefix" {
    var storage: [16]u8 = undefined;
    var area = T.init(&storage);
    _ = area.setText("leftRIGHT", 4);
    _ = area.apply(.beginPaste);
    try testing.expectEqual(T.Failure.paste_active, area.apply(.left).failure.?);
    try testing.expectEqual(T.Failure.paste_active, area.clear().failure.?);
    try testing.expectEqual(T.Failure.paste_active, area.setCursor(0).failure.?);
    try testing.expectEqual(T.Failure.paste_active, area.replace(.{ .start = 0, .end = 0 }, "x").failure.?);
    _ = area.apply(.{ .feedPaste = "abcdefgh" });
    _ = area.apply(.{ .feedPaste = "discarded" });
    const rollback = area.apply(.{ .endPaste = .marker });
    try testing.expectEqual(T.Failure.capacity, rollback.failure.?);
    try testing.expect(rollback.paste.?.rolled_back);
    try expectText(&area, "leftRIGHT", 4);
    _ = area.apply(.beginPaste);
    _ = area.apply(.{ .feedPaste = "ok\xffrest" });
    const invalid = area.apply(.{ .endPaste = .explicit });
    try testing.expectEqual(T.Failure.invalid_utf8, invalid.failure.?);
    try testing.expect(!invalid.paste.?.rolled_back);
    try expectText(&area, "leftokRIGHT", 6);
    _ = insert(&area, "!");
    try expectText(&area, "leftok!RIGHT", 7);
    try testing.expectEqual(T.Failure.paste_not_started, area.apply(.{ .feedPaste = "late" }).failure.?);
}

test "CRLF normalization persists across fragments and focus loss finishes only local paste" {
    var storage: [80]u8 = undefined;
    var area = T.init(&storage);
    _ = area.setText("LR", 1);
    _ = area.apply(.beginPaste);
    _ = area.apply(.{ .feedPaste = "a\r" });
    _ = area.apply(.{ .feedPaste = "\nb\rc\n\t" });
    var ctx = context(testing.allocator);
    defer ctx.cmds.deinit(testing.allocator);
    try area.handleEvent(&ctx, .focus_out);
    try expectText(&area, "La\nb\nc\n\tR", "La\nb\nc\n\t".len);
    try testing.expectEqual(T.Failure.paste_not_started, area.apply(.{ .feedPaste = "late" }).failure.?);
    try area.handleEvent(&ctx, .paste_end);
    _ = insert(&area, "!");
    try testing.expectEqualStrings("La\nb\nc\n\t!R", area.text());
}

test "split regional indicator joiner and combining context remains contiguous across draws" {
    for ([_]struct { initial: []const u8, first: []const u8, second: []const u8, expected: []const u8, column: u16 }{
        .{ .initial = "L👩TAIL", .first = "👨‍", .second = "👧", .expected = "L👨‍👧👩TAIL", .column = 3 },
        .{ .initial = "L🇧TAIL", .first = "🇦", .second = "🇨", .expected = "L🇦🇨🇧TAIL", .column = 3 },
        .{ .initial = "Le\u{301}TAIL", .first = "a", .second = "\u{301}", .expected = "La\u{301}e\u{301}TAIL", .column = 2 },
    }) |case| {
        var storage: [80]u8 = undefined;
        var area = T.init(&storage);
        _ = area.setText(case.initial, 1);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const ctx = drawContext(arena.allocator(), 40, 8);
        _ = area.apply(.beginPaste);
        _ = area.apply(.{ .feedPaste = case.first });
        const joined = try area.draw(ctx);
        try testing.expectEqual(case.column, joined.cursor.?.col);
        _ = area.apply(.{ .feedPaste = case.second });
        const continued = try area.draw(ctx);
        try testing.expectEqualStrings(case.expected, area.text());
        try testing.expectEqual(case.column, continued.cursor.?.col);
        _ = area.apply(.{ .endPaste = .marker });
        const ended = try area.draw(ctx);
        try testing.expectEqualDeep(continued.cursor, ended.cursor);
        // Width one clips wide glyphs without relocating the logical caret.
        const cursor = area.byteOffsetToCursor();
        _ = try area.draw(drawContext(arena.allocator(), 1, 3));
        try testing.expectEqual(cursor, area.byteOffsetToCursor());
        _ = try area.draw(ctx);
        try testing.expectEqualStrings(case.expected, area.text());
    }
    var storage: [80]u8 = undefined;
    var area = T.init(&storage);
    _ = area.setText("🇦🇧🇨", "🇦🇧🇨".len);
    _ = area.apply(.left);
    try testing.expectEqual("🇦🇧".len, area.byteOffsetToCursor());
    _ = area.apply(.left);
    try testing.expectEqual(@as(usize, 0), area.byteOffsetToCursor());
    _ = area.apply(.right);
    try testing.expectEqual("🇦🇧".len, area.byteOffsetToCursor());
}

const Observer = struct {
    changes: usize = 0,
    edits: usize = 0,
    pastes: usize = 0,
    submits: usize = 0,
    origin: T.Origin = .programmatic,
    bytes: [80]u8 = undefined,
    len: usize = 0,
    last_paste: ?T.PasteEvent = null,

    fn change(raw: ?*anyopaque, _: *vxfw.EventContext, value: T.Change) !void {
        const self: *Observer = @ptrCast(@alignCast(raw.?));
        self.changes += 1;
        self.edits += value.edit_count;
        self.origin = value.origin;
        @memcpy(self.bytes[0..value.text.len], value.text);
        self.len = value.text.len;
    }
    fn paste(raw: ?*anyopaque, _: *vxfw.EventContext, value: T.PasteEvent) !void {
        const self: *Observer = @ptrCast(@alignCast(raw.?));
        self.pastes += 1;
        self.last_paste = value;
    }
    fn submit(raw: ?*anyopaque, _: *vxfw.EventContext, _: []const u8) !void {
        const self: *Observer = @ptrCast(@alignCast(raw.?));
        self.submits += 1;
    }
};

test "callbacks observe actual edits once no-ops stay quiet and direct operations never notify" {
    var storage: [8]u8 = undefined;
    var area = T.init(&storage);
    var observer: Observer = .{};
    area.userdata = &observer;
    area.onChange = Observer.change;
    area.onPaste = Observer.paste;
    area.onSubmit = Observer.submit;
    var ctx = context(testing.allocator);
    defer ctx.cmds.deinit(testing.allocator);
    _ = try area.dispatch(&ctx, .delete_previous);
    try testing.expect(ctx.consume_event and !ctx.redraw);
    try testing.expectEqual(@as(usize, 0), observer.changes);
    _ = insert(&area, "ab");
    _ = area.setText("ab", 0);
    try testing.expectEqual(@as(usize, 0), area.setText("ab", 0).edit_count);
    try testing.expectEqual(@as(usize, 0), observer.changes);
    _ = try area.dispatch(&ctx, .right);
    try testing.expect(ctx.redraw);
    try testing.expectEqual(@as(usize, 0), observer.changes);
    _ = try area.dispatch(&ctx, .{ .insert = .{ .bytes = "中", .origin = .typed } });
    try testing.expectEqual(@as(usize, 1), observer.changes);
    try testing.expectEqual(@as(usize, 1), observer.edits);
    try testing.expectEqual(T.Origin.typed, observer.origin);
    try testing.expectEqualStrings("a中b", observer.bytes[0..observer.len]);
    _ = try area.dispatch(&ctx, .{ .insert = .{ .bytes = "\xff" } });
    try testing.expectEqual(@as(usize, 1), observer.changes);
    _ = try area.dispatch(&ctx, .{ .insert = .{ .bytes = "12345" } });
    try testing.expectEqual(@as(usize, 2), observer.changes);
    try testing.expectEqual(@as(usize, 4), observer.edits);
    _ = try area.dispatch(&ctx, .submit);
    try testing.expectEqual(@as(usize, 1), observer.submits);
    _ = area.clear();
    _ = try area.dispatch(&ctx, .beginPaste);
    _ = try area.dispatch(&ctx, .{ .feedPaste = "123456789" });
    try testing.expectEqual(@as(usize, 3), observer.changes);
    try testing.expectEqual(@as(usize, 13), observer.edits);
    try testing.expectEqualStrings("", observer.bytes[0..observer.len]);
    _ = try area.dispatch(&ctx, .{ .endPaste = .marker });
    try testing.expectEqual(@as(usize, 2), observer.pastes);
    try testing.expect(observer.last_paste.?.rolled_back);
    try testing.expectEqual(T.Failure.capacity, observer.last_paste.?.failure.?);
    _ = try area.dispatch(&ctx, .beginPaste);
    _ = try area.dispatch(&ctx, .{ .endPaste = .explicit });
    try testing.expectEqual(@as(usize, 4), observer.pastes);
    try testing.expectEqual(@as(usize, 3), observer.changes);
}

test "defaults insert LF not submit and none isolates manual binding policy" {
    var storage: [128]u8 = undefined;
    var area = T.init(&storage);
    var observer: Observer = .{};
    area.userdata = &observer;
    area.onSubmit = Observer.submit;
    var ctx = context(testing.allocator);
    defer ctx.cmds.deinit(testing.allocator);
    for ([_]vaxis.Key{
        .{ .codepoint = vaxis.Key.enter },
        .{ .codepoint = vaxis.Key.enter, .mods = .{ .alt = true } },
        .{ .codepoint = vaxis.Key.enter, .mods = .{ .shift = true } },
        .{ .codepoint = 'j', .mods = .{ .ctrl = true } },
    }) |key| try area.handleEvent(&ctx, .{ .key_press = key });
    try expectText(&area, "\n\n\n\n", 4);
    try testing.expectEqual(@as(usize, 0), observer.submits);
    for ([_]vaxis.Key{
        .{ .codepoint = 'j', .text = "j", .mods = .{ .ctrl = true, .shift = true } },
        .{ .codepoint = vaxis.Key.enter, .text = "\r", .mods = .{ .alt = true, .shift = true } },
        .{ .codepoint = 'x', .text = "x", .mods = .{ .alt = true } },
        .{ .codepoint = 'c', .text = "c", .mods = .{ .ctrl = true } },
        .{ .codepoint = 'a', .text = "a", .mods = .{ .meta = true } },
        .{ .codepoint = vaxis.Key.left, .text = "x", .mods = .{ .shift = true } },
        .{ .codepoint = vaxis.Key.escape, .text = "\x1b" },
    }) |key| {
        ctx.consume_event = false;
        try area.handleEvent(&ctx, .{ .key_press = key });
        try testing.expect(!ctx.consume_event);
        try expectText(&area, "\n\n\n\n", 4);
    }
    area.bindings = .none;
    for ([_]vxfw.Event{ .paste_start, .paste_end, .{ .key_press = .{ .codepoint = 'x', .text = "x" } }, .{ .key_press = .{ .codepoint = vaxis.Key.enter } } }) |ev| {
        ctx.consume_event = false;
        try area.handleEvent(&ctx, ev);
        try testing.expect(!ctx.consume_event);
    }
    try testing.expectEqual(T.Failure.paste_not_started, area.apply(.{ .feedPaste = "x" }).failure.?);
    _ = try area.dispatch(&ctx, .submit);
    try testing.expectEqual(@as(usize, 1), observer.submits);
    try expectText(&area, "\n\n\n\n", 4);
    _ = area.apply(.buffer_start);
    ctx.consume_event = false;
    area.bindings = .default;
    try area.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    try testing.expect(!ctx.consume_event);
    _ = area.clear();
    try area.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'd', .mods = .{ .ctrl = true } } });
    try testing.expect(ctx.consume_event and !ctx.quit);
    // OSC52 data is still owned by its requester, not by this widget.
    ctx.consume_event = false;
    try area.handleEvent(&ctx, .{ .paste = "do not insert" });
    try testing.expect(!ctx.consume_event);
    try expectText(&area, "", 0);
}

test "acceptScalar is additional policy not a blanket format-character ban" {
    const Policy = struct {
        fn accept(_: ?*anyopaque, cp: u21) bool {
            return cp == 0x200d or vaxis.unicode.generalCategory(cp) != .other_format;
        }
    };
    var storage: [80]u8 = undefined;
    var area = T.init(&storage);
    try testing.expectEqual(@as(?T.Failure, null), insert(&area, "a\u{200e}").failure);
    _ = area.clear();
    area.acceptScalar = Policy.accept;
    try testing.expectEqual(T.Failure.invalid_scalar, insert(&area, "a\u{200e}").failure.?);
    try expectText(&area, "a", 1);
    _ = area.clear();
    try testing.expectEqual(@as(?T.Failure, null), insert(&area, "🧑‍🌾").failure);
    for ([_][]const u8{ "\x00", "\x1b", "\x7f", "\xc2\x85" }) |control| {
        try testing.expectEqual(T.Failure.invalid_scalar, insert(&area, control).failure.?);
    }
    try testing.expectEqual(@as(?T.Failure, null), insert(&area, "\t\n").failure);
}

test "draw clips every small size without moving the caret or changing bytes" {
    var storage: [80]u8 = undefined;
    var area = T.init(&storage);
    const bytes = "中e\u{301}\n👩‍💻end";
    for ([_]usize{ 0, "中".len, "中e\u{301}\n".len, bytes.len }) |cursor| {
        _ = area.setText(bytes, cursor);
        for (0..6) |width| for (0..6) |height| {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const surface = try area.draw(drawContext(arena.allocator(), @intCast(width), @intCast(height)));
            try testing.expect(surface.size.width <= width and surface.size.height <= height);
            if (width == 0 or height == 0) {
                try testing.expectEqual(@as(usize, 0), surface.buffer.len);
                try testing.expectEqual(null, surface.cursor);
            } else {
                try testing.expect(surface.cursor.?.col < width and surface.cursor.?.row < height);
            }
            try expectText(&area, bytes, cursor);
        };
    }
}

test "draw grows above ten rows respects minimum height and preserves byte anchors on resize" {
    var storage: [128]u8 = undefined;
    var area = T.init(&storage);
    _ = area.setText("0\n1\n2\n3\n4\n5\n6\n7\n8\n9\na\nb\nc\nd\ne\nf\ng\nh\ni\nj", 39);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tall = try area.draw(drawContext(arena.allocator(), 40, 15));
    try testing.expectEqual(@as(u16, 15), tall.size.height);
    try testing.expectEqual(@as(usize, 20), area.viewport().total);
    try testing.expectEqual(@as(usize, 5), area.viewport().first);
    try testing.expectEqual(@as(u16, 14), tall.cursor.?.row);
    _ = area.setText("one two three four five six", 8);
    _ = try area.draw(drawContext(arena.allocator(), 9, 2));
    _ = area.apply(.buffer_end);
    _ = try area.draw(drawContext(arena.allocator(), 9, 2));
    _ = area.setCursor(8);
    _ = try area.draw(drawContext(arena.allocator(), 5, 2));
    try testing.expectEqual(@as(usize, 2), area.viewport().first);
    _ = area.clear();
    var ctx = drawContext(arena.allocator(), 40, 8);
    ctx.min.height = 4;
    const padded = try area.draw(ctx);
    try testing.expectEqual(@as(u16, 4), padded.size.height);
    try testing.expectEqual(@as(usize, 1), area.viewport().visible);
    area.show_cursor = false;
    try testing.expectEqual(null, (try area.draw(ctx)).cursor);
}

test "cells use the cell allocator when present and no frame text is retained" {
    var storage: [80]u8 = undefined;
    var area = T.init(&storage);
    _ = area.setText("ab\t中", "ab\t中".len);
    var metadata: [8192]u8 = undefined;
    var cell_memory: [16384]u8 = undefined;
    var meta = std.heap.FixedBufferAllocator.init(&metadata);
    var cells = std.heap.FixedBufferAllocator.init(&cell_memory);
    var ctx = drawContext(meta.allocator(), 20, 4);
    if (@hasField(vxfw.DrawContext, "cell_arena")) ctx.cell_arena = cells.allocator();
    const surface = try area.draw(ctx);
    const expected_memory: []const u8 = if (@hasField(vxfw.DrawContext, "cell_arena")) &cell_memory else &metadata;
    const address = @intFromPtr(surface.buffer.ptr);
    try testing.expect(address >= @intFromPtr(expected_memory.ptr) and address < @intFromPtr(expected_memory.ptr) + expected_memory.len);
    try testing.expectEqualStrings(" ", surface.readCell(2, 0).char.grapheme);
    const glyph = surface.readCell(3, 0).char.grapheme;
    try testing.expectEqualStrings("中", glyph);
    try testing.expectEqual(@intFromPtr(area.text().ptr) + 3, @intFromPtr(glyph.ptr));
    const widget = surface.widget;
    const view = area.viewport();
    cells.reset();
    @memset(&cell_memory, 0xaa);
    // Focus/userdata metadata and borrowed storage outlive released cells.
    try testing.expectEqual(area.widget().userdata, widget.userdata);
    try testing.expectEqualDeep(view, area.viewport());
    meta.reset();
    @memset(&metadata, 0xbb);
    try expectText(&area, "ab\t中", "ab\t中".len);
    var event_ctx = context(testing.allocator);
    defer event_ctx.cmds.deinit(testing.allocator);
    try widget.handleEvent(&event_ctx, .{ .key_press = .{ .codepoint = 'x', .text = "x" } });
    try expectText(&area, "ab\t中x", "ab\t中x".len);
}

test "default edit keys retain independent hard-line and word meanings" {
    var storage: [128]u8 = undefined;
    var area = T.init(&storage);
    var ctx = context(testing.allocator);
    defer ctx.cmds.deinit(testing.allocator);
    const cases = [_]struct { key: vaxis.Key, initial: []const u8, cursor: usize, expected: []const u8, after: usize }{
        .{ .key = .{ .codepoint = 'b', .mods = .{ .ctrl = true } }, .initial = "ae\u{301}z", .cursor = 4, .expected = "ae\u{301}z", .after = 1 },
        .{ .key = .{ .codepoint = 'f', .mods = .{ .ctrl = true } }, .initial = "ae\u{301}z", .cursor = 1, .expected = "ae\u{301}z", .after = 4 },
        .{ .key = .{ .codepoint = 'a', .mods = .{ .ctrl = true } }, .initial = "one\ntwo", .cursor = 7, .expected = "one\ntwo", .after = 4 },
        .{ .key = .{ .codepoint = 'e', .mods = .{ .ctrl = true } }, .initial = "one\ntwo", .cursor = 0, .expected = "one\ntwo", .after = 3 },
        .{ .key = .{ .codepoint = 'u', .mods = .{ .ctrl = true } }, .initial = "one\ntwo", .cursor = 6, .expected = "one\no", .after = 4 },
        .{ .key = .{ .codepoint = 'k', .mods = .{ .ctrl = true } }, .initial = "one\ntwo", .cursor = 1, .expected = "o\ntwo", .after = 1 },
        .{ .key = .{ .codepoint = 'd', .mods = .{ .ctrl = true } }, .initial = "ab", .cursor = 0, .expected = "b", .after = 0 },
        .{ .key = .{ .codepoint = 'w', .mods = .{ .ctrl = true } }, .initial = "ask src/foo-bar", .cursor = 15, .expected = "ask ", .after = 4 },
        .{ .key = .{ .codepoint = vaxis.Key.backspace, .mods = .{ .alt = true } }, .initial = "ask src/foo-bar", .cursor = 15, .expected = "ask src/foo-", .after = 12 },
        .{ .key = .{ .codepoint = 'b', .mods = .{ .alt = true } }, .initial = "one two/三", .cursor = 11, .expected = "one two/三", .after = 8 },
        .{ .key = .{ .codepoint = 'f', .mods = .{ .alt = true } }, .initial = "one two/三", .cursor = 3, .expected = "one two/三", .after = 7 },
        .{ .key = .{ .codepoint = vaxis.Key.tab }, .initial = "ab", .cursor = 1, .expected = "a\tb", .after = 2 },
    };
    for (cases) |case| {
        try testing.expectEqual(@as(?T.Failure, null), area.setText(case.initial, case.cursor).failure);
        ctx.consume_event = false;
        try area.handleEvent(&ctx, .{ .key_press = case.key });
        try testing.expect(ctx.consume_event);
        try expectText(&area, case.expected, case.after);
    }
}

test "event paste is data not bindings and typed event scratch is copied" {
    var storage: [80]u8 = undefined;
    var area = T.init(&storage);
    var ctx = context(testing.allocator);
    defer ctx.cmds.deinit(testing.allocator);
    try area.handleEvent(&ctx, .paste_start);
    try area.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'a', .text = "line1" } });
    try area.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try area.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'j', .mods = .{ .ctrl = true } } });
    try area.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.tab } });
    try area.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'w', .text = "word", .mods = .{ .ctrl = true } } });
    try area.handleEvent(&ctx, .paste_end);
    try expectText(&area, "line1\n\tword", "line1\n\tword".len);
    var scratch = "xy".*;
    try area.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.multicodepoint, .text = &scratch } });
    @memset(&scratch, 'z');
    try testing.expectEqualStrings("line1\n\twordxy", area.text());
    // Complete malformed parser fragments are rejected, never staged into the
    // next ordinary key. Streaming fragments remain an explicit action API.
    try area.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 0xfffd, .text = "\xc3" } });
    try area.handleEvent(&ctx, .{ .key_press = .{ .codepoint = '!', .text = "!" } });
    try testing.expectEqualStrings("line1\n\twordxy!", area.text());
}

test "wide-cluster wrapping matches renderer width and leaves tabs unchanged" {
    var storage: [80]u8 = undefined;
    var area = T.init(&storage);
    _ = area.setText("abcd中", "abcd中".len);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const surface = try area.draw(drawContext(arena.allocator(), 5, 8));
    try testing.expectEqual(@as(usize, 2), area.viewport().total);
    try testing.expectEqual(@as(u16, 2), surface.cursor.?.col);
    try testing.expectEqualStrings("中", surface.readCell(0, 1).char.grapheme);
    _ = area.setText("a\tb", 3);
    area.style = .{ .bg = .{ .index = 19 } };
    const tabs = try area.draw(drawContext(arena.allocator(), 5, 8));
    try testing.expectEqualStrings(" ", tabs.readCell(1, 0).char.grapheme);
    try expectText(&area, "a\tb", 3);
    for (tabs.buffer) |cell| try testing.expectEqual(vaxis.Color{ .index = 19 }, cell.style.bg);
}

test "default deletion notifications retain typed origin" {
    var storage: [16]u8 = undefined;
    var area = T.init(&storage);
    var observer: Observer = .{};
    area.userdata = &observer;
    area.onChange = Observer.change;
    _ = area.setText("ab", 2);
    var ctx = context(testing.allocator);
    defer ctx.cmds.deinit(testing.allocator);
    try area.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.backspace } });
    try testing.expectEqual(T.Origin.typed, observer.origin);
    try testing.expectEqual(@as(usize, 1), observer.edits);
    _ = try area.dispatch(&ctx, .delete_previous);
    try testing.expectEqual(T.Origin.programmatic, observer.origin);
}

/// The caret a repair from byte 0 gives: the end of the grapheme that holds
/// the byte before `at`.
fn fullScanCaret(bytes: []const u8, at: usize) usize {
    if (at == 0) return 0;
    var it = vaxis.unicode.graphemeIterator(bytes);
    while (it.next()) |g| if (g.start + g.len >= at) return g.start + g.len;
    return bytes.len;
}

test "insertion repairs the caret as a scan from byte 0 would, typed or pasted, at every boundary" {
    const texts = [_][]const u8{ "ab", "🇫🇷🇩🇪", "🧑\u{200d}🌾x", "e\u{301}\u{302}y", "\u{1100}\u{1161}\u{11a8}", "a\nb\tc", "🇫🇷x🇩🇪" };
    const scalars = [_][]const u8{ "z", "\u{301}", "\u{200d}", "🇫", "🇷", "🌾", "\u{fe0f}", "\u{1161}", "\u{11a8}", "\n" };
    var storage: [64]u8 = undefined;
    for (texts) |initial| {
        var at: usize = 0;
        while (at <= initial.len) : (at += 1) {
            if (at != initial.len and fullScanCaret(initial, at) != at) continue;
            for (scalars) |scalar| for ([_]bool{ false, true }) |pasted| {
                errdefer std.debug.print("text={s} at={d} scalar={any} pasted={}\n", .{ initial, at, scalar, pasted });
                var area = T.init(&storage);
                try testing.expectEqual(@as(?T.Failure, null), area.setText(initial, at).failure);
                // The second scalar repairs from the boundary the first settled.
                if (pasted) {
                    _ = area.apply(.beginPaste);
                    _ = area.apply(.{ .feedPaste = scalar });
                    _ = area.apply(.{ .feedPaste = scalar });
                    if (area.apply(.{ .endPaste = .explicit }).failure != null) continue;
                    try testing.expectEqual(fullScanCaret(area.text(), at + 2 * scalar.len), area.byteOffsetToCursor());
                } else for (0..2) |_| {
                    const before = area.byteOffsetToCursor();
                    if (insert(&area, scalar).failure != null) break;
                    try testing.expectEqual(fullScanCaret(area.text(), before + scalar.len), area.byteOffsetToCursor());
                }
            };
        }
    }
}

test "a paste segments only near its insertion point, at the end or in the middle" {
    const storage = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(storage);
    for ([_][]const u8{ "", "tail🇫🇷" }) |suffix| for ([_][]const u8{ "x", "e\u{301}", "🇫🇷", "🧑\u{200d}🌾" }) |unit| {
        var area = T.init(storage);
        _ = area.setText(suffix, 0);
        _ = area.apply(.beginPaste);
        var pasted: usize = 0;
        while (pasted + unit.len + suffix.len <= storage.len) : (pasted += unit.len) {
            _ = area.apply(.{ .feedPaste = unit });
            // A repair walks from `settled` to the caret: that span is one
            // grapheme or two, never the text before them.
            if (suffix.len != 0) try testing.expect(area.byteOffsetToCursor() - area.settled <= 2 * unit.len);
        }
        try testing.expectEqual(@as(?T.Failure, null), area.apply(.{ .endPaste = .explicit }).failure);
        try testing.expectEqual(pasted + suffix.len, area.text().len);
        try testing.expectEqual(pasted, area.byteOffsetToCursor());
    };
}

fn noFormat(_: ?*anyopaque, cp: u21) bool {
    return cp != 0x200b;
}

test "a streaming text check gives setText's verdict at every split" {
    const inputs = [_][]const u8{ "plain", "\u{301}x", "e\u{301}", "a\nb\tc", "\x01", "x\x7f", "\xff", "\xc3", "ok\u{200b}", "🧑\u{200d}🌾", "\n\u{301}", "\u{200d}", "a\u{fe0f}", "é\xe2\x82" };
    var storage: [32]u8 = undefined;
    for (inputs) |input| for ([_]bool{ false, true }) |policy| {
        var area = T.init(&storage);
        if (policy) area.acceptScalar = noFormat;
        const verdict = area.setText(input, 0).failure;
        for (0..input.len + 1) |split| {
            errdefer std.debug.print("input={any} split={d} policy={}\n", .{ input, split, policy });
            var check = area.textCheck();
            check.feed(input[0..split]);
            check.feed(input[split..]);
            // setText rejects malformed UTF-8 before any scalar policy.
            const streamed = check.finish();
            if (verdict == .invalid_utf8) try testing.expect(streamed != null) else try testing.expectEqual(verdict, streamed);
        }
    };
}

test "an explicit width method measures wrapping, the caret and cells whatever the frame's" {
    const draft = "a👩‍💻b";
    var storage: [32]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The frame's method is process-wide; leave it at its default after.
    defer vxfw.DrawContext.init(.unicode);
    for ([_]vaxis.gwidth.Method{ .unicode, .wcwidth, .no_zwj }) |method| for ([_]vaxis.gwidth.Method{ .unicode, .wcwidth, .no_zwj }) |global| {
        errdefer std.debug.print("method={s} frame={s}\n", .{ @tagName(method), @tagName(global) });
        vxfw.DrawContext.init(global);
        var area = T.init(&storage);
        area.width_method = method;
        _ = area.setText(draft, draft.len);
        const emoji: u16 = @intCast(vaxis.gwidth.gwidth("👩‍💻", method));
        // Wide enough for all of it: the caret follows the method's widths.
        const wide = try area.draw(drawContext(arena.allocator(), 20, 4));
        try testing.expectEqual(@as(usize, 1), area.viewport().total);
        try testing.expectEqual(1 + emoji + 1, wide.cursor.?.col);
        try testing.expectEqual(@as(u16, emoji), wide.readCell(1, 0).char.width);
        try testing.expectEqualStrings("b", wide.readCell(1 + emoji, 0).char.grapheme);
        // One column short of all of it: "b" wraps to the next row.
        const narrow = try area.draw(drawContext(arena.allocator(), 1 + emoji, 4));
        try testing.expectEqual(@as(usize, 2), area.viewport().total);
        try testing.expectEqualStrings("b", narrow.readCell(0, 1).char.grapheme);
        try testing.expectEqual(@as(u16, 1), narrow.cursor.?.col);
    };
}
