//! A fixed-capacity, multi-line UTF-8 editor. Storage is borrowed for the widget's
//! lifetime; no deinit is needed. Construct in its final location before widget().
//! Text and cells borrow that storage: do not edit between draw and render.
//! Actions own editing mechanics, not history, completion, submission policy or
//! cross-focus paste routing. Default Enter inserts LF; submit is explicit.
//! Defaults use exact modifiers: arrows, Home/End, Backspace/Delete, Ctrl-A/E/
//! B/F/K/U/W/D, Alt-B/F/Backspace, Tab, Enter, Alt/Shift-Enter and Ctrl-J.
//! Up/Down count graphemes on hard lines, not cells or wrapped screen rows.
const std = @import("std");
const vaxis = @import("../main.zig");
const vxfw = @import("vxfw.zig");
const unicode = vaxis.unicode;
const layout = @import("TextArea/layout.zig");
const TextArea = @This();

buffer: []u8,
length: usize = 0,
cursor: usize = 0,
partial: [4]u8 = undefined,
partial_length: u3 = 0,
partial_need: u3 = 0,
paste_state: ?PasteState = null,
anchor: usize = 0,
view: View = .{},

style: vaxis.Style = .{},
bindings: Bindings = .default,
show_cursor: bool = true,
userdata: ?*anyopaque = null,
/// Additional scalar policy, after intrinsic UTF-8/control validation. Must be
/// pure; returning false reports invalid_scalar. Format characters are not
/// categorically forbidden by this widget.
acceptScalar: ?*const fn (?*anyopaque, u21) bool = null,
/// Notifications borrow text for the call only. Callbacks may schedule work but
/// must not mutate or destroy this widget reentrantly.
onChange: ?*const fn (?*anyopaque, *vxfw.EventContext, Change) anyerror!void = null,
onPaste: ?*const fn (?*anyopaque, *vxfw.EventContext, PasteEvent) anyerror!void = null,
onSubmit: ?*const fn (?*anyopaque, *vxfw.EventContext, []const u8) anyerror!void = null,

pub const Bindings = enum { default, none };

pub const Origin = enum { typed, programmatic, paste };
pub const Failure = enum {
    capacity,
    invalid_utf8,
    invalid_scalar,
    unrenderable,
    invalid_range,
    paste_not_started,
    paste_active,
};
pub const EndReason = enum { marker, focus_loss, explicit };
pub const PasteEvent = struct {
    phase: enum { begin, end },
    reason: EndReason = .explicit,
    failure: ?Failure = null,
    rolled_back: bool = false,
};
/// A handled no-op still consumes its key. handled=false means no neighboring
/// hard line is available, so a parent may interpret Up/Down. Counts include
/// committed scalar insertions, erases and a paste rollback erase.
pub const Result = struct {
    handled: bool = true,
    cursor_changed: bool = false,
    edit_count: usize = 0,
    failure: ?Failure = null,
    paste: ?PasteEvent = null,
    origin: Origin = .programmatic,
};
pub const Change = struct { text: []const u8, edit_count: usize, origin: Origin };
pub const Range = struct { start: usize, end: usize };
pub const View = struct {
    first: usize = 0,
    total: usize = 0,
    visible: usize = 0,
    hidden_above: usize = 0,
    hidden_below: usize = 0,
};
pub const Action = union(enum) {
    /// Streaming bytes may end in a partial scalar. Source must not alias the
    /// editor storage: the borrowed text view ends at the first mutation.
    insert: struct { bytes: []const u8, origin: Origin = .programmatic },
    newline,
    tab,
    left,
    right,
    up,
    down,
    line_start,
    line_end,
    buffer_start,
    buffer_end,
    word_left,
    word_right,
    delete_previous,
    delete_next,
    delete_to_line_start,
    delete_to_line_end,
    /// Delete the preceding whitespace-delimited word.
    delete_word,
    /// Delete the preceding letter/number/underscore word-part.
    delete_word_part,
    beginPaste,
    /// Insertion-only streaming data, disjoint from editor storage. CR/CRLF
    /// normalize to LF. Capacity/unrenderable failures roll back the transaction;
    /// invalid input retains the accepted prefix. The first fault is also
    /// reported at endPaste, which discards an incomplete trailing scalar.
    feedPaste: []const u8,
    endPaste: EndReason,
    submit,
};
const PasteState = struct {
    cursor: usize,
    length: usize,
    after_cr: bool = false,
    failure: ?Failure = null,
    rolled_back: bool = false,
};

