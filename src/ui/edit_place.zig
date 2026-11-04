//! Editar um servidor (nome, descrição, ícone e banner) ou um grupo de DM
//! (nome e ícone). Só o que mudou vai para o Discord.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const types = @import("../core/types.zig");
const image_uri = @import("../core/image_uri.zig");
const popup = @import("popup.zig");
const forum = @import("forum.zig");
const inbox = @import("inbox.zig");
const w_ui = @import("widgets.zig");
const ev = @import("../core/event.zig");
const Id = types.Id;

var name_buf: [101]u8 = @splat(0);
var desc_buf: [301]u8 = @splat(0);
var name0: [101]u8 = @splat(0);
var desc0: [301]u8 = @splat(0);

/// A imagem escolhida ou o pedido de remover.
const Slot = struct {
    path: ?[:0]u8 = null,
    remove: bool = false,

    fn clear(s: *Slot) void {
        if (s.path) |p| std.heap.c_allocator.free(p);
        s.* = .{};
    }
    fn set(s: *Slot, p: [:0]const u8) void {
        s.clear();
        s.path = std.heap.c_allocator.dupeSentinel(u8, p, 0) catch null;
    }
    fn change(s: *const Slot) ev.ImageChange {
        if (s.path) |p| return .{ .path = std.heap.c_allocator.dupeSentinel(u8, p, 0) catch return .keep };
        return if (s.remove) .remove else .keep;
    }
};
var icon: Slot = .{};
var banner: Slot = .{};

/// Para qual imagem vai o arquivo que o seletor devolver.
var picking: enum { none, icon, banner } = .none;

/// O seletor de arquivos devolveu `path`: é para cá? (senão vira anexo)
pub fn takePicked(st: anytype, now_ms: i64, path: [:0]const u8) bool {
    if (picking == .none) return false;
    defer picking = .none;
    if (image_uri.mimeOf(path) == null) {
        st.showToast(now_ms, true, "use PNG, JPG, GIF ou WEBP", "use PNG, JPG, GIF or WEBP", .{});
    } else if (fileSize(path)) |size| {
        if (size > image_uri.max_bytes)
            st.showToast(now_ms, true, "a imagem passa de 10 MB", "the image is over 10 MB", .{})
        else
            (if (picking == .banner) &banner else &icon).set(path);
    } else st.showToast(now_ms, true, "não consegui ler o arquivo", "couldn't read the file", .{});
    return true;
}

fn fileSize(path: [:0]const u8) ?u64 {
    var info: c.SDL_PathInfo = undefined;
    if (!c.SDL_GetPathInfo(path.ptr, &info)) return null;
    return info.size;
}

/// Para o QA: escolher um arquivo sem abrir o seletor do sistema.
pub fn qaPick(path: [:0]const u8) void {
    icon.set(path);
}

pub fn open(ctx: *d.Ctx, id: Id, group: bool) void {
    @memset(&name_buf, 0);
    @memset(&desc_buf, 0);
    icon.clear();
    banner.clear();
    picking = .none;
    if (group) {
        if (ctx.store.channel(id)) |cs| copyTo(&name_buf, cs.info.name);
    } else if (ctx.store.guild(id)) |g| {
        copyTo(&name_buf, g.name);
        copyTo(&desc_buf, g.description);
    }
    name0 = name_buf;
    desc0 = desc_buf;
    ctx.st.popup = .{ .edit_place = .{ .id = id, .group = group } };
}

fn copyTo(buf: []u8, s: []const u8) void {
    const head = d.utf8Prefix(s, buf.len - 1);
    @memcpy(buf[0..head.len], head);
}

/// A linha de uma imagem: a prévia e os botões de trocar e remover.
fn imageRow(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, slot: *Slot, which: @TypeOf(picking), current: ?[]const u8, url: []const u8, title: []const u8, base_id: usize) void {
    const fam = ctx.ui;
    d.text(dl, fam.get(.semibold), 13, r.right() + 14, r.y + 2, ctx.col(.text), title);
    var shown = false;
    const scale = ctx.io.*.DisplayFramebufferScale.x;
    var fb: [1100]u8 = undefined;
    const want: []const u8 = if (slot.path) |p| std.fmt.bufPrint(&fb, "file://{s}", .{p}) catch "" else if (slot.remove or current == null) "" else url;
    if (want.len > 0) switch (ctx.images.getStill(want, r.w * scale, r.h * scale)) {
        .ready => |t| {
            @import("embeds.zig").imageCover(dl, t, r, 1, 8, 0);
            shown = true;
        },
        else => {},
    };
    if (!shown) {
        d.rect(dl, r, ctx.col(.rail).mix(ctx.col(.surface), 0.35), 8);
        d.border(dl, r, ctx.col(.border), 8, 1);
    }
    const change = i18n.tr("Trocar imagem", "Change Image");
    const cw = inbox.buttonWidth(ctx, change);
    const cr: d.Rect = .{ .x = r.right() + 14, .y = r.y + 24, .w = cw, .h = 28 };
    qa.mark(cr, "edit-pick:{s}", .{@tagName(which)});
    if (inbox.button(ctx, dl, base_id, cr, change, false)) {
        picking = which;
        ctx.act(.pick_image);
    }
    if (slot.path != null or (current != null and !slot.remove)) {
        const rm = i18n.tr("Remover", "Remove");
        const rr: d.Rect = .{ .x = cr.right() + 8, .y = cr.y, .w = inbox.buttonWidth(ctx, rm), .h = 28 };
        qa.mark(rr, "edit-remove:{s}", .{@tagName(which)});
        if (inbox.button(ctx, dl, base_id + 1, rr, rm, false)) {
            const had = current != null;
            slot.clear();
            slot.remove = had;
        }
    }
}

