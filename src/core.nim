## clonim core — clojure.core builtins, registered into the global var table.
import std/[strutils, math, times, random]
import runtime

proc num(v: Value): float64 =
  case v.kind
  of kInt: float64(v.i)
  of kFloat: v.f
  else: err("Not a number: " & prStr(v))

proc isFloaty(vs: openArray[Value]): bool =
  for v in vs:
    if v.kind == kFloat: return true
  false

proc intOf(v: Value): int64 =
  case v.kind
  of kInt: v.i
  of kFloat: int64(v.f)
  else: err("Not a number: " & prStr(v))

proc arith(name: string, args: openArray[Value], unit: int64,
           fi: proc (a, b: int64): int64, ff: proc (a, b: float64): float64): Value =
  if args.len == 0: return mkInt(unit)
  if isFloaty(args):
    var acc = (if args.len == 1: float64(unit) else: num(args[0]))
    let start = (if args.len == 1: 0 else: 1)
    for i in start ..< args.len: acc = ff(acc, num(args[i]))
    return mkFloat(acc)
  var acc = (if args.len == 1: unit else: args[0].i)
  let start = (if args.len == 1: 0 else: 1)
  for i in start ..< args.len: acc = fi(acc, args[i].i)
  mkInt(acc)

proc cmpChain(args: openArray[Value], ok: proc (c: int): bool): Value =
  for i in 0 ..< args.len - 1:
    let a = num(args[i])
    let b = num(args[i + 1])
    let c = (if a < b: -1 elif a > b: 1 else: 0)
    if not ok(c): return FalseV
  TrueV

# ------------------------------------------------------- inlinable primitives
## Two-argument forms of the arithmetic and comparison builtins, exported so
## call sites can inline them instead of dispatching through a closure and an
## argument list, and so the analyzer has something to compile an integer
## expression down to. Each takes the int/int path in a couple of instructions
## and otherwise falls back to the same numeric-tower behaviour as the generic
## builtin.

## Integer division that reports rather than trapping: Nim's `div` raises an
## uncatchable defect on a zero divisor, where `/` here already errored.
proc idiv*(a, b: int64): int64 {.inline.} =
  if b == 0: err("Divide by zero")
  a div b

proc irem*(a, b: int64): int64 {.inline.} =
  if b == 0: err("Divide by zero")
  a mod b

proc add2*(a, b: Value): Value {.inline.} =
  if a.kind == kInt and b.kind == kInt: mkInt(a.i + b.i)
  else: mkFloat(num(a) + num(b))

proc sub2*(a, b: Value): Value {.inline.} =
  if a.kind == kInt and b.kind == kInt: mkInt(a.i - b.i)
  else: mkFloat(num(a) - num(b))

proc mul2*(a, b: Value): Value {.inline.} =
  if a.kind == kInt and b.kind == kInt: mkInt(a.i * b.i)
  else: mkFloat(num(a) * num(b))

proc lt2*(a, b: Value): Value {.inline.} =
  if a.kind == kInt and b.kind == kInt: mkBool(a.i < b.i)
  else: mkBool(num(a) < num(b))

proc gt2*(a, b: Value): Value {.inline.} =
  if a.kind == kInt and b.kind == kInt: mkBool(a.i > b.i)
  else: mkBool(num(a) > num(b))

proc le2*(a, b: Value): Value {.inline.} =
  if a.kind == kInt and b.kind == kInt: mkBool(a.i <= b.i)
  else: mkBool(num(a) <= num(b))

proc ge2*(a, b: Value): Value {.inline.} =
  if a.kind == kInt and b.kind == kInt: mkBool(a.i >= b.i)
  else: mkBool(num(a) >= num(b))

proc eq2*(a, b: Value): Value {.inline.} =
  if a.kind == kInt and b.kind == kInt: mkBool(a.i == b.i)
  else: mkBool(equals(a, b))

proc ne2*(a, b: Value): Value {.inline.} =
  if a.kind == kInt and b.kind == kInt: mkBool(a.i != b.i)
  else: mkBool(not equals(a, b))

proc inc1*(a: Value): Value {.inline.} =
  if a.kind == kInt: mkInt(a.i + 1) else: mkFloat(num(a) + 1.0)

proc dec1*(a: Value): Value {.inline.} =
  if a.kind == kInt: mkInt(a.i - 1) else: mkFloat(num(a) - 1.0)

## Guarded forms: the whole call site, cell check included, as one expression,
## for the call sites where a def in the program can still rebind the name.
proc add2g*(c: VarCell, k: Value, a, b: Value): Value {.inline.} =
  if cellIs(c, k): add2(a, b) else: call(cellGet(c), [a, b])

proc sub2g*(c: VarCell, k: Value, a, b: Value): Value {.inline.} =
  if cellIs(c, k): sub2(a, b) else: call(cellGet(c), [a, b])