pub fn init(buffer: []u8) TextArea {
    return .{ .buffer = buffer };
}

pub fn widget(self: *TextArea) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = eventAdapter, .drawFn = drawAdapter };
}

/// Borrowed until the next edit or reuse of the caller's storage.
pub fn text(self: *const TextArea) []const u8 {
    return self.buffer[0..self.length];
}

/// The caret's byte offset, always on an extended-grapheme boundary.
pub fn byteOffsetToCursor(self: *const TextArea) usize {
    return self.cursor;
}

/// Numeric metadata from the last draw; no frame-owned data is retained.
pub fn viewport(self: *const TextArea) View {
    return self.view;
}

fn boundary(bytes: []const u8, at: usize) bool {
    if (at == 0 or at == bytes.len) return true;
    if (at > bytes.len) return false;
    var it = unicode.graphemeIterator(bytes);
    while (it.next()) |g| if (g.start == at) return true;
    return false;
}

pub fn setCursor(self: *TextArea, at: usize) Result {
    if (self.paste_state != null) return .{ .failure = .paste_active };
    if (!boundary(self.text(), at)) return .{ .failure = .invalid_range };
    const changed = self.cursor != at;
    self.cursor = at;
    self.partial_length = 0;
    return .{ .cursor_changed = changed };
}

fn validScalar(self: *const TextArea, cp: u21) bool {
    if ((cp < 0x20 and cp != '\n' and cp != '\t') or (cp >= 0x7f and cp < 0xa0)) return false;
    return if (self.acceptScalar) |accept| accept(self.userdata, cp) else true;
}

// Preserve the scalar-width gate: a zero-width scalar must join its preceding
// scalar. Segmentation for movement/repair, in contrast, always scans full text.
fn renderable(prefix: []const u8, scalar: []const u8, cp: u21) bool {
    if (cp == '\n' or cp == '\t' or vaxis.gwidth.gwidth(scalar, .wcwidth) != 0) return true;
    if (prefix.len == 0) return false;
    var start = prefix.len - 1;
    while (start > 0 and prefix[start] & 0xc0 == 0x80) start -= 1;
    var pair: [8]u8 = undefined;
    const tail = prefix[start..];
    @memcpy(pair[0..tail.len], tail);
    @memcpy(pair[tail.len..][0..scalar.len], scalar);
    var it = unicode.graphemeIterator(pair[0 .. tail.len + scalar.len]);
    return it.next().?.len == tail.len + scalar.len;
}

fn validate(self: *const TextArea, bytes: []const u8) ?Failure {
    if (!std.unicode.utf8ValidateSlice(bytes)) return .invalid_utf8;
    var at: usize = 0;
    while (at < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[at]) catch unreachable;
        const cp = std.unicode.utf8Decode(bytes[at..][0..n]) catch unreachable;
        if (!self.validScalar(cp)) return .invalid_scalar;
        if (!renderable(bytes[0..at], bytes[at..][0..n], cp)) return .unrenderable;
        at += n;
    }
    return null;
}

