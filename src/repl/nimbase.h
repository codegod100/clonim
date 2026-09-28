/* Put first on the C include path when building the REPL host and the shared
   libraries it loads (src/repl_host.nim). Nim marks its generated symbols
   hidden, so each library would otherwise keep a private copy of the Nim
   system module and of the runtime's globals: its own allocator, its own
   exception state, its own NilV. With default visibility, and the host linked
   with -rdynamic, the dynamic linker binds every symbol the host defines to
   the host's copy, so all inputs share one runtime. */
#include_next <nimbase.h>
#undef N_LIB_PRIVATE
#define N_LIB_PRIVATE