proc mul2g*(c: VarCell, k: Value, a, b: Value): Value {.inline.} =
  if cellIs(c, k): mul2(a, b) else: call(cellGet(c), [a, b])

proc lt2g*(c: VarCell, k: Value, a, b: Value): Value {.inline.} =
  if cellIs(c, k): lt2(a, b) else: call(cellGet(c), [a, b])

proc gt2g*(c: VarCell, k: Value, a, b: Value): Value {.inline.} =
  if cellIs(c, k): gt2(a, b) else: call(cellGet(c), [a, b])

proc le2g*(c: VarCell, k: Value, a, b: Value): Value {.inline.} =
  if cellIs(c, k): le2(a, b) else: call(cellGet(c), [a, b])

proc ge2g*(c: VarCell, k: Value, a, b: Value): Value {.inline.} =
  if cellIs(c, k): ge2(a, b) else: call(cellGet(c), [a, b])

proc eq2g*(c: VarCell, k: Value, a, b: Value): Value {.inline.} =
  if cellIs(c, k): eq2(a, b) else: call(cellGet(c), [a, b])

proc ne2g*(c: VarCell, k: Value, a, b: Value): Value {.inline.} =
  if cellIs(c, k): ne2(a, b) else: call(cellGet(c), [a, b])

proc inc1g*(c: VarCell, k: Value, a: Value): Value {.inline.} =
  if cellIs(c, k): inc1(a) else: call(cellGet(c), [a])

proc dec1g*(c: VarCell, k: Value, a: Value): Value {.inline.} =
  if cellIs(c, k): dec1(a) else: call(cellGet(c), [a])

proc getIn(coll, k, dflt: Value): Value =
  if coll.isNil or coll.kind == kNil: return dflt
  case coll.kind
  of kMap: mapGet(coll.m, k, dflt)
  of kSet: mapGet(coll.m, k, dflt)
  of kVector:
    if k.kind != kInt: return dflt
    let i = int(k.i)
    if i < 0 or i >= coll.vec.cnt: dflt else: vecNth(coll.vec, i)
  of kList:
    if k.kind != kInt: return dflt
    let i = int(k.i)
    if i < 0 or i >= coll.xs.len: dflt else: coll.xs[i]
  of kStr:
    if k.kind != kInt: return dflt
    let i = int(k.i)
    if i < 0 or i >= coll.s.len: dflt else: mkStr($coll.s[i])
  else: dflt

proc assocOne(coll, k, v: Value): Value =
  if coll.isNil or coll.kind == kNil:
    return mkMapOf(mapAssoc(emptyPMap(), k, v))
  case coll.kind
  of kMap: mkMapOf(mapAssoc(coll.m, k, v))
  of kVector:
    if k.kind != kInt: err("Vector index must be an integer")
    mkVec(vecAssoc(coll.vec, int(k.i), v))
  else: err("assoc not supported on " & prStr(coll))

proc conjOne(coll, x: Value): Value =
  if coll.isNil or coll.kind == kNil: return mkList(@[x])
  case coll.kind
  of kVector: mkVec(vecConj(coll.vec, x))
  of kList: mkList(@[x] & coll.xs)
  of kSet:
    (if mapContains(coll.m, x): coll else: mkSetOf(mapAssoc(coll.m, x, x)))
  of kMap:
    let xs = items(x)
    if x.kind in {kVector, kList} and xs.len == 2:
      assocOne(coll, xs[0], xs[1])
    elif x.kind == kMap:
      var m = coll.m
      for e in mapEntries(x.m): m = mapAssoc(m, e.key, e.val)
      mkMapOf(m)
    else: err("conj on map needs a pair")
  else: err("conj not supported on " & prStr(coll))

# ------------------------------------------------------------- lazy seqs
## Producers share one shape: capture a Cursor, and return a thunk that
## advances a *copy* of it, yields one cons cell, and hands the advanced copy
## to the next thunk. Because each thunk only ever takes one step, an infinite
## source costs exactly as much as the consumer asks for.

proc lazyOf(c: Cursor): Value =
  ## The remainder of a cursor, as a lazy seq.
  let cur = c
  mkLazy(proc (): Value =
    var cc = cur
    if not hasNext(cc): return NilV
    let x = next(cc)
    mkCons(x, lazyOf(cc)))

proc lazyFilter(pred: Value, c: Cursor, keep: bool): Value

proc lazyMap(f: Value, c: Cursor): Value =
  ## Chunked, which means f runs for up to ChunkSize elements as soon as the
  ## first is demanded -- the same trade Clojure makes. f must not be relied on
  ## for per-element side effects; `doseq` and `run!` are the tools for that.
  let cur = c
  mkLazy(proc (): Value =
    var cc = cur
    var xs = newSeqOfCap[Value](ChunkSize)
    while xs.len < ChunkSize and hasNext(cc):
      xs.add call(f, [next(cc)])
    if xs.len == 0: return NilV
    mkChunk(xs, 0, lazyMap(f, cc)))