/// Atomic restore. Validates size, complete UTF-8 and grapheme-aligned caret
/// before touching storage. Overlap with this buffer is supported.
pub fn setText(self: *TextArea, bytes: []const u8, at: usize) Result {
    if (self.paste_state != null) return .{ .failure = .paste_active };
    if (bytes.len > self.buffer.len) return .{ .failure = .capacity };
    if (self.validate(bytes)) |failure| return .{ .failure = failure };
    if (!boundary(bytes, at)) return .{ .failure = .invalid_range };
    const changed = !std.mem.eql(u8, self.text(), bytes);
    const cursor_changed = self.cursor != at;
    var count: usize = if (changed and self.length != 0) 1 else 0;
    if (changed) {
        for (bytes) |b| if (b & 0xc0 != 0x80) {
            count += 1;
        };
        if (@intFromPtr(bytes.ptr) > @intFromPtr(self.buffer.ptr))
            std.mem.copyForwards(u8, self.buffer[0..bytes.len], bytes)
        else
            std.mem.copyBackwards(u8, self.buffer[0..bytes.len], bytes);
    }
    self.length = bytes.len;
    self.cursor = at;
    self.partial_length = 0;
    return .{ .edit_count = count, .cursor_changed = cursor_changed };
}

pub fn clear(self: *TextArea) Result {
    return self.setText("", 0);
}

/// Checked, byte-indexed replacement. Input must not overlap the backing buffer.
/// Final size is preflighted; accepted-size input then uses streaming insertion
/// semantics (a malformed scalar can leave an already accepted prefix).
pub fn replace(self: *TextArea, range: Range, bytes: []const u8) Result {
    if (self.paste_state != null) return .{ .failure = .paste_active };
    if (range.start > range.end or !boundary(self.text(), range.start) or !boundary(self.text(), range.end)) return .{ .failure = .invalid_range };
    if (bytes.len != 0 and @intFromPtr(bytes.ptr) < @intFromPtr(self.buffer.ptr) + self.buffer.len and @intFromPtr(bytes.ptr) + bytes.len > @intFromPtr(self.buffer.ptr)) return .{ .failure = .invalid_range };
    if (bytes.len > self.buffer.len - (self.length - (range.end - range.start))) return .{ .failure = .capacity };
    const old = self.cursor;
    var result: Result = .{};
    self.partial_length = 0;
    self.erase(range.start, range.end, &result);
    // Insert at the requested range start, not the repaired caret after erase.
    self.cursor = range.start;
    self.feed(bytes, &result);
    self.repair();
    result.cursor_changed = old != self.cursor;
    return result;
}

/// Apply semantic actions without event context or callbacks. Failed edits do
/// not latch: a later action is independent. Paste is insertion-only until end.
pub fn apply(self: *TextArea, action: Action) Result {
    const old = self.cursor;
    var result: Result = .{};
    if (self.paste_state != null and action != .feedPaste and action != .endPaste) return .{ .failure = .paste_active };
    switch (action) {
        .insert => |input| {
            result.origin = input.origin;
            self.feed(input.bytes, &result);
        },
        .newline => self.feed("\n", &result),
        .tab => self.feed("\t", &result),
        .left => self.cursor = self.previous(self.cursor),
        .right => self.cursor = self.next(self.cursor),
        .up => result.handled = self.vertical(false),
        .down => result.handled = self.vertical(true),
        .line_start => self.cursor = self.lineStart(),
        .line_end => self.cursor = self.lineEnd(),
        .buffer_start => self.cursor = 0,
        .buffer_end => self.cursor = self.length,
        .word_left => self.moveWord(false),
        .word_right => self.moveWord(true),
        .delete_previous => self.erase(self.previous(self.cursor), self.cursor, &result),
        .delete_next => self.erase(self.cursor, self.next(self.cursor), &result),
        .delete_to_line_start => self.erase(self.lineStart(), self.cursor, &result),
        .delete_to_line_end => self.erase(self.cursor, self.lineEnd(), &result),
        .delete_word => self.backwardWord(true, &result),
        .delete_word_part => self.backwardWord(false, &result),
        .beginPaste => {
            self.partial_length = 0;
            self.paste_state = .{ .cursor = self.cursor, .length = self.length };
            result.origin = .paste;
            result.paste = .{ .phase = .begin };
        },
        .feedPaste => |bytes| {
            result.origin = .paste;
            if (self.paste_state == null) return .{ .failure = .paste_not_started, .origin = .paste };
            for (bytes) |byte| {
                if (self.paste_state.?.failure != null) break;
                const after_cr = self.paste_state.?.after_cr;
                self.paste_state.?.after_cr = byte == '\r';
                if (byte == '\n' and after_cr) continue;
                self.insertByte(if (byte == '\r') '\n' else byte, &result);
            }
        },
        .endPaste => |reason| {
            result.origin = .paste;
            const state = self.paste_state orelse return .{ .failure = .paste_not_started, .origin = .paste };
            self.partial_length = 0;
            self.partial_need = 0;
            self.paste_state = null;
            self.repair();
            result.failure = state.failure;
            result.paste = .{ .phase = .end, .reason = reason, .failure = state.failure, .rolled_back = state.rolled_back };
        },
        .submit => {},
    }
    // Movement cancels an incomplete typed scalar; feeds retain it.
    if (action != .insert and action != .feedPaste) self.partial_length = 0;
    result.cursor_changed = old != self.cursor;
    return result;
}

