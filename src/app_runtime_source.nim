## Private source interface used by the self-contained release compiler.
## Nim compiles these modules together with the generated program, avoiding a
## second copy of Nim's support runtime while keeping the result standalone.
##
## Importing runtime_lib emits its exported entry points in every program, so
## the runtime modules compile to the same C whatever the program uses. That
## lets every program share one nimcache and reuse the runtime's objects; only
## the program's own module is compiled per program.
import runtime, core, namespaces, runtime_lib
export runtime, core, namespaces

proc initClonimRuntime*() {.inline.} = discard

# Generated programs register only the core vars they reach, passing the names
# to each group (see app_runtime.nim). Inline, so this module's C does not
# depend on which groups a program calls.
proc registerCoreArithmetic*(names: openArray[string]) {.inline.} =
  registerCoreArithmeticSelected(names)
proc registerCorePredicates*(names: openArray[string]) {.inline.} =
  registerCorePredicatesSelected(names)
proc registerCoreStringsIo*(names: openArray[string]) {.inline.} =
  registerCoreStringsIoSelected(names)
proc registerCoreCollections*(names: openArray[string]) {.inline.} =
  registerCoreCollectionsSelected(names)
proc registerCoreHigherOrder*(names: openArray[string]) {.inline.} =
  registerCoreHigherOrderSelected(names)
proc registerCoreStateHost*(names: openArray[string]) {.inline.} =
  registerCoreStateHostSelected(names)

proc pinSeqInstances() {.exportc: "clonim_pin_seq_instances".} =
  ## Generated programs build `seq[Value]` and `seq[(Value, Value)]`. Nim emits
  ## those generic instances into the shared system/runtime C, named after the
  ## module that first instantiates them. Instantiate them here, before any
  ## program does, so that C is identical for every program.
  var pairs = newSeq[(Value, Value)]()
  pairs.setLen(1)
  discard mkMap(pairs)
  var vals = newSeq[Value]()
  vals.setLen(1)
  discard mkList(vals)
