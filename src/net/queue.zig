//! Fila protegida por mutex para trocar mensagens entre threads.
const std = @import("std");
const c = @import("c");

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: *c.SDL_Mutex,
        cond: *c.SDL_Condition,
        items: std.ArrayList(T) = .empty,
        gpa: std.mem.Allocator,

        pub fn init(gpa: std.mem.Allocator) !Self {
            return .{
                .gpa = gpa,
                .mutex = c.SDL_CreateMutex() orelse return error.SdlMutex,
                .cond = c.SDL_CreateCondition() orelse return error.SdlCondition,
            };
        }

        pub fn deinit(q: *Self) void {
            q.items.deinit(q.gpa);
            c.SDL_DestroyCondition(q.cond);
            c.SDL_DestroyMutex(q.mutex);
        }

        pub fn push(q: *Self, item: T) void {
            c.SDL_LockMutex(q.mutex);
            defer c.SDL_UnlockMutex(q.mutex);
            q.items.append(q.gpa, item) catch return;
            c.SDL_SignalCondition(q.cond);
        }

        /// Move tudo que está na fila para `out` (que deve estar vazio).
        pub fn drain(q: *Self, out: *std.ArrayList(T)) void {
            c.SDL_LockMutex(q.mutex);
            defer c.SDL_UnlockMutex(q.mutex);
            std.mem.swap(std.ArrayList(T), &q.items, out);
        }

        /// Espera até `timeout_ms` e tira o item mais novo (LIFO), ou null.
        pub fn waitPop(q: *Self, timeout_ms: i32) ?T {
            c.SDL_LockMutex(q.mutex);
            defer c.SDL_UnlockMutex(q.mutex);
            if (q.items.items.len == 0 and timeout_ms > 0)
                _ = c.SDL_WaitConditionTimeout(q.cond, q.mutex, timeout_ms);
            return q.items.pop();
        }

        /// Acorda todo mundo que está esperando (para encerrar).
        pub fn wakeAll(q: *Self) void {
            c.SDL_LockMutex(q.mutex);
            defer c.SDL_UnlockMutex(q.mutex);
            c.SDL_BroadcastCondition(q.cond);
        }

        /// Espera até `timeout_ms` por um item e drena a fila.
        pub fn waitDrain(q: *Self, out: *std.ArrayList(T), timeout_ms: i32) void {
            c.SDL_LockMutex(q.mutex);
            defer c.SDL_UnlockMutex(q.mutex);
            if (q.items.items.len == 0 and timeout_ms > 0)
                _ = c.SDL_WaitConditionTimeout(q.cond, q.mutex, timeout_ms);
            std.mem.swap(std.ArrayList(T), &q.items, out);
        }
    };
}
