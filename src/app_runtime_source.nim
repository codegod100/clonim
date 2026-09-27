## Private source interface used by the self-contained release compiler.
## Nim compiles these modules together with the generated program, avoiding a
## second copy of Nim's support runtime while keeping the result standalone.
import runtime, core, namespaces
export runtime, core, namespaces

proc initClonimRuntime*() = discard

# Generated programs register only the core vars they reach, passing the names
# to each group (see app_runtime.nim).
proc registerCoreArithmetic*(names: openArray[string]) =
  registerCoreArithmeticSelected(names)
proc registerCorePredicates*(names: openArray[string]) =
  registerCorePredicatesSelected(names)
proc registerCoreStringsIo*(names: openArray[string]) =
  registerCoreStringsIoSelected(names)
proc registerCoreCollections*(names: openArray[string]) =
  registerCoreCollectionsSelected(names)
proc registerCoreHigherOrder*(names: openArray[string]) =
  registerCoreHigherOrderSelected(names)
proc registerCoreStateHost*(names: openArray[string]) =
  registerCoreStateHostSelected(names)
