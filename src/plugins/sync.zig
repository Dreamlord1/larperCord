//! Trava, condição, thread e relógio dos plugins. No app são os do SDL, como no
//! resto do código; os testes (que rodam sem SDL) usam os da biblioteca padrão.
const std = @import("std");
const builtin = @import("builtin");

const Impl = if (builtin.is_test) StdImpl else SdlImpl;

pub const Lock = Impl.Lock;
pub const Thread = Impl.Thread;
pub const nowMs = Impl.nowMs;
pub const sleepMs = Impl.sleepMs;

const StdImpl = struct {
    const io = std.Options.debug_io;

    const Lock = struct {
        m: std.Io.Mutex = .init,
        cv: std.Io.Condition = .init,

        fn init() StdImpl.Lock {
            return .{};
        }
        pub fn deinit(_: *StdImpl.Lock) void {}
        pub fn lock(l: *StdImpl.Lock) void {
            l.m.lockUncancelable(io);
        }
        pub fn unlock(l: *StdImpl.Lock) void {
            l.m.unlock(io);
        }
        /// Com a trava na mão. null = sem prazo.
        pub fn wait(l: *StdImpl.Lock, ms: ?u32) void {
            if (ms) |t| {
                l.cv.waitTimeout(io, &l.m, .{ .duration = .{ .raw = .fromMilliseconds(t), .clock = .awake } }) catch {};
            } else l.cv.waitUncancelable(io, &l.m);
        }
        pub fn signal(l: *StdImpl.Lock) void {
            l.cv.signal(io);
        }
    };

    const Thread = struct {
        t: std.Thread,

        pub fn spawn(comptime f: fn (?*anyopaque) void, arg: ?*anyopaque, _: [*:0]const u8) ?StdImpl.Thread {
            const t = std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, f, .{arg}) catch return null;
            return .{ .t = t };
        }
        pub fn join(th: StdImpl.Thread) void {
            th.t.join();
        }
    };

    fn nowMs() i64 {
        return std.Io.Clock.real.now(io).toMilliseconds();
    }

    fn sleepMs(ms: u32) void {
        std.Io.sleep(io, .fromMilliseconds(ms), .awake) catch {};
    }
};

const SdlImpl = struct {
    const c = @import("c");

    const Lock = struct {
        m: ?*c.SDL_Mutex = null,
        cv: ?*c.SDL_Condition = null,

        fn init() SdlImpl.Lock {
            return .{ .m = c.SDL_CreateMutex(), .cv = c.SDL_CreateCondition() };
        }
        pub fn deinit(l: *SdlImpl.Lock) void {
            c.SDL_DestroyCondition(l.cv);
            c.SDL_DestroyMutex(l.m);
        }
        pub fn lock(l: *SdlImpl.Lock) void {
            c.SDL_LockMutex(l.m);
        }
        pub fn unlock(l: *SdlImpl.Lock) void {
            c.SDL_UnlockMutex(l.m);
        }
        pub fn wait(l: *SdlImpl.Lock, ms: ?u32) void {
            if (ms) |t| {
                _ = c.SDL_WaitConditionTimeout(l.cv, l.m, @intCast(@min(t, std.math.maxInt(i32))));
            } else c.SDL_WaitCondition(l.cv, l.m);
        }
        pub fn signal(l: *SdlImpl.Lock) void {
            c.SDL_SignalCondition(l.cv);
        }
    };

    const Thread = struct {
        t: *c.SDL_Thread,

        pub fn spawn(comptime f: fn (?*anyopaque) void, arg: ?*anyopaque, name: [*:0]const u8) ?SdlImpl.Thread {
            const Enter = struct {
                fn run(raw: ?*anyopaque) callconv(.c) c_int {
                    f(raw);
                    return 0;
                }
            };
            return .{ .t = c.SDL_CreateThread(Enter.run, name, arg) orelse return null };
        }
        pub fn join(th: SdlImpl.Thread) void {
            c.SDL_WaitThread(th.t, null);
        }
    };

    fn nowMs() i64 {
        var t: c.SDL_Time = 0;
        _ = c.SDL_GetCurrentTime(&t);
        return @divTrunc(t, 1_000_000);
    }

    fn sleepMs(ms: u32) void {
        c.SDL_Delay(ms);
    }
};

pub fn lockInit() Lock {
    return Lock.init();
}
