## Private interface to the precompiled clonim runtime. Generated programs
## import this module; implementations live in libclonim_runtime.a.
import runtime_types
export runtime_types

proc mkFn*(name: string,
           f: proc (args: openArray[Value]): Value {.closure.}): Value
  {.cdecl, importc: "clonim_mk_fn".}

{.push cdecl.}
proc initClonimRuntime*() {.importc: "ClonimRuntimeNimMain".}
proc registerCore*() {.importc: "clonim_register_core".}
proc registerCoreSelected*(names: openArray[string])
  {.importc: "clonim_register_core_selected".}
proc registerCoreArithmetic*(names: openArray[string])
  {.importc: "clonim_register_core_arithmetic".}
proc registerCorePredicates*(names: openArray[string])
  {.importc: "clonim_register_core_predicates".}
proc registerCoreStringsIo*(names: openArray[string])
  {.importc: "clonim_register_core_strings_io".}
proc registerCoreCollections*(names: openArray[string])
  {.importc: "clonim_register_core_collections".}
proc registerCoreHigherOrder*(names: openArray[string])
  {.importc: "clonim_register_core_higher_order".}
proc registerCoreStateHost*(names: openArray[string])
  {.importc: "clonim_register_core_state_host".}
proc registerNamespaceCore*() {.importc: "clonim_register_namespace_core".}

proc err*(msg: string) {.noreturn, importc: "clonim_err".}
proc varCell*(name: string): VarCell {.importc: "clonim_var_cell".}
proc setVar*(name: string, v: Value): Value {.discardable, importc: "clonim_set_var".}
proc cellGet*(c: VarCell): Value {.importc: "clonim_cell_get".}
proc cellIs*(c: VarCell, v: Value): bool {.importc: "clonim_cell_is".}
proc getVar*(name: string): Value {.importc: "clonim_get_var".}
proc hasVar*(name: string): bool {.importc: "clonim_has_var".}
proc call*(f: Value, args: openArray[Value]): Value {.importc: "clonim_call".}
proc argAt*(args: openArray[Value], i: int): Value {.importc: "clonim_arg_at".}
proc restArgs*(args: openArray[Value], i: int): Value {.importc: "clonim_rest_args".}
proc seqDrop*(v: Value, n: int): Value {.importc: "clonim_seq_drop".}
proc seqDropOrNil*(v: Value, n: int): Value {.importc: "clonim_seq_drop_or_nil".}
proc toSeq*(v: Value): seq[Value] {.importc: "clonim_to_seq".}
proc truthy*(v: Value): bool {.importc: "clonim_truthy".}

iterator elems*(v: Value): Value =
  for x in toSeq(v): yield x

proc mkInt*(x: int64): Value {.importc: "clonim_mk_int".}
proc mkFloat*(x: float64): Value {.importc: "clonim_mk_float".}
proc mkChar*(code: int64): Value {.importc: "clonim_mk_char".}
proc mkStr*(x: string): Value {.importc: "clonim_mk_str".}
proc mkKeyword*(x: string): Value {.importc: "clonim_mk_keyword".}
proc mkSymbol*(x: string): Value {.importc: "clonim_mk_symbol".}
proc mkList*(xs: openArray[Value]): Value {.importc: "clonim_mk_list".}
proc mkVector*(xs: openArray[Value]): Value {.importc: "clonim_mk_vector".}
proc mkSet*(xs: openArray[Value]): Value {.importc: "clonim_mk_set".}
proc mkMap*(ps: seq[(Value, Value)]): Value {.importc: "clonim_mk_map".}

proc idiv*(a, b: int64): int64 {.importc: "clonim_idiv".}
proc irem*(a, b: int64): int64 {.importc: "clonim_irem".}
proc add2*(a, b: Value): Value {.importc: "clonim_add2".}
proc sub2*(a, b: Value): Value {.importc: "clonim_sub2".}
proc mul2*(a, b: Value): Value {.importc: "clonim_mul2".}
proc lt2*(a, b: Value): Value {.importc: "clonim_lt2".}
proc gt2*(a, b: Value): Value {.importc: "clonim_gt2".}
proc le2*(a, b: Value): Value {.importc: "clonim_le2".}
proc ge2*(a, b: Value): Value {.importc: "clonim_ge2".}
proc eq2*(a, b: Value): Value {.importc: "clonim_eq2".}
proc ne2*(a, b: Value): Value {.importc: "clonim_ne2".}
proc inc1*(a: Value): Value {.importc: "clonim_inc1".}
proc dec1*(a: Value): Value {.importc: "clonim_dec1".}
proc fusedReduce*(f, init: Value, hasInit: bool, base: Value,
                  ops: openArray[FusedOp]): Value {.importc: "clonim_fused_reduce".}
proc fusedCount*(base: Value, ops: openArray[FusedOp]): Value
  {.importc: "clonim_fused_count".}
{.pop.}