pub fn draw(ctx: *d.Ctx, id: Id, group: bool) void {
    const g = if (group) null else ctx.store.guild(id);
    const cs = if (group) ctx.store.channel(id) else null;
    if (g == null and cs == null) return popup.close(ctx);
    const can_banner = if (g) |x| x.can_banner else false;
    const h: f32 = 262 + (if (!group) @as(f32, 62) else 0) + (if (can_banner) @as(f32, 92) else 0);
    const r = forum.dialogRect(ctx, 480, h);
    const dl = popup.beginWindow("##edit-place", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    inbox.panelFrame(ctx, dl, r);
    const fam = ctx.ui;
    d.text(dl, fam.get(.bold), 17, r.x + 18, r.y + 16, ctx.col(.text), if (group) i18n.tr("Editar grupo", "Edit Group") else i18n.tr("Editar servidor", "Edit Server"));

    var y = r.y + 52;
    var ub: [160]u8 = undefined;
    const cur_icon: ?[]const u8 = if (g) |x| x.icon else cs.?.info.icon;
    const icon_url = if (cur_icon) |hash| w_ui.cdnUrl(&ub, if (group) .group else .guild, id, hash) else "";
    imageRow(ctx, dl, .{ .x = r.x + 18, .y = y, .w = 64, .h = 64 }, &icon, .icon, cur_icon, icon_url, i18n.tr("Ícone", "Icon"), 80);
    y += 78;
    if (can_banner) {
        var bb: [160]u8 = undefined;
        const url = if (g.?.banner) |hash| w_ui.bannerUrl(&bb, id, hash, false) else "";
        imageRow(ctx, dl, .{ .x = r.x + 18, .y = y, .w = 128, .h = 72 }, &banner, .banner, g.?.banner, url, i18n.tr("Banner", "Banner"), 84);
        y += 92;
    }

    d.text(dl, fam.get(.semibold), 12.5, r.x + 18, y, ctx.col(.muted), i18n.tr("Nome", "Name"));
    const nr: d.Rect = .{ .x = r.x + 18, .y = y + 20, .w = r.w - 36, .h = 36 };
    qa.mark(nr, "edit-name", .{});
    if (popup.appearing) c.ImGui_SetKeyboardFocusHere();
    _ = forum.textInput(ctx, dl, nr, "##edit-name", if (group) i18n.trZ("Nome do grupo", "Group name").ptr else i18n.trZ("Nome do servidor", "Server name").ptr, &name_buf, 0);
    y += 62;
    if (!group) {
        d.text(dl, fam.get(.semibold), 12.5, r.x + 18, y, ctx.col(.muted), i18n.tr("Descrição", "Description"));
        const dr: d.Rect = .{ .x = r.x + 18, .y = y + 20, .w = r.w - 36, .h = 36 };
        qa.mark(dr, "edit-description", .{});
        _ = forum.textInput(ctx, dl, dr, "##edit-desc", i18n.trZ("Sobre o que é o servidor", "What the server is about").ptr, &desc_buf, 0);
    }

    const name = std.mem.trim(u8, std.mem.sliceTo(&name_buf, 0), " ");
    const desc = std.mem.trim(u8, std.mem.sliceTo(&desc_buf, 0), " ");
    const name_changed = !std.mem.eql(u8, name, std.mem.trim(u8, std.mem.sliceTo(&name0, 0), " "));
    const desc_changed = !std.mem.eql(u8, desc, std.mem.trim(u8, std.mem.sliceTo(&desc0, 0), " "));
    const images_changed = icon.path != null or icon.remove or banner.path != null or banner.remove;
    // O Discord pede de 2 a 100 caracteres no servidor; grupo pode ficar sem nome.
    const valid = group or name.len >= 2;
    const changed = name_changed or desc_changed or images_changed;

    const lbl = i18n.tr("Salvar", "Save");
    const bw = d.width(fam.get(.semibold), 13.5, lbl) + 36;
    const br: d.Rect = .{ .x = r.right() - 18 - bw, .y = r.bottom() - 50, .w = bw, .h = 34 };
    qa.mark(br, "edit-save", .{});
    const save = forum.primary(ctx, dl, fam, 90, br, lbl, valid and changed);
    const cancel = i18n.tr("Cancelar", "Cancel");
    const cw = inbox.buttonWidth(ctx, cancel);
    const cr: d.Rect = .{ .x = br.x - cw - 10, .y = br.y + 3, .w = cw, .h = 28 };
    qa.mark(cr, "edit-cancel", .{});
    if (inbox.button(ctx, dl, 91, cr, cancel, false)) return popup.close(ctx);
    if (save and valid and changed) {
        const gpa = ctx.st.gpa;
        ctx.act(.{ .edit_place = .{
            .id = id,
            .group = group,
            .name = if (name_changed) gpa.dupe(u8, name) catch null else null,
            .description = if (desc_changed and !group) gpa.dupe(u8, desc) catch null else null,
            .icon = icon.change(),
            .banner = banner.change(),
        } });
        icon.clear();
        banner.clear();
        popup.close(ctx);
    }
}
