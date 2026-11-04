//! A parte da API C do Lua 5.4 (third_party/lua) que os plugins usam.
//! Declarada à mão: as macros do lua.h (lua_pcall, lua_pop…) não passam
//! pelo translate-c, então as equivalentes estão aqui como funções.
pub const State = opaque {};
pub const Debug = opaque {};

pub const Integer = i64;
pub const KContext = isize;
pub const CFunction = *const fn (?*State) callconv(.c) c_int;
pub const KFunction = *const fn (?*State, c_int, KContext) callconv(.c) c_int;
pub const Alloc = *const fn (?*anyopaque, ?*anyopaque, usize, usize) callconv(.c) ?*anyopaque;
pub const Hook = *const fn (?*State, ?*Debug) callconv(.c) void;

pub const OK: c_int = 0;
pub const MULTRET: c_int = -1;
pub const MASKCOUNT: c_int = 1 << 3;
/// -LUAI_MAXSTACK - 1000 (LUAI_MAXSTACK = 1000000 com int de 32 bits).
pub const REGISTRYINDEX: c_int = -1000000 - 1000;

pub const TNIL: c_int = 0;
pub const TBOOLEAN: c_int = 1;
pub const TNUMBER: c_int = 3;
pub const TSTRING: c_int = 4;
pub const TTABLE: c_int = 5;
pub const TFUNCTION: c_int = 6;

pub extern fn lua_newstate(f: Alloc, ud: ?*anyopaque) ?*State;
pub extern fn lua_close(L: ?*State) void;
pub extern fn lua_atpanic(L: ?*State, f: CFunction) ?CFunction;
pub extern fn lua_getallocf(L: ?*State, ud: *?*anyopaque) Alloc;
pub extern fn lua_sethook(L: ?*State, f: ?Hook, mask: c_int, count: c_int) void;

pub extern fn lua_gettop(L: ?*State) c_int;
pub extern fn lua_settop(L: ?*State, idx: c_int) void;
pub extern fn lua_pushvalue(L: ?*State, idx: c_int) void;
pub extern fn lua_rotate(L: ?*State, idx: c_int, n: c_int) void;
pub extern fn lua_type(L: ?*State, idx: c_int) c_int;
pub extern fn lua_tolstring(L: ?*State, idx: c_int, len: ?*usize) ?[*]const u8;
pub extern fn lua_tointegerx(L: ?*State, idx: c_int, isnum: ?*c_int) Integer;
pub extern fn lua_toboolean(L: ?*State, idx: c_int) c_int;
pub extern fn lua_touserdata(L: ?*State, idx: c_int) ?*anyopaque;
pub extern fn lua_rawlen(L: ?*State, idx: c_int) u64;

pub extern fn lua_pushnil(L: ?*State) void;
pub extern fn lua_pushinteger(L: ?*State, n: Integer) void;
pub extern fn lua_pushlstring(L: ?*State, s: [*]const u8, len: usize) ?[*]const u8;
pub extern fn lua_pushstring(L: ?*State, s: [*:0]const u8) ?[*]const u8;
pub extern fn lua_pushcclosure(L: ?*State, f: CFunction, n: c_int) void;
pub extern fn lua_pushboolean(L: ?*State, b: c_int) void;
pub extern fn lua_pushlightuserdata(L: ?*State, p: ?*anyopaque) void;

pub extern fn lua_getglobal(L: ?*State, name: [*:0]const u8) c_int;
pub extern fn lua_getfield(L: ?*State, idx: c_int, k: [*:0]const u8) c_int;
pub extern fn lua_rawgeti(L: ?*State, idx: c_int, n: Integer) c_int;
pub extern fn lua_rawget(L: ?*State, idx: c_int) c_int;
pub extern fn lua_getmetatable(L: ?*State, idx: c_int) c_int;
pub extern fn lua_setmetatable(L: ?*State, idx: c_int) c_int;
pub extern fn lua_rawset(L: ?*State, idx: c_int) void;
pub extern fn lua_createtable(L: ?*State, narr: c_int, nrec: c_int) void;
pub extern fn lua_setglobal(L: ?*State, name: [*:0]const u8) void;
pub extern fn lua_setfield(L: ?*State, idx: c_int, k: [*:0]const u8) void;
pub extern fn lua_rawseti(L: ?*State, idx: c_int, n: Integer) void;

pub extern fn lua_callk(L: ?*State, nargs: c_int, nresults: c_int, ctx: KContext, k: ?KFunction) void;
pub extern fn lua_pcallk(L: ?*State, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: KContext, k: ?KFunction) c_int;
pub extern fn lua_error(L: ?*State) c_int;
pub extern fn lua_concat(L: ?*State, n: c_int) void;

pub extern fn luaL_loadbufferx(L: ?*State, buf: [*]const u8, sz: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int;
pub extern fn luaL_checklstring(L: ?*State, arg: c_int, len: ?*usize) [*]const u8;
pub extern fn luaL_checktype(L: ?*State, arg: c_int, t: c_int) void;
pub extern fn luaL_checkany(L: ?*State, arg: c_int) void;
pub extern fn luaL_tolstring(L: ?*State, idx: c_int, len: ?*usize) [*]const u8;
pub extern fn luaL_where(L: ?*State, lvl: c_int) void;

pub extern fn luaopen_base(L: ?*State) c_int;
pub extern fn luaopen_string(L: ?*State) c_int;
pub extern fn luaopen_table(L: ?*State) c_int;
pub extern fn luaopen_math(L: ?*State) c_int;
pub extern fn luaopen_utf8(L: ?*State) c_int;
pub extern fn luaopen_os(L: ?*State) c_int;

// --- As macros do lua.h -------------------------------------------------------

pub fn pop(L: ?*State, n: c_int) void {
    lua_settop(L, -n - 1);
}
pub fn newtable(L: ?*State) void {
    lua_createtable(L, 0, 0);
}
pub fn pushcfunction(L: ?*State, f: CFunction) void {
    lua_pushcclosure(L, f, 0);
}
pub fn pcall(L: ?*State, nargs: c_int, nresults: c_int) c_int {
    return lua_pcallk(L, nargs, nresults, 0, 0, null);
}
pub fn call(L: ?*State, nargs: c_int, nresults: c_int) void {
    lua_callk(L, nargs, nresults, 0, null);
}
pub fn insert(L: ?*State, idx: c_int) void {
    lua_rotate(L, idx, 1);
}
pub fn pushSlice(L: ?*State, s: []const u8) void {
    _ = lua_pushlstring(L, s.ptr, s.len);
}
/// Texto no índice (só se for string ou número), sem copiar.
pub fn toSlice(L: ?*State, idx: c_int) ?[]const u8 {
    var len: usize = 0;
    const p = lua_tolstring(L, idx, &len) orelse return null;
    return p[0..len];
}
pub fn checkSlice(L: ?*State, arg: c_int) []const u8 {
    var len: usize = 0;
    const p = luaL_checklstring(L, arg, &len);
    return p[0..len];
}