proc lazyMapN(f: Value, cs: seq[Cursor]): Value =
  let curs = cs
  mkLazy(proc (): Value =
    var ccs = curs
    var args: seq[Value] = @[]
    for i in 0 ..< ccs.len:
      if not hasNext(ccs[i]): return NilV    # stop at the shortest
      args.add next(ccs[i])
    mkCons(call(f, args), lazyMapN(f, ccs)))

proc lazyMapIndexed(f: Value, i: int64, c: Cursor): Value =
  let cur = c
  mkLazy(proc (): Value =
    var cc = cur
    if not hasNext(cc): return NilV
    let x = next(cc)
    mkCons(call(f, [mkInt(i), x]), lazyMapIndexed(f, i + 1, cc)))

proc lazyFilter(pred: Value, c: Cursor, keep: bool): Value =
  ## Draws up to ChunkSize source elements per step and emits whichever pass,
  ## rather than pulling until ChunkSize have passed: that keeps the work per
  ## step bounded when matches are rare in a long or infinite source.
  let cur = c
  mkLazy(proc (): Value =
    var cc = cur
    while true:
      var xs = newSeqOfCap[Value](ChunkSize)
      var drawn = 0
      while drawn < ChunkSize and hasNext(cc):
        let x = next(cc)
        if truthy(call(pred, [x])) == keep: xs.add x
        inc drawn
      if xs.len > 0: return mkChunk(xs, 0, lazyFilter(pred, cc, keep))
      if drawn == 0: return NilV)

proc lazyTake(n: int, c: Cursor): Value =
  if n <= 0: return mkList(@[])
  let cur = c
  mkLazy(proc (): Value =
    var cc = cur
    var want = min(n, ChunkSize)
    var xs = newSeqOfCap[Value](want)
    while xs.len < want and hasNext(cc): xs.add next(cc)
    if xs.len == 0: return NilV
    mkChunk(xs, 0, lazyTake(n - xs.len, cc)))

proc lazyDrop(n: int, c: Cursor): Value =
  let cur = c
  mkLazy(proc (): Value =
    var cc = cur
    var k = n
    while k > 0 and hasNext(cc): discard next(cc); dec k
    force(lazyOf(cc)))

proc lazyTakeWhile(pred: Value, c: Cursor): Value =
  let cur = c
  mkLazy(proc (): Value =
    var cc = cur
    if not hasNext(cc): return NilV
    let x = next(cc)
    if not truthy(call(pred, [x])): return NilV
    mkCons(x, lazyTakeWhile(pred, cc)))

proc lazyDropWhile(pred: Value, c: Cursor): Value =
  let cur = c
  mkLazy(proc (): Value =
    var cc = cur
    while true:
      var peek = cc
      if not hasNext(peek): return NilV
      let x = next(peek)
      if not truthy(call(pred, [x])): return mkCons(x, lazyOf(peek))
      cc = peek)

proc lazyRange(i, hi, step: int64, bounded: bool): Value =
  ## Chunked: one thunk and one chunk per ChunkSize elements rather than a
  ## cons and a thunk each. An unbounded range stays lazy -- it just realizes
  ## a bounded batch at a time.
  mkLazyRec(proc (): Value =
    var cur = i
    var xs = newSeqOfCap[Value](ChunkSize)
    while xs.len < ChunkSize:
      if bounded and ((step > 0 and cur >= hi) or (step < 0 and cur <= hi)): break
      xs.add mkInt(cur)
      cur += step
    if xs.len == 0: return NilV
    mkChunk(xs, 0, lazyRange(cur, hi, step, bounded)),
    Recipe(rk: rkRange, lo: i, hi: hi, step: step, bounded: bounded))

proc lazyIterate(f, x: Value): Value =
  mkLazy(proc (): Value = mkCons(x, lazyIterate(f, call(f, [x]))))

proc lazyRepeat(x: Value, n: int64, bounded: bool): Value =
  mkLazy(proc (): Value =
    if bounded and n <= 0: return NilV
    mkCons(x, lazyRepeat(x, n - 1, bounded)))

proc lazyRepeatedly(f: Value, n: int64, bounded: bool): Value =
  mkLazy(proc (): Value =
    if bounded and n <= 0: return NilV
    mkCons(call(f, []), lazyRepeatedly(f, n - 1, bounded)))

proc lazyCycle(orig: Value, c: Cursor): Value =
  let cur = c
  mkLazy(proc (): Value =
    var cc = cur
    if not hasNext(cc):
      cc = cursor(orig)                      # wrap around
      if not hasNext(cc): return NilV        # empty source: empty cycle
    let x = next(cc)
    mkCons(x, lazyCycle(orig, cc)))

