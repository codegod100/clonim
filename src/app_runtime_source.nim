## Private source interface used by the self-contained release compiler.
## Nim compiles these modules together with the generated program, avoiding a
## second copy of Nim's support runtime while keeping the result standalone.
import runtime, core, namespaces
export runtime, core, namespaces

proc initClonimRuntime*() = discard