fn feed(self: *TextArea, bytes: []const u8, result: *Result) void {
    for (bytes) |byte| {
        self.insertByte(byte, result);
        if (result.failure != null) break;
    }
}

fn fail(self: *TextArea, failure: Failure, result: *Result) void {
    self.partial_length = 0;
    self.partial_need = 0;
    result.failure = failure;
    if (self.paste_state) |*state| {
        state.failure = failure;
        if (failure == .capacity or failure == .unrenderable) {
            const added = self.length - state.length;
            std.mem.copyForwards(u8, self.buffer[state.cursor..][0 .. self.length - state.cursor - added], self.buffer[state.cursor + added .. self.length]);
            self.length = state.length;
            self.cursor = state.cursor;
            if (added != 0) result.edit_count += 1;
            state.rolled_back = true;
        }
    }
}

fn insertByte(self: *TextArea, byte: u8, result: *Result) void {
    const insertion = if (self.paste_state) |state| state.cursor + self.length - state.length else self.cursor;
    if (self.partial_length == 0) self.partial_need = std.unicode.utf8ByteSequenceLength(byte) catch {
        self.fail(.invalid_utf8, result);
        return;
    };
    if (self.length + self.partial_length + 1 > self.buffer.len) {
        self.fail(.capacity, result);
        return;
    }
    self.partial[self.partial_length] = byte;
    self.partial_length += 1;
    if (self.partial_length != self.partial_need) return;
    const scalar = self.partial[0..self.partial_length];
    const cp = std.unicode.utf8Decode(scalar) catch {
        self.fail(.invalid_utf8, result);
        return;
    };
    if (!self.validScalar(cp)) {
        self.fail(.invalid_scalar, result);
        return;
    }
    if (!renderable(self.buffer[0..insertion], scalar, cp)) {
        self.fail(.unrenderable, result);
        return;
    }
    std.mem.copyBackwards(u8, self.buffer[insertion + scalar.len .. self.length + scalar.len], self.buffer[insertion..self.length]);
    @memcpy(self.buffer[insertion..][0..scalar.len], scalar);
    self.length += scalar.len;
    self.cursor = insertion + scalar.len;
    self.partial_length = 0;
    result.edit_count += 1;
    self.repair();
}

fn previous(self: *const TextArea, position: usize) usize {
    var it = unicode.graphemeIterator(self.text());
    var prior: usize = 0;
    while (it.next()) |g| {
        if (g.start >= position) break;
        prior = g.start;
    }
    return prior;
}

fn next(self: *const TextArea, position: usize) usize {
    var it = unicode.graphemeIterator(self.text());
    while (it.next()) |g| if (g.start + g.len > position) return g.start + g.len;
    return self.length;
}

fn repair(self: *TextArea) void {
    if (self.cursor != 0) self.cursor = self.next(self.cursor - 1);
}

fn erase(self: *TextArea, from: usize, to: usize, result: *Result) void {
    if (from == to) return;
    std.mem.copyForwards(u8, self.buffer[from .. self.length - (to - from)], self.buffer[to..self.length]);
    self.length -= to - from;
    self.cursor = from;
    self.repair();
    result.edit_count += 1;
}