proc lazyConcat(colls: seq[Value], i: int, c: Cursor): Value =
  let cur = c
  mkLazy(proc (): Value =
    var cc = cur
    var k = i
    while not hasNext(cc):
      if k >= colls.len: return NilV
      cc = cursor(colls[k]); inc k
    let x = next(cc)
    mkCons(x, lazyConcat(colls, k, cc)))

proc def(name: string, f: proc (args: openArray[Value]): Value {.closure.}) =
  setVar(name, mkFn(name, f))

# ----------------------------------------------------------------- fusion
## A pipeline whose intermediate sequences are syntactic temporaries -- nobody
## named them, so nobody can hold them -- does not need those sequences to
## exist. The compiler proves that and calls in here with the stages passed
## explicitly; the runtime never guesses, because a lazy seq someone named
## memoizes its elements and a consumer cannot tell whether it is shared.
##
## Each base element is pushed through the stages and whatever survives is
## folded, so no chunk, cursor or intermediate seq is built between stages.

type FusedOp* = object
  isMap*: bool     ## map when true, filter when false
  fn*: Value
  keep*: bool      ## filter: keep matches, or drop them

template pushThrough(ops: openArray[FusedOp], x0: Value, emit: untyped) =
  ## Stages arrive outermost-first, so they apply in reverse.
  var it {.inject.} = x0
  var dropped = false
  for k in countdown(ops.len - 1, 0):
    if ops[k].isMap:
      it = call(ops[k].fn, [it])
    elif truthy(call(ops[k].fn, [it])) != ops[k].keep:
      dropped = true
      break
  if not dropped:
    emit

template overBase(base: Value, ops: openArray[FusedOp], emit: untyped) =
  ## A range base generates its integers in the loop rather than being walked,
  ## which is safe because range is pure: recomputing an element cannot be
  ## observed. Any other base is walked normally, so a named lazy source still
  ## realizes and memoizes exactly as it would have.
  let br = rec(base)
  if not br.isNil and br.rk == rkRange:
    var cur = br.lo
    while not (br.bounded and ((br.step > 0 and cur >= br.hi) or
                               (br.step < 0 and cur <= br.hi))):
      pushThrough(ops, mkInt(cur), emit)
      cur += br.step
  else:
    for x in elems(base):
      pushThrough(ops, x, emit)

proc fusedReduce*(f, init: Value, hasInit: bool, base: Value,
                  ops: openArray[FusedOp]): Value =
  var acc = init
  var seeded = hasInit
  overBase(base, ops):
    if seeded: acc = call(f, [acc, it])
    else:
      acc = it
      seeded = true
  if seeded: acc
  elif hasInit: init
  else: call(f, emptyArgs)

proc fusedCount*(base: Value, ops: openArray[FusedOp]): Value =
  var n = 0
  overBase(base, ops):
    discard it
    inc n
  mkInt(n)

