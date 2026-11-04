//! Clique em link no texto: o que é do Discord abre aqui; o resto, no navegador.
const d = @import("draw.zig");
const att = @import("attachments.zig");
const links = @import("../core/links.zig");
const types = @import("../core/types.zig");

pub fn open(ctx: *d.Ctx, url: []const u8) void {
    const l = links.parseMessage(url) orelse return att.openUrl(url);
    const cs = ctx.store.channel(l.channel) orelse {
        // Canal que esta conta não vê (ou servidor em que não está): quem sabe
        // o navegador, com outra conta, abre.
        ctx.st.showToast(ctx.now_ms, false, "esse canal não está nesta conta: abrindo no navegador", "that channel isn't on this account: opening in the browser", .{});
        return att.openUrl(url);
    };
    if (cs.info.kind != .text) return att.openUrl(url);
    ctx.act(.{ .open_message = .{ .channel = l.channel, .id = l.message } });
}