fn lineStart(self: *const TextArea) usize {
    return if (std.mem.lastIndexOfScalar(u8, self.buffer[0..self.cursor], '\n')) |i| i + 1 else 0;
}

fn lineEnd(self: *const TextArea) usize {
    return std.mem.indexOfScalarPos(u8, self.text(), self.cursor, '\n') orelse self.length;
}

fn vertical(self: *TextArea, down: bool) bool {
    const start = self.lineStart();
    const destination = if (down)
        if (self.lineEnd() < self.length) self.lineEnd() + 1 else return false
    else if (start > 0)
        if (std.mem.lastIndexOfScalar(u8, self.buffer[0 .. start - 1], '\n')) |i| i + 1 else 0
    else
        return false;
    const limit = std.mem.indexOfScalarPos(u8, self.text(), destination, '\n') orelse self.length;
    var column: usize = 0;
    var at = start;
    while (at < self.cursor) : (column += 1) at = self.next(at);
    at = destination;
    while (column > 0 and at < limit) : (column -= 1) at = @min(self.next(at), limit);
    self.cursor = at;
    return true;
}

fn codepointAt(self: *const TextArea, start: usize) u21 {
    const n = std.unicode.utf8ByteSequenceLength(self.buffer[start]) catch unreachable;
    return std.unicode.utf8Decode(self.buffer[start..][0..n]) catch unreachable;
}

fn space(self: *const TextArea, start: usize) bool {
    return std.mem.indexOfScalar(u8, " \t\n", self.buffer[start]) != null or unicode.generalCategory(self.codepointAt(start)) == .separator_space;
}

fn word(self: *const TextArea, start: usize) bool {
    const cp = self.codepointAt(start);
    return cp == '_' or switch (unicode.generalCategory(cp)) {
        .letter_uppercase, .letter_lowercase, .letter_titlecase, .letter_modifier, .letter_other, .number_decimal_digit, .number_letter, .number_other => true,
        else => false,
    };
}

fn backwardWord(self: *TextArea, whitespace: bool, result: *Result) void {
    var it = unicode.graphemeIterator(self.text());
    var nonspace_start: usize = 0;
    var word_start: usize = 0;
    var in_nonspace = false;
    var in_word = false;
    while (it.next()) |g| {
        if (g.start >= self.cursor) break;
        const is_space = self.space(g.start);
        const is_word = self.word(g.start);
        if (!is_space and !in_nonspace) nonspace_start = g.start;
        if (is_word and !in_word) word_start = g.start;
        in_nonspace = !is_space;
        in_word = is_word;
    }
    self.erase(if (whitespace) nonspace_start else word_start, self.cursor, result);
}

fn moveWord(self: *TextArea, forward: bool) void {
    var it = unicode.graphemeIterator(self.text());
    var in_word = false;
    var word_start: usize = 0;
    var found_forward = false;
    while (it.next()) |g| {
        const is_word = self.word(g.start);
        if (!forward and g.start < self.cursor) {
            if (is_word and !in_word) word_start = g.start;
            in_word = is_word;
        } else if (forward and g.start >= self.cursor) {
            if (found_forward and !is_word) {
                self.cursor = g.start;
                return;
            }
            found_forward = found_forward or is_word;
        }
    }
    self.cursor = if (forward) self.length else word_start;
}

/// Event-aware action path. Callback data is captured after all mutations;
/// no mutation follows notification. Direct apply() never invokes callbacks.
pub fn dispatch(self: *TextArea, ctx: *vxfw.EventContext, action: Action) anyerror!Result {
    return self.dispatchOrigin(ctx, action, null);
}

fn dispatchOrigin(self: *TextArea, ctx: *vxfw.EventContext, action: Action, origin: ?Origin) anyerror!Result {
    var result = self.apply(action);
    if (origin) |value| result.origin = value;
    if (result.handled) ctx.consume_event = true;
    if (result.edit_count != 0 or result.cursor_changed) ctx.redraw = true;
    const change: Change = .{ .text = self.text(), .edit_count = result.edit_count, .origin = result.origin };
    if (result.edit_count != 0) if (self.onChange) |callback| try callback(self.userdata, ctx, change);
    if (result.paste) |paste| if (self.onPaste) |callback| try callback(self.userdata, ctx, paste);
    if (action == .submit and result.failure == null) if (self.onSubmit) |callback| try callback(self.userdata, ctx, change.text);
    return result;
}