proc registerCore*() =
  # ---- arithmetic
  def "+", proc (a: openArray[Value]): Value =
    arith("+", a, 0, proc (x, y: int64): int64 = x + y, proc (x, y: float64): float64 = x + y)
  def "-", proc (a: openArray[Value]): Value =
    arith("-", a, 0, proc (x, y: int64): int64 = x - y, proc (x, y: float64): float64 = x - y)
  def "*", proc (a: openArray[Value]): Value =
    arith("*", a, 1, proc (x, y: int64): int64 = x * y, proc (x, y: float64): float64 = x * y)
  def "/", proc (a: openArray[Value]): Value =
    if isFloaty(a) or a.len == 1:
      arith("/", a, 1, proc (x, y: int64): int64 = x div y, proc (x, y: float64): float64 = x / y)
    else:
      for i in 1 ..< a.len:
        if a[i].kind == kInt and a[i].i == 0: err("Divide by zero")
      arith("/", a, 1, proc (x, y: int64): int64 = x div y, proc (x, y: float64): float64 = x / y)
  def "quot", proc (a: openArray[Value]): Value = mkInt(idiv(intOf(a[0]), intOf(a[1])))
  def "rem", proc (a: openArray[Value]): Value = mkInt(irem(intOf(a[0]), intOf(a[1])))
  def "mod", proc (a: openArray[Value]): Value =
    let x = intOf(a[0]); let y = intOf(a[1])
    var r = irem(x, y)
    if r != 0 and ((r < 0) != (y < 0)): r += y
    mkInt(r)
  def "inc", proc (a: openArray[Value]): Value =
    (if a[0].kind == kFloat: mkFloat(a[0].f + 1.0) else: mkInt(a[0].i + 1))
  def "dec", proc (a: openArray[Value]): Value =
    (if a[0].kind == kFloat: mkFloat(a[0].f - 1.0) else: mkInt(a[0].i - 1))
  def "max", proc (a: openArray[Value]): Value =
    result = a[0]
    for x in a: (if num(x) > num(result): result = x)
  def "min", proc (a: openArray[Value]): Value =
    result = a[0]
    for x in a: (if num(x) < num(result): result = x)
  def "abs", proc (a: openArray[Value]): Value =
    (if a[0].kind == kFloat: mkFloat(abs(a[0].f)) else: mkInt(abs(a[0].i)))
  def "Math/sqrt", proc (a: openArray[Value]): Value = mkFloat(sqrt(num(a[0])))
  def "Math/pow", proc (a: openArray[Value]): Value = mkFloat(pow(num(a[0]), num(a[1])))
  def "rand-int", proc (a: openArray[Value]): Value = mkInt(rand(int(intOf(a[0])) - 1))
  def "double", proc (a: openArray[Value]): Value = mkFloat(num(a[0]))
  def "int", proc (a: openArray[Value]): Value = mkInt(intOf(a[0]))

  # ---- comparison / predicates
  def "=", proc (a: openArray[Value]): Value =
    for i in 0 ..< a.len - 1:
      if not equals(a[i], a[i + 1]): return FalseV
    TrueV
  def "not=", proc (a: openArray[Value]): Value =
    for i in 0 ..< a.len - 1:
      if not equals(a[i], a[i + 1]): return TrueV
    FalseV
  def "<", proc (a: openArray[Value]): Value = cmpChain(a, proc (c: int): bool = c < 0)
  def ">", proc (a: openArray[Value]): Value = cmpChain(a, proc (c: int): bool = c > 0)
  def "<=", proc (a: openArray[Value]): Value = cmpChain(a, proc (c: int): bool = c <= 0)
  def ">=", proc (a: openArray[Value]): Value = cmpChain(a, proc (c: int): bool = c >= 0)
  def "not", proc (a: openArray[Value]): Value = mkBool(not truthy(a[0]))
  def "nil?", proc (a: openArray[Value]): Value = mkBool(a[0].isNil or a[0].kind == kNil)
  def "some?", proc (a: openArray[Value]): Value = mkBool(not (a[0].isNil or a[0].kind == kNil))
  def "true?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kBool and a[0].b)
  def "false?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kBool and not a[0].b)
  def "zero?", proc (a: openArray[Value]): Value = mkBool(num(a[0]) == 0.0)
  def "pos?", proc (a: openArray[Value]): Value = mkBool(num(a[0]) > 0.0)
  def "neg?", proc (a: openArray[Value]): Value = mkBool(num(a[0]) < 0.0)
  def "even?", proc (a: openArray[Value]): Value = mkBool(intOf(a[0]) mod 2 == 0)
  def "odd?", proc (a: openArray[Value]): Value = mkBool(intOf(a[0]) mod 2 != 0)
  def "string?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kStr)
  def "number?", proc (a: openArray[Value]): Value = mkBool(a[0].kind in {kInt, kFloat})
  def "int?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kInt)
  def "keyword?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kKeyword)
  def "symbol?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kSymbol)
  def "vector?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kVector)
  def "list?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kList)
  def "map?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kMap)
  def "set?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kSet)
  def "coll?", proc (a: openArray[Value]): Value =
    mkBool(a[0].kind in {kList, kVector, kMap, kSet})
  def "fn?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kFn)
  def "empty?", proc (a: openArray[Value]): Value = mkBool(seqIsEmpty(a[0]))
  def "contains?", proc (a: openArray[Value]): Value =
    let c = a[0]
    if c.isNil or c.kind == kNil: return FalseV
    case c.kind
    of kMap, kSet: mkBool(mapContains(c.m, a[1]))
    of kVector:
      mkBool(a[1].kind == kInt and a[1].i >= 0 and a[1].i < c.vec.cnt)
    else: FalseV

  # ---- strings / IO
  def "str", proc (a: openArray[Value]): Value =
    var s = ""
    for x in a: s &= str(x)
    mkStr(s)
  def "pr-str", proc (a: openArray[Value]): Value =
    var parts: seq[string] = @[]
    for x in a: parts.add prStr(x)
    mkStr(parts.join(" "))
  def "println", proc (a: openArray[Value]): Value =
    var parts: seq[string] = @[]
    for x in a: parts.add str(x)
    echo parts.join(" ")
    NilV
  def "prn", proc (a: openArray[Value]): Value =
    var parts: seq[string] = @[]
    for x in a: parts.add prStr(x)
    echo parts.join(" ")
    NilV
  def "print", proc (a: openArray[Value]): Value =
    var parts: seq[string] = @[]
    for x in a: parts.add str(x)
    stdout.write parts.join(" ")
    NilV
  def "name", proc (a: openArray[Value]): Value =
    case a[0].kind
    of kKeyword, kSymbol, kStr: mkStr(a[0].s)
    else: err("name expects keyword/symbol/string")
  def "keyword", proc (a: openArray[Value]): Value = mkKeyword(str(a[0]))
  def "symbol", proc (a: openArray[Value]): Value = mkSymbol(str(a[0]))
  def "subs", proc (a: openArray[Value]): Value =
    let s = a[0].s
    let st = int(intOf(a[1]))
    let en = (if a.len > 2: int(intOf(a[2])) else: s.len)
    mkStr(s[st ..< en])
  def "clojure.string/upper-case", proc (a: openArray[Value]): Value = mkStr(a[0].s.toUpperAscii)
  def "clojure.string/lower-case", proc (a: openArray[Value]): Value = mkStr(a[0].s.toLowerAscii)
  def "clojure.string/trim", proc (a: openArray[Value]): Value = mkStr(a[0].s.strip)
  def "clojure.string/split", proc (a: openArray[Value]): Value =
    var r: seq[Value] = @[]
    for piece in a[0].s.split(a[1].s): r.add mkStr(piece)
    mkVector(r)
  def "clojure.string/join", proc (a: openArray[Value]): Value =
    let sep = (if a.len > 1: str(a[0]) else: "")
    let coll = (if a.len > 1: a[1] else: a[0])
    var parts: seq[string] = @[]
    for x in elems(coll): parts.add str(x)
    mkStr(parts.join(sep))
  def "read-line", proc (a: openArray[Value]): Value =
    try: mkStr(stdin.readLine()) except CatchableError: NilV
  def "slurp", proc (a: openArray[Value]): Value = mkStr(readFile(a[0].s))
  def "spit", proc (a: openArray[Value]): Value =
    writeFile(a[0].s, str(a[1])); NilV
  # Host primitive used by the source-level stdlib's now-ms wrapper.
  def "*epoch-time-ms*", proc (a: openArray[Value]): Value = mkInt(int64(epochTime() * 1000))

  # ---- collections
  def "list", proc (a: openArray[Value]): Value = mkList(a)
  def "vector", proc (a: openArray[Value]): Value = mkVector(a)
  def "hash-map", proc (a: openArray[Value]): Value =
    var m = emptyPMap()
    var i = 0
    while i + 1 < a.len:
      m = mapAssoc(m, a[i], a[i + 1]); i += 2
    mkMapOf(m)
  def "hash-set", proc (a: openArray[Value]): Value = mkSet(a)
  def "set", proc (a: openArray[Value]): Value = mkSet(toSeq(a[0]))
  def "vec", proc (a: openArray[Value]): Value = mkVector(toSeq(a[0]))
  def "seq", proc (a: openArray[Value]): Value =
    # does not realize a lazy seq — just asks whether it has a first element
    (if seqIsEmpty(a[0]): NilV else: a[0])
  def "count", proc (a: openArray[Value]): Value =
    if a[0].kind == kNil: return mkInt(0)
    mkInt(count(a[0]))
  def "conj", proc (a: openArray[Value]): Value =
    result = a[0]
    for i in 1 ..< a.len: result = conjOne(result, a[i])
  def "cons", proc (a: openArray[Value]): Value = mkCons(a[0], a[1])
  def "first", proc (a: openArray[Value]): Value =
    if a[0].kind == kVector:
      return (if a[0].vec.cnt == 0: NilV else: vecNth(a[0].vec, 0))
    seqFirst(a[0])
  def "second", proc (a: openArray[Value]): Value = seqFirst(seqRest(a[0]))
  def "last", proc (a: openArray[Value]): Value =
    if a[0].kind == kVector:
      return (if a[0].vec.cnt == 0: NilV else: vecNth(a[0].vec, a[0].vec.cnt - 1))
    result = NilV
    for x in elems(a[0]): result = x
  def "rest", proc (a: openArray[Value]): Value = seqRest(a[0])
  def "next", proc (a: openArray[Value]): Value =
    let r = seqRest(a[0])
    (if seqIsEmpty(r): NilV else: r)
  def "nth", proc (a: openArray[Value]): Value =
    let i = int(intOf(a[1]))
    if a[0].kind == kVector:
      # O(log32 n) straight through the trie, no intermediate seq
      if i >= 0 and i < a[0].vec.cnt: return vecNth(a[0].vec, i)
      if a.len > 2: return a[2]
      err("Index out of bounds: " & $i)
    if i >= 0:
      # walks the seq, realizing no more of it than the index demands
      var k = i
      var c = cursor(a[0])
      while hasNext(c):
        let x = next(c)
        if k == 0: return x
        dec k
    if a.len > 2: a[2]
    else: err("Index out of bounds: " & $i)
  def "get", proc (a: openArray[Value]): Value =
    getIn(a[0], a[1], (if a.len > 2: a[2] else: NilV))
  def "get-in", proc (a: openArray[Value]): Value =
    var cur = a[0]
    for k in toSeq(a[1]):
      cur = getIn(cur, k, NilV)
    (if (cur.isNil or cur.kind == kNil) and a.len > 2: a[2] else: cur)
  def "assoc", proc (a: openArray[Value]): Value =
    result = a[0]
    var i = 1
    while i + 1 < a.len:
      result = assocOne(result, a[i], a[i + 1]); i += 2
  def "dissoc", proc (a: openArray[Value]): Value =
    var m = a[0].m
    for i in 1 ..< a.len: m = mapDissoc(m, a[i])
    mkMapOf(m)
  def "update", proc (a: openArray[Value]): Value =
    let cur = getIn(a[0], a[1], NilV)
    assocOne(a[0], a[1], call(a[2], @[cur] & @(a[3 .. ^1])))
  def "keys", proc (a: openArray[Value]): Value =
    var r: seq[Value] = @[]
    for e in mapEntries(a[0].m): r.add e.key
    (if r.len == 0: NilV else: mkList(r))
  def "vals", proc (a: openArray[Value]): Value =
    var r: seq[Value] = @[]
    for e in mapEntries(a[0].m): r.add e.val
    (if r.len == 0: NilV else: mkList(r))
  def "reverse", proc (a: openArray[Value]): Value =
    let s = toSeq(a[0])
    var r: seq[Value] = @[]
    for i in countdown(s.len - 1, 0): r.add s[i]
    mkList(r)
  def "range", proc (a: openArray[Value]): Value =
    var lo: int64 = 0
    var hi: int64 = 0
    var step: int64 = 1
    if a.len == 1: hi = intOf(a[0])
    elif a.len >= 2:
      lo = intOf(a[0]); hi = intOf(a[1])
      if a.len > 2: step = intOf(a[2])
    # (range) with no bound is infinite; everything else stops at hi
    lazyRange(lo, hi, step, bounded = a.len > 0)
  def "take", proc (a: openArray[Value]): Value =
    lazyTake(int(intOf(a[0])), cursor(a[1]))
  def "drop", proc (a: openArray[Value]): Value =
    lazyDrop(int(intOf(a[0])), cursor(a[1]))
  def "concat", proc (a: openArray[Value]): Value =
    lazyConcat(@a, 0, cursor(NilV))
  def "iterate", proc (a: openArray[Value]): Value = lazyIterate(a[0], a[1])
  def "repeat", proc (a: openArray[Value]): Value =
    (if a.len == 1: lazyRepeat(a[0], 0, bounded = false)
     else: lazyRepeat(a[1], intOf(a[0]), bounded = true))
  def "repeatedly", proc (a: openArray[Value]): Value =
    (if a.len == 1: lazyRepeatedly(a[0], 0, bounded = false)
     else: lazyRepeatedly(a[1], intOf(a[0]), bounded = true))
  def "cycle", proc (a: openArray[Value]): Value = lazyCycle(a[0], cursor(a[0]))
  def "doall", proc (a: openArray[Value]): Value = mkList(toSeq(a[0]))
  def "dorun", proc (a: openArray[Value]): Value =
    for x in elems(a[0]): discard
    NilV
  def "sort", proc (a: openArray[Value]): Value =
    var s = toSeq(a[^1])
    let cmpFn = (if a.len > 1: a[0] else: NilV)
    # insertion sort keeps it simple and stable
    for i in 1 ..< s.len:
      var j = i
      while j > 0:
        let before =
          if cmpFn.kind == kFn: truthy(call(cmpFn, [s[j], s[j - 1]]))
          elif s[j].kind == kStr: s[j].s < s[j - 1].s
          else: num(s[j]) < num(s[j - 1])
        if not before: break
        swap(s[j], s[j - 1]); dec j
    mkList(s)
  def "sort-by", proc (a: openArray[Value]): Value =
    var s = toSeq(a[^1])
    let kf = a[0]
    for i in 1 ..< s.len:
      var j = i
      while j > 0:
        let ka = call(kf, [s[j]])
        let kb = call(kf, [s[j - 1]])
        let before = (if ka.kind == kStr: ka.s < kb.s else: num(ka) < num(kb))
        if not before: break
        swap(s[j], s[j - 1]); dec j
    mkList(s)
  def "distinct", proc (a: openArray[Value]): Value =
    var r: seq[Value] = @[]
    for x in elems(a[0]):
      var dup = false
      for y in r:
        if equals(x, y): dup = true; break
      if not dup: r.add x
    mkList(r)
  def "interpose", proc (a: openArray[Value]): Value =
    var r: seq[Value] = @[]
    for x in elems(a[1]):
      if r.len > 0: r.add a[0]
      r.add x
    mkList(r)
  def "partition", proc (a: openArray[Value]): Value =
    let n = int(intOf(a[0]))
    let s = toSeq(a[^1])
    var r: seq[Value] = @[]
    var i = 0
    while i + n <= s.len:
      r.add mkList(s[i ..< i + n]); i += n
    mkList(r)

  # ---- higher order
  def "apply", proc (a: openArray[Value]): Value =
    var callArgs: seq[Value] = @[]
    for i in 1 ..< a.len - 1: callArgs.add a[i]
    callArgs.add toSeq(a[^1])
    call(a[0], callArgs)
  def "map", proc (a: openArray[Value]): Value =
    if a.len == 2: return lazyMap(a[0], cursor(a[1]))
    var cs: seq[Cursor] = @[]
    for i in 1 ..< a.len: cs.add cursor(a[i])
    lazyMapN(a[0], cs)
  def "mapv", proc (a: openArray[Value]): Value =
    var r: seq[Value] = @[]
    for x in elems(a[1]): r.add call(a[0], [x])
    mkVector(r)
  def "map-indexed", proc (a: openArray[Value]): Value =
    lazyMapIndexed(a[0], 0, cursor(a[1]))
  def "filter", proc (a: openArray[Value]): Value =
    lazyFilter(a[0], cursor(a[1]), keep = true)
  def "remove", proc (a: openArray[Value]): Value =
    lazyFilter(a[0], cursor(a[1]), keep = false)
  def "reduce", proc (a: openArray[Value]): Value =
    ## Streams the source rather than materializing it, so folding a lazy seq
    ## holds one chunk at a time instead of the whole sequence -- and when the
    ## source is a describable pipeline, runs the whole thing as one loop.
    let f = a[0]
    if a.len == 2:
      var acc = NilV
      var first = true
      for x in elems(a[1]):
        if first: acc = x; first = false
        else: acc = call(f, [acc, x])
      if first: return call(f, [])
      return acc
    var acc = a[1]
    for x in elems(a[2]): acc = call(f, [acc, x])
    acc
  def "some", proc (a: openArray[Value]): Value =
    for x in elems(a[1]):
      let r = call(a[0], [x])
      if truthy(r): return r
    NilV
  def "every?", proc (a: openArray[Value]): Value =
    for x in elems(a[1]):
      if not truthy(call(a[0], [x])): return FalseV
    TrueV
  def "take-while", proc (a: openArray[Value]): Value =
    lazyTakeWhile(a[0], cursor(a[1]))
  def "drop-while", proc (a: openArray[Value]): Value =
    lazyDropWhile(a[0], cursor(a[1]))
  def "group-by", proc (a: openArray[Value]): Value =
    var m = emptyPMap()
    for x in elems(a[1]):
      let k = call(a[0], [x])
      m = mapAssoc(m, k, conjOne(mapGet(m, k, mkVector(@[])), x))
    mkMapOf(m)
  def "frequencies", proc (a: openArray[Value]): Value =
    var m = emptyPMap()
    for x in elems(a[0]):
      m = mapAssoc(m, x, mkInt(mapGet(m, x, mkInt(0)).i + 1))
    mkMapOf(m)
  def "identity", proc (a: openArray[Value]): Value = a[0]
  def "comp", proc (a: openArray[Value]): Value =
    let fs = @a
    mkFn("comp", proc (args: openArray[Value]): Value =
      if fs.len == 0: return argAt(args, 0)
      var v = call(fs[^1], args)
      for i in countdown(fs.len - 2, 0): v = call(fs[i], [v])
      v)
  def "partial", proc (a: openArray[Value]): Value =
    let f = a[0]
    let bound = a[1 .. ^1]
    mkFn("partial", proc (args: openArray[Value]): Value = call(f, bound & @args))
  def "juxt", proc (a: openArray[Value]): Value =
    let fs = @a
    mkFn("juxt", proc (args: openArray[Value]): Value =
      var r: seq[Value] = @[]
      for f in fs: r.add call(f, args)
      mkVector(r))
  def "constantly", proc (a: openArray[Value]): Value =
    let v = a[0]
    mkFn("constantly", proc (args: openArray[Value]): Value = v)

  # ---- atoms (mutable boxes, modelled as a 1-slot vector)
  def "atom", proc (a: openArray[Value]): Value =
    var cell = a[0]
    mkFn("atom", proc (args: openArray[Value]): Value =
      # (a)        -> deref
      # (a :set v) -> reset
      if args.len == 0: return cell
      cell = args[1]
      cell)
  def "deref", proc (a: openArray[Value]): Value = call(a[0], [])
  def "reset!", proc (a: openArray[Value]): Value = call(a[0], [mkKeyword("set"), a[1]])
  def "swap!", proc (a: openArray[Value]): Value =
    let cur = call(a[0], [])
    let nv = call(a[1], @[cur] & @(a[2 .. ^1]))
    call(a[0], [mkKeyword("set"), nv])

  def "throw", proc (a: openArray[Value]): Value = err(str(a[0]))
  def "ex-info", proc (a: openArray[Value]): Value = mkStr(str(a[0]))
  def "time-ms", proc (a: openArray[Value]): Value = mkInt(int64(epochTime() * 1000))
