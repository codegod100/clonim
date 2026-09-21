## C-named entry points for clonim's private static runtime archive.
import runtime, core, namespaces

proc clonim_mk_fn(name: string,
                  f: proc (args: openArray[Value]): Value {.closure.}): Value
  {.cdecl, exportc.} =
  mkFn(name, f)

{.push cdecl, exportc.}
proc clonim_register_core() = registerCore()
proc clonim_register_namespace_core() = registerNamespaceCore()
proc clonim_err(msg: string) {.noreturn.} = err(msg)
proc clonim_var_cell(name: string): VarCell = varCell(name)
proc clonim_set_var(name: string, v: Value): Value = setVar(name, v)
proc clonim_cell_get(c: VarCell): Value = cellGet(c)
proc clonim_cell_is(c: VarCell, v: Value): bool = cellIs(c, v)
proc clonim_get_var(name: string): Value = getVar(name)
proc clonim_has_var(name: string): bool = hasVar(name)
proc clonim_call(f: Value, args: openArray[Value]): Value = call(f, args)
proc clonim_arg_at(args: openArray[Value], i: int): Value = argAt(args, i)
proc clonim_rest_args(args: openArray[Value], i: int): Value = restArgs(args, i)
proc clonim_seq_drop(v: Value, n: int): Value = seqDrop(v, n)
proc clonim_seq_drop_or_nil(v: Value, n: int): Value = seqDropOrNil(v, n)
proc clonim_to_seq(v: Value): seq[Value] = toSeq(v)
proc clonim_truthy(v: Value): bool = truthy(v)

proc clonim_mk_int(x: int64): Value = mkInt(x)
proc clonim_mk_float(x: float64): Value = mkFloat(x)
proc clonim_mk_char(code: int64): Value = mkChar(code)
proc clonim_mk_str(x: string): Value = mkStr(x)
proc clonim_mk_keyword(x: string): Value = mkKeyword(x)
proc clonim_mk_symbol(x: string): Value = mkSymbol(x)
proc clonim_mk_list(xs: openArray[Value]): Value = mkList(xs)
proc clonim_mk_vector(xs: openArray[Value]): Value = mkVector(xs)
proc clonim_mk_set(xs: openArray[Value]): Value = mkSet(xs)
proc clonim_mk_map(ps: seq[(Value, Value)]): Value = mkMap(ps)

proc clonim_idiv(a, b: int64): int64 = idiv(a, b)
proc clonim_irem(a, b: int64): int64 = irem(a, b)
proc clonim_add2(a, b: Value): Value = add2(a, b)
proc clonim_sub2(a, b: Value): Value = sub2(a, b)
proc clonim_mul2(a, b: Value): Value = mul2(a, b)
proc clonim_lt2(a, b: Value): Value = lt2(a, b)
proc clonim_gt2(a, b: Value): Value = gt2(a, b)
proc clonim_le2(a, b: Value): Value = le2(a, b)
proc clonim_ge2(a, b: Value): Value = ge2(a, b)
proc clonim_eq2(a, b: Value): Value = eq2(a, b)
proc clonim_ne2(a, b: Value): Value = ne2(a, b)
proc clonim_inc1(a: Value): Value = inc1(a)
proc clonim_dec1(a: Value): Value = dec1(a)
proc clonim_fused_reduce(f, init: Value, hasInit: bool, base: Value,
                         ops: openArray[FusedOp]): Value =
  fusedReduce(f, init, hasInit, base, ops)
proc clonim_fused_count(base: Value, ops: openArray[FusedOp]): Value =
  fusedCount(base, ops)
{.pop.}