fn defaultAction(key: vaxis.Key) ?Action {
    const K = vaxis.Key;
    if (key.matchExact(K.left, .{}) or key.matchExact('b', .{ .ctrl = true })) return .left;
    if (key.matchExact(K.right, .{}) or key.matchExact('f', .{ .ctrl = true })) return .right;
    if (key.matchExact(K.up, .{})) return .up;
    if (key.matchExact(K.down, .{})) return .down;
    if (key.matchExact(K.home, .{}) or key.matchExact('a', .{ .ctrl = true })) return .line_start;
    if (key.matchExact(K.end, .{}) or key.matchExact('e', .{ .ctrl = true })) return .line_end;
    if (key.matchExact(K.backspace, .{})) return .delete_previous;
    if (key.matchExact(K.delete, .{}) or key.matchExact('d', .{ .ctrl = true })) return .delete_next;
    if (key.matchExact('k', .{ .ctrl = true })) return .delete_to_line_end;
    if (key.matchExact('u', .{ .ctrl = true })) return .delete_to_line_start;
    if (key.matchExact('w', .{ .ctrl = true })) return .delete_word;
    if (key.matchExact('b', .{ .alt = true }) or key.matchExact(K.left, .{ .alt = true })) return .word_left;
    if (key.matchExact('f', .{ .alt = true }) or key.matchExact(K.right, .{ .alt = true })) return .word_right;
    if (key.matchExact(K.backspace, .{ .alt = true }) or key.matchExact(127, .{ .alt = true })) return .delete_word_part;
    if (key.matchExact(K.tab, .{})) return .tab;
    if (key.matchExact(K.enter, .{}) or key.matchExact(K.enter, .{ .alt = true }) or key.matchExact(K.enter, .{ .shift = true }) or key.matchExact('j', .{ .ctrl = true })) return .newline;
    if (key.mods.ctrl or key.mods.alt or key.mods.super or key.mods.hyper or key.mods.meta) return null;
    if (key.codepoint < 0x20 or (key.codepoint >= 0x7f and key.codepoint < 0xa0)) return null;
    if (key.codepoint >= K.insert and key.codepoint <= K.iso_level_5_shift) return null;
    if (key.text) |bytes| return .{ .insert = .{ .bytes = bytes, .origin = .typed } };
    return null;
}

/// Defaults require stable-recipient paste routing until the end marker. OSC52
/// paste is deliberately unhandled: its permission and allocation belong to the
/// requester. With bindings=none, call semantic actions from your own adapter.
pub fn handleEvent(self: *TextArea, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    // Finish an existing transaction on blur even if defaults were disabled.
    if (event == .focus_out and self.paste_state != null) {
        _ = try self.dispatch(ctx, .{ .endPaste = .focus_loss });
        return;
    }
    if (self.bindings == .none) return;
    switch (event) {
        .paste_start => {
            _ = try self.dispatch(ctx, .beginPaste);
        },
        .paste_end => if (self.paste_state != null) {
            _ = try self.dispatch(ctx, .{ .endPaste = .marker });
        },
        .key_press => |key| {
            if (self.paste_state != null) {
                const bytes = key.text orelse if (key.matchExact(vaxis.Key.enter, .{})) "\r" else if (key.matchExact('j', .{ .ctrl = true })) "\n" else if (key.matchExact(vaxis.Key.tab, .{})) "\t" else "\x00";
                _ = try self.dispatch(ctx, .{ .feedPaste = bytes });
            } else if (defaultAction(key)) |action| {
                // Parser text is a complete event, unlike the streaming API.
                if (action == .insert and !std.unicode.utf8ValidateSlice(action.insert.bytes)) {
                    self.partial_length = 0;
                    ctx.consume_event = true;
                    return;
                }
                if (action == .newline or action == .tab) {
                    _ = try self.dispatch(ctx, .{ .insert = .{ .bytes = if (action == .newline) "\n" else "\t", .origin = .typed } });
                } else _ = try self.dispatchOrigin(ctx, action, .typed);
            }
        },
        else => {},
    }
}

