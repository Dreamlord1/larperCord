//! Devolver memória com a glibc. Em outro sistema, nada aqui faz efeito.
//! (Limitar as arenas com M_ARENA_MAX foi medido e não ganhou além do ruído.)
const builtin = @import("builtin");
const c = @import("c");

const glibc = builtin.os.tag == .linux and builtin.abi.isGnu();

/// Devolve ao sistema o que está livre no meio das arenas (só o topo volta
/// sozinho). Leva milissegundos: fora da thread da UI.
pub fn trim() void {
    if (glibc) _ = c.malloc_trim(0);
}