fn eventAdapter(raw: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *TextArea = @ptrCast(@alignCast(raw));
    return self.handleEvent(ctx, event);
}

fn drawAdapter(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *TextArea = @ptrCast(@alignCast(raw));
    return self.draw(ctx);
}

const Pieces = struct {
    bytes: []const u8,
    ctx: vxfw.DrawContext,
    iterator: ?unicode.GraphemeIterator = null,

    pub fn next(self: *Pieces) ?layout.Piece {
        if (self.iterator == null) self.iterator = unicode.graphemeIterator(self.bytes);
        const g = self.iterator.?.next() orelse return null;
        const bytes = g.bytes(self.bytes);
        const tab = std.mem.eql(u8, bytes, "\t");
        const kind = if (tab) .space else layout.kindOf(bytes);
        return .{ .len = g.len, .cells = if (kind == .newline) 0 else if (tab) 1 else @intCast(@min(self.ctx.stringWidth(bytes), std.math.maxInt(u16))), .kind = kind };
    }
};

/// Draw within finite width and height constraints. Only visible-row scratch
/// and cells are allocated; glyphs borrow the editor buffer (tabs use static
/// spaces). The widget retains no text copies, cells or per-line index.
pub fn draw(self: *TextArea, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    std.debug.assert(ctx.max.width != null and ctx.max.height != null);
    const width = ctx.max.width.?;
    const height = ctx.max.height.?;
    const cells = if (@hasField(vxfw.DrawContext, "cell_arena")) ctx.cell_arena else ctx.arena;
    if (width == 0 or height == 0) {
        self.view = .{};
        return vxfw.Surface.init(cells, self.widget(), .{});
    }
    const pieces: Pieces = .{ .bytes = self.text(), .ctx = ctx };
    const shape = layout.shape(pieces, width, self.cursor, self.anchor);
    const lines = try ctx.arena.alloc(layout.Line, @min(shape.lines, height));
    const shown = layout.fit(pieces, width, self.cursor, shape, height, lines);
    self.anchor = lines[0].start;
    self.view = .{ .first = shown.first, .total = shape.lines, .visible = shown.rows, .hidden_above = shown.hidden_above, .hidden_below = shown.hidden_below };
    var surface = try vxfw.Surface.init(cells, self.widget(), .{
        .width = width,
        .height = @min(height, @max(ctx.min.height, shown.rows)),
    });
    @memset(surface.buffer, .{ .style = self.style });
    for (lines[0..shown.rows], 0..) |line, row| {
        var it = unicode.graphemeIterator(self.buffer[line.start..line.end]);
        var col: usize = 0;
        while (it.next()) |g| {
            const bytes = g.bytes(self.buffer[line.start..line.end]);
            const tab = std.mem.eql(u8, bytes, "\t");
            const w = if (tab) 1 else ctx.stringWidth(bytes);
            if (col + w > width) break;
            if (w != 0) surface.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = if (tab) " " else bytes, .width = @intCast(w) },
                .style = self.style,
            });
            col += w;
        }
    }
    if (self.show_cursor) surface.cursor = .{ .row = @intCast(shape.caret_line - shown.first), .col = shape.caret_column };
    return surface;
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
    _ = @import("TextArea/tests.zig");
}

test TextArea {
    var storage: [256]u8 = undefined;
    var area = TextArea.init(&storage);
    _ = area.apply(.{ .insert = .{ .bytes = "Hello" } });
    _ = area.apply(.newline);
    _ = area.apply(.{ .insert = .{ .bytes = "world" } });
    try std.testing.expectEqualStrings("Hello\nworld", area.text());
}
