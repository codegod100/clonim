## clonim core — clojure.core builtins, registered into the global var table.
import std/[algorithm, strutils, math, times, random, re, os, httpclient, sequtils, sets,
            tables]
import runtime, reader

var selectedCore: HashSet[string]
var selectingCore = false

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
  of kInt, kChar: v.i
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
  of kObject:
    if objMethod(coll, "valAt").isNil: dflt
    else: objCall(coll, "valAt", [k, dflt])
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
  if selectingCore and name notin selectedCore: return
  setVar(name, mkFn(name, f))

proc def(name: string, v: Value) =
  ## A var whose value is data rather than a function, such as *out*.
  if selectingCore and name notin selectedCore: return
  setVar(name, v)

# ----------------------------------------------------------------- fusion
## A pipeline whose intermediate sequences are syntactic temporaries -- nobody
## named them, so nobody can hold them -- does not need those sequences to
## exist. The compiler proves that and calls in here with the stages passed
## explicitly; the runtime never guesses, because a lazy seq someone named
## memoizes its elements and a consumer cannot tell whether it is shared.
##
## Each base element is pushed through the stages and whatever survives is
## folded, so no chunk, cursor or intermediate seq is built between stages.

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

proc sOf(v: Value): string =
  ## A string argument, checked: reaching into a nil or a number here would
  ## read through a nil object pointer.
  if v.isNil or v.kind != kStr: err("Expected a string, got: " & prStr(v))
  v.s

proc parseIntRadix(s: string, radix: int): int64 =
  ## Java's Integer/Long.parseInt: an optional sign, then digits in `radix`.
  var i = 0
  var neg = false
  if i < s.len and (s[i] == '-' or s[i] == '+'):
    neg = s[i] == '-'; inc i
  if i >= s.len: err("Not a number: " & s)
  while i < s.len:
    let c = toLowerAscii(s[i])
    let d = (if c in '0'..'9': ord(c) - ord('0')
             elif c in 'a'..'z': ord(c) - ord('a') + 10
             else: 99)
    if d >= radix: err("Not a number: " & s)
    result = result * int64(radix) + int64(d)
    inc i
  if neg: result = -result

proc javaFormat(fmt: string, args: openArray[Value]): string =
  ## The subset of java.util.Formatter that shows up in Clojure source:
  ## %s %d %x %X %o %c %f %e %b, with flags "-0+ " and width.precision.
  var ai = 0
  var i = 0
  while i < fmt.len:
    if fmt[i] != '%': result.add fmt[i]; inc i; continue
    inc i
    if i < fmt.len and fmt[i] == '%': result.add '%'; inc i; continue
    var flags = ""
    while i < fmt.len and fmt[i] in {'-', '0', '+', ' ', ',', '#'}:
      flags.add fmt[i]; inc i
    var width = ""
    while i < fmt.len and fmt[i].isDigit: width.add fmt[i]; inc i
    var prec = -1
    if i < fmt.len and fmt[i] == '.':
      inc i
      var p = ""
      while i < fmt.len and fmt[i].isDigit: p.add fmt[i]; inc i
      prec = parseInt(p)
    if i >= fmt.len: err("Bad format string: " & fmt)
    let conv = fmt[i]; inc i
    if ai >= args.len: err("Too few arguments for format string: " & fmt)
    let v = args[ai]; inc ai
    var body: string
    case conv
    of 's', 'S':
      body = str(v)
      if prec >= 0 and body.len > prec: body = body[0 ..< prec]
      if conv == 'S': body = body.toUpperAscii
    of 'd': body = $intOf(v)
    of 'x', 'X':
      body = toHex(intOf(v)).strip(trailing = false, chars = {'0'})
      if body.len == 0: body = "0"
      body = (if conv == 'x': body.toLowerAscii else: body.toUpperAscii)
    of 'o':
      body = toOct(intOf(v), 22).strip(trailing = false, chars = {'0'})
      if body.len == 0: body = "0"
    of 'f': body = formatFloat(num(v), ffDecimal, (if prec < 0: 6 else: prec))
    of 'e', 'E':
      body = formatFloat(num(v), ffScientific, (if prec < 0: 6 else: prec))
      if conv == 'E': body = body.toUpperAscii
    of 'b': body = (if truthy(v): "true" else: "false")
    of 'c': body = str(v)
    of 'n': body = "\n"; dec ai
    else: err("Unsupported format conversion: %" & conv
    )
    let w = (if width.len == 0: 0 else: parseInt(width))
    if body.len < w:
      let pad = w - body.len
      if '-' in flags: body = body & " ".repeat(pad)
      elif '0' in flags and conv in {'d', 'x', 'X', 'o', 'f', 'e', 'E'}:
        if body.len > 0 and body[0] == '-': body = "-" & "0".repeat(pad) & body[1 .. ^1]
        else: body = "0".repeat(pad) & body
      else: body = " ".repeat(pad) & body
    result.add body

proc writeOut(f: File, s: string) =
  ## A closed pipe ends the program quietly, the way a tool killed by SIGPIPE
  ## does, rather than surfacing as an unhandled IOError.
  try:
    f.write(s)
    f.flushFile
  except IOError:
    quit(0)

proc currentOut(): File =
  ## Where print and friends write. `binding` can move it to *err*.
  if hasVar("clojure.core/*out*") and equals(getVar("clojure.core/*out*"), mkKeyword("stderr")):
    stderr
  else:
    stdout

proc registerCoreArithmetic*() =
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
  # ---- bitwise (int64, JVM semantics: shift counts mask to 0..63)
  def "bit-and", proc (a: openArray[Value]): Value =
    result = mkInt(intOf(a[0]))
    for i in 1 ..< a.len: result = mkInt(result.i and intOf(a[i]))
  def "bit-or", proc (a: openArray[Value]): Value =
    result = mkInt(intOf(a[0]))
    for i in 1 ..< a.len: result = mkInt(result.i or intOf(a[i]))
  def "bit-xor", proc (a: openArray[Value]): Value =
    result = mkInt(intOf(a[0]))
    for i in 1 ..< a.len: result = mkInt(result.i xor intOf(a[i]))
  def "bit-and-not", proc (a: openArray[Value]): Value =
    result = mkInt(intOf(a[0]))
    for i in 1 ..< a.len: result = mkInt(result.i and not intOf(a[i]))
  def "bit-not", proc (a: openArray[Value]): Value = mkInt(not intOf(a[0]))
  def "bit-shift-left", proc (a: openArray[Value]): Value =
    mkInt(intOf(a[0]) shl (intOf(a[1]) and 63))
  def "bit-shift-right", proc (a: openArray[Value]): Value =
    # arithmetic: the sign bit is replicated, as on the JVM
    mkInt(ashr(intOf(a[0]), intOf(a[1]) and 63))
  def "unsigned-bit-shift-right", proc (a: openArray[Value]): Value =
    mkInt(cast[int64](cast[uint64](intOf(a[0])) shr uint64(intOf(a[1]) and 63)))
  def "bit-test", proc (a: openArray[Value]): Value =
    mkBool((ashr(intOf(a[0]), intOf(a[1]) and 63) and 1) != 0)
  def "bit-set", proc (a: openArray[Value]): Value =
    mkInt(intOf(a[0]) or (1'i64 shl (intOf(a[1]) and 63)))
  def "bit-clear", proc (a: openArray[Value]): Value =
    mkInt(intOf(a[0]) and not (1'i64 shl (intOf(a[1]) and 63)))
  def "bit-flip", proc (a: openArray[Value]): Value =
    mkInt(intOf(a[0]) xor (1'i64 shl (intOf(a[1]) and 63)))
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
  def "char", proc (a: openArray[Value]): Value =
    (if a[0].kind == kChar: a[0] else: mkChar(intOf(a[0])))
  def "char?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kChar)
  def ".charAt", proc (a: openArray[Value]): Value =
    let i = int(intOf(a[1]))
    if i < 0 or i >= a[0].s.len: err("String index out of range: " & $i)
    mkChar(int64(ord(a[0].s[i])))
  def "Character/isDigit", proc (a: openArray[Value]): Value =
    mkBool(a[0].kind == kChar and a[0].i >= int64(ord('0')) and a[0].i <= int64(ord('9')))
  def "Character/isLetter", proc (a: openArray[Value]): Value =
    mkBool(a[0].kind == kChar and char(a[0].i) in Letters)
  def "Character/isWhitespace", proc (a: openArray[Value]): Value =
    mkBool(a[0].kind == kChar and char(a[0].i) in {' ', '\t', '\n', '\r', '\f', '\v'})
  def "long", proc (a: openArray[Value]): Value = mkInt(intOf(a[0]))
  def "unchecked-int", proc (a: openArray[Value]): Value =
    mkInt(int64(cast[int32](uint32(intOf(a[0]) and 0xffffffff'i64))))
  def "unchecked-byte", proc (a: openArray[Value]): Value =
    mkInt(int64(cast[int8](uint8(intOf(a[0]) and 0xff))))
  def "Math/floor", proc (a: openArray[Value]): Value = mkFloat(floor(num(a[0])))
  def "Math/ceil", proc (a: openArray[Value]): Value = mkFloat(ceil(num(a[0])))
  def "Math/abs", proc (a: openArray[Value]): Value =
    (if a[0].kind == kFloat: mkFloat(abs(a[0].f)) else: mkInt(abs(a[0].i)))
  def "Integer/parseInt", proc (a: openArray[Value]): Value =
    let radix = (if a.len > 1: int(intOf(a[1])) else: 10)
    mkInt(parseIntRadix(a[0].s.strip, radix))
  def "Long/parseLong", proc (a: openArray[Value]): Value =
    let radix = (if a.len > 1: int(intOf(a[1])) else: 10)
    mkInt(parseIntRadix(a[0].s.strip, radix))
  def "Double/parseDouble", proc (a: openArray[Value]): Value =
    try: mkFloat(parseFloat(a[0].s.strip))
    except ValueError: err("Not a number: " & a[0].s)

proc registerCorePredicates*() =
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
    of kObject:
      if objMethod(c, "containsKey").isNil: FalseV
      else: mkBool(truthy(objCall(c, "containsKey", [a[1]])))
    else: FalseV

proc registerCoreStringsIo*() =
  # ---- strings / IO
  def "str", proc (a: openArray[Value]): Value =
    var s = ""
    for x in a: s &= str(x)
    mkStr(s)
  def "pr-str", proc (a: openArray[Value]): Value =
    var parts: seq[string] = @[]
    for x in a: parts.add prStr(x)
    mkStr(parts.join(" "))
  def "*out*", mkKeyword("stdout")
  def "*err*", mkKeyword("stderr")
  def "*in*", mkKeyword("stdin")
  def "*command-line-args*", NilV
  def "println", proc (a: openArray[Value]): Value =
    var parts: seq[string] = @[]
    for x in a: parts.add str(x)
    writeOut(currentOut(), parts.join(" ") & "\n")
    NilV
  def "prn", proc (a: openArray[Value]): Value =
    var parts: seq[string] = @[]
    for x in a: parts.add prStr(x)
    writeOut(currentOut(), parts.join(" ") & "\n")
    NilV
  def "print", proc (a: openArray[Value]): Value =
    var parts: seq[string] = @[]
    for x in a: parts.add str(x)
    writeOut(currentOut(), parts.join(" "))
    NilV
  def "pr", proc (a: openArray[Value]): Value =
    var parts: seq[string] = @[]
    for x in a: parts.add prStr(x)
    writeOut(currentOut(), parts.join(" "))
    NilV
  def "flush", proc (a: openArray[Value]): Value =
    writeOut(currentOut(), ""); NilV
  def "newline", proc (a: openArray[Value]): Value =
    writeOut(currentOut(), "\n"); NilV
  def "name", proc (a: openArray[Value]): Value =
    case a[0].kind
    of kStr: a[0]
    of kKeyword, kSymbol:
      let s = a[0].s
      let i = s.find('/')
      mkStr(if i > 0 and s != "/": s[i + 1 .. ^1] else: s)
    else: err("name expects keyword/symbol/string")
  def "keyword", proc (a: openArray[Value]): Value =
    if a.len > 1:
      return (if a[0].kind == kNil: mkKeyword(str(a[1]))
              else: mkKeyword(str(a[0]) & "/" & str(a[1])))
    case a[0].kind
    of kKeyword: a[0]
    of kNil: NilV
    else: mkKeyword(str(a[0]))
  def "symbol", proc (a: openArray[Value]): Value =
    if a.len > 1:
      return (if a[0].kind == kNil: mkSymbol(str(a[1]))
              else: mkSymbol(str(a[0]) & "/" & str(a[1])))
    (if a[0].kind == kKeyword: mkSymbol(a[0].s) else: mkSymbol(str(a[0])))
  def "subs", proc (a: openArray[Value]): Value =
    let s = sOf(a[0])
    let st = int(intOf(a[1]))
    let en = (if a.len > 2: int(intOf(a[2])) else: s.len)
    mkStr(s[st ..< en])
  def "clojure.string/upper-case", proc (a: openArray[Value]): Value = mkStr(sOf(a[0]).toUpperAscii)
  def "clojure.string/lower-case", proc (a: openArray[Value]): Value = mkStr(sOf(a[0]).toLowerAscii)
  def "clojure.string/trim", proc (a: openArray[Value]): Value = mkStr(sOf(a[0]).strip)
  def "re-find", proc (a: openArray[Value]): Value =
    let pattern = re(sOf(a[0]))
    let start = find(sOf(a[1]), pattern)
    if start < 0: NilV
    else:
      let n = matchLen(sOf(a[1]), pattern, start)
      mkStr(sOf(a[1])[start ..< start + n])
  def "clojure.string/replace", proc (a: openArray[Value]): Value =
    mkStr(sOf(a[0]).replace(re(sOf(a[1])), sOf(a[2])))
  def "clojure.string/split", proc (a: openArray[Value]): Value =
    var r: seq[Value] = @[]
    for piece in sOf(a[0]).split(sOf(a[1])): r.add mkStr(piece)
    mkVector(r)
  def "clojure.string/join", proc (a: openArray[Value]): Value =
    let sep = (if a.len > 1: str(a[0]) else: "")
    let coll = (if a.len > 1: a[1] else: a[0])
    var parts: seq[string] = @[]
    for x in elems(coll): parts.add str(x)
    mkStr(parts.join(sep))
  def "read-line", proc (a: openArray[Value]): Value =
    try: mkStr(stdin.readLine()) except CatchableError: NilV
  def "slurp", proc (a: openArray[Value]): Value =
    (if a[0].kind == kKeyword and a[0].s == "stdin": mkStr(stdin.readAll)
     else: mkStr(readFile(sOf(a[0]))))
  def "spit", proc (a: openArray[Value]): Value =
    writeFile(sOf(a[0]), str(a[1])); NilV
  def "int-array", proc (a: openArray[Value]): Value =
    if a.len == 1 and a[0].kind == kInt: mkList(newSeqWith(int(a[0].i), mkInt(0)))
    elif a.len == 1: mkList(toSeq(a[0])) else: mkList(a)
  def "long-array", proc (a: openArray[Value]): Value =
    if a.len == 1 and a[0].kind == kInt: mkList(newSeqWith(int(a[0].i), mkInt(0)))
    elif a.len == 1: mkList(toSeq(a[0])) else: mkList(a)
  def "byte-array", proc (a: openArray[Value]): Value =
    if a.len == 1: mkList(toSeq(a[0])) else: mkList(a)
  def "alength", proc (a: openArray[Value]): Value = mkInt(count(a[0]))
  def "aget", proc (a: openArray[Value]): Value =
    let i = int(intOf(a[1]))
    if a[0].kind == kList: a[0].obj.xs[i] else: toSeq(a[0])[i]
  def "aset", proc (a: openArray[Value]): Value =
    if a[0].kind != kList: err("aset expects an array")
    a[0].obj.xs[int(intOf(a[1]))] = a[2]; a[2]
  def "System/arraycopy", proc (a: openArray[Value]): Value =
    for i in 0 ..< int(intOf(a[4])):
      a[2].obj.xs[int(intOf(a[3])) + i] = a[0].obj.xs[int(intOf(a[1])) + i]
    NilV
  def ".getBytes", proc (a: openArray[Value]): Value =
    var xs: seq[Value] = @[]
    for ch in sOf(a[0]): xs.add mkInt(ord(ch))
    mkList(xs)
  def "StringBuilder.", proc (a: openArray[Value]): Value =
    ## A mutable string: the one place a string value is written in place.
    mkStr(if a.len > 0: str(a[0]) else: "")
  def ".append", proc (a: openArray[Value]): Value =
    if a[0].kind != kStr: err(".append expects a StringBuilder")
    a[0].obj.s.add(str(a[1]))
    a[0]
  def ".toString", proc (a: openArray[Value]): Value = mkStr(str(a[0]))
  def ".length", proc (a: openArray[Value]): Value = mkInt(int64(sOf(a[0]).len))
  def "*output-stream*", proc (a: openArray[Value]): Value =
    ## A write handle, driven by keyword messages so that it stays an
    ## ordinary value: (o :write bytes) and (o :close).
    let path = sOf(a[0])
    var f: File
    if not f.open(path, fmWrite): err("Cannot open for writing: " & path)
    var closed = false
    mkFn("output-stream", proc (args: openArray[Value]): Value =
      if args.len == 0 or args[0].kind != kKeyword:
        err("output-stream expects a keyword message")
      case args[0].s
      of "write":
        if closed: err("Stream is closed: " & path)
        var bytes = ""
        for x in elems(args[1]): bytes.add char(uint8(intOf(x) and 0xff))
        f.write(bytes)
      of "close":
        if not closed: f.close(); closed = true
      else: err("Unknown stream message: " & prStr(args[0]))
      NilV)
  def ".write", proc (a: openArray[Value]): Value =
    call(a[0], [mkKeyword("write"), a[1]])
  def ".close", proc (a: openArray[Value]): Value =
    (if a[0].kind == kFn: call(a[0], [mkKeyword("close")]) else: NilV)
  def "*delete-file*", proc (a: openArray[Value]): Value =
    try:
      removeFile(sOf(a[0]))
      TrueV
    except OSError:
      if a.len > 1 and truthy(a[1]): FalseV
      else: raise
  def "*http-fetch*", proc (a: openArray[Value]): Value =
    ## Native replacement for the narrow Jolt HTTP API used by Freeqsay.
    try:
      let response = newHttpClient().get(sOf(a[0]))
      writeFile(sOf(a[1]), response.body)
      mkMap(@[(mkKeyword("outcome"), mkKeyword("ok")),
              (mkKeyword("status"), mkInt(response.code.int)),
              (mkKeyword("error"), NilV)])
    except CatchableError as e:
      mkMap(@[(mkKeyword("outcome"), mkKeyword("error")),
              (mkKeyword("status"), mkInt(0)),
              (mkKeyword("error"), mkStr(e.msg))])
  # Host primitive used by the source-level stdlib's now-ms wrapper.
  def "*epoch-time-ms*", proc (a: openArray[Value]): Value = mkInt(int64(epochTime() * 1000))

# ------------------------------------------------------------- comparison
proc splitName(s: string): (string, string, bool) =
  ## (namespace, name, has-namespace) for a keyword or symbol's text.
  let i = s.find('/')
  if i > 0 and s != "/": (s[0 ..< i], s[i + 1 .. ^1], true)
  else: ("", s, false)

proc cmpStr(a, b: string): int =
  ## java.lang.String#compareTo: the first differing char, else the length.
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]: return int(a[i]) - int(b[i])
  a.len - b.len

proc uuidHalves(s: string): (int64, int64) =
  let hex = s.replace("-", "")
  (cast[int64](fromHex[uint64](hex[0 .. 15])), cast[int64](fromHex[uint64](hex[16 .. 31])))

proc compareValues*(a, b: Value): int =
  ## clojure.core/compare: a total order within each comparable type.
  if a.kind == kNil: return (if b.kind == kNil: 0 else: -1)
  if b.kind == kNil: return 1
  if a.kind in {kInt, kFloat} and b.kind in {kInt, kFloat}:
    if a.kind == kInt and b.kind == kInt: return cmp(a.i, b.i)
    return cmp(num(a), num(b))
  if a.kind != b.kind:
    err("Cannot compare " & prStr(a) & " to " & prStr(b))
  case a.kind
  of kBool: cmp(int(a.b), int(b.b))
  of kChar: int(a.i - b.i)
  of kInst: cmp(a.i, b.i)
  of kStr: cmpStr(a.s, b.s)
  of kUuid:
    let (am, al) = uuidHalves(a.s)
    let (bm, bl) = uuidHalves(b.s)
    (if am != bm: cmp(am, bm) else: cmp(al, bl))
  of kKeyword, kSymbol:
    let (an, aname, ahas) = splitName(a.s)
    let (bn, bname, bhas) = splitName(b.s)
    if ahas != bhas: return (if ahas: 1 else: -1)
    if ahas:
      let c = cmpStr(an, bn)
      if c != 0: return c
    cmpStr(aname, bname)
  of kVector:
    if a.vec.cnt != b.vec.cnt: return cmp(a.vec.cnt, b.vec.cnt)
    for i in 0 ..< a.vec.cnt:
      let c = compareValues(vecNth(a.vec, i), vecNth(b.vec, i))
      if c != 0: return c
    0
  of kObject:
    let m = objMethod(a, "compareTo")
    if m.isNil: err("Cannot compare " & prStr(a))
    int(intOf(objCall(a, "compareTo", [b])))
  else: err("Cannot compare " & prStr(a) & " to " & prStr(b))

proc comparatorProc(f: Value): proc (a, b: Value): int =
  ## A Clojure comparator: a fn returning a number, or a boolean "less than"
  ## predicate, which is how Clojure lets (sort > xs) work.
  if f.isNil or f.kind == kNil: return compareValues
  result = proc (a, b: Value): int =
    let r = call(f, [a, b])
    case r.kind
    of kBool:
      if r.b: -1
      elif truthy(call(f, [b, a])): 1
      else: 0
    of kInt: int(clamp(r.i, -1, 1))
    of kFloat: (if r.f < 0: -1 elif r.f > 0: 1 else: 0)
    else: err("Comparator must return a number or boolean")

proc sortedList(xs: seq[Value], cmpF: proc (a, b: Value): int): Value =
  var s = xs
  s.sort(cmpF)            # merge sort: stable, O(n log n)
  mkList(s)

# ---------------------------------------------------------- nested update
proc assocInImpl(m: Value, ks: seq[Value], i: int, v: Value): Value =
  if i == ks.len - 1: return assocOne(m, ks[i], v)
  assocOne(m, ks[i], assocInImpl(getIn(m, ks[i], NilV), ks, i + 1, v))

proc updateInImpl(m: Value, ks: seq[Value], i: int, f: Value,
                  extra: seq[Value]): Value =
  if i == ks.len - 1:
    return assocOne(m, ks[i], call(f, @[getIn(m, ks[i], NilV)] & extra))
  assocOne(m, ks[i], updateInImpl(getIn(m, ks[i], NilV), ks, i + 1, f, extra))

proc flattenInto(v: Value, acc: var seq[Value]) =
  for x in elems(v):
    if x.kind in {kList, kVector, kCons, kChunk, kLazy}: flattenInto(x, acc)
    else: acc.add x

proc setOf(v: Value): PMap =
  if v.isNil or v.kind == kNil: return emptyPMap()
  if v.kind == kSet: return v.m
  var m = emptyPMap()
  for x in elems(v): m = mapAssoc(m, x, x)
  m

proc exInfo(msg: string, data: Value): Value =
  let dataV = data
  let msgV = mkStr(msg)
  var methods = emptyPMap()
  methods = mapAssoc(methods, mkStr("getMessage"),
    mkFn("getMessage", proc (a: openArray[Value]): Value = msgV))
  methods = mapAssoc(methods, mkStr("getData"),
    mkFn("getData", proc (a: openArray[Value]): Value = dataV))
  methods = mapAssoc(methods, mkStr("toString"),
    mkFn("toString", proc (a: openArray[Value]): Value =
      mkStr("clojure.lang.ExceptionInfo: " & msg & " " & prStr(dataV))))
  mkObject("clojure.lang.ExceptionInfo", mkMapOf(methods))

proc randomUuidStr(): string =
  var bytes: array[16, int]
  for i in 0 ..< 16: bytes[i] = rand(255)
  bytes[6] = (bytes[6] and 0x0f) or 0x40
  bytes[8] = (bytes[8] and 0x3f) or 0x80
  for i, b in bytes:
    if i in [4, 6, 8, 10]: result.add '-'
    result.add toHex(b, 2).toLowerAscii

proc ednTagFn(opts: Value): TagFn =
  if opts.kind != kMap: return nil
  let readers = mapGet(opts.m, mkKeyword("readers"), NilV)
  let dflt = mapGet(opts.m, mkKeyword("default"), NilV)
  result = proc (tag: string, form: Value): Value =
    if readers.kind == kMap:
      let f = mapGet(readers.m, mkSymbol(tag), NilV)
      if not f.isNil and f.kind != kNil: return call(f, [form])
    if not dflt.isNil and dflt.kind != kNil:
      return call(dflt, [mkSymbol(tag), form])
    err("No reader function for tag " & tag)

proc registerCoreData() =
  def "compare", proc (a: openArray[Value]): Value =
    mkInt(compareValues(a[0], a[1]))
  def "sort", proc (a: openArray[Value]): Value =
    sortedList(toSeq(a[^1]), comparatorProc(if a.len > 1: a[0] else: NilV))
  def "sort-by", proc (a: openArray[Value]): Value =
    let kf = a[0]
    let c = comparatorProc(if a.len > 2: a[1] else: NilV)
    sortedList(toSeq(a[^1]), proc (x, y: Value): int =
      c(call(kf, [x]), call(kf, [y])))
  def "distinct", proc (a: openArray[Value]): Value =
    var seen = emptyPMap()
    var r: seq[Value] = @[]
    for x in elems(a[0]):
      if not mapContains(seen, x):
        seen = mapAssoc(seen, x, x)
        r.add x
    mkList(r)
  def "keys", proc (a: openArray[Value]): Value =
    var r: seq[Value] = @[]
    if a[0].kind == kMap:
      for e in mapEntries(a[0].m): r.add e.key
    else:
      for e in elems(a[0]): r.add seqFirst(e)
    (if r.len == 0: NilV else: mkList(r))
  def "vals", proc (a: openArray[Value]): Value =
    var r: seq[Value] = @[]
    if a[0].kind == kMap:
      for e in mapEntries(a[0].m): r.add e.val
    else:
      for e in elems(a[0]): r.add seqFirst(seqRest(e))
    (if r.len == 0: NilV else: mkList(r))
  def "merge", proc (a: openArray[Value]): Value =
    result = NilV
    for m in a:
      if m.kind == kNil: continue
      result = (if result.kind == kNil: m else: conjOne(result, m))
  def "merge-with", proc (a: openArray[Value]): Value =
    let f = a[0]
    result = NilV
    for i in 1 ..< a.len:
      let m = a[i]
      if m.kind == kNil: continue
      if result.kind == kNil: result = m; continue
      var acc = result.m
      for e in mapEntries(m.m):
        if mapContains(acc, e.key):
          acc = mapAssoc(acc, e.key, call(f, [mapGet(acc, e.key, NilV), e.val]))
        else: acc = mapAssoc(acc, e.key, e.val)
      result = mkMapOf(acc)
  def "zipmap", proc (a: openArray[Value]): Value =
    var m = emptyPMap()
    var ck = cursor(a[0])
    var cv = cursor(a[1])
    while hasNext(ck) and hasNext(cv):
      let k = next(ck)
      m = mapAssoc(m, k, next(cv))
    mkMapOf(m)
  def "select-keys", proc (a: openArray[Value]): Value =
    var m = emptyPMap()
    if a[0].kind == kMap:
      for k in elems(a[1]):
        if mapContains(a[0].m, k): m = mapAssoc(m, k, mapGet(a[0].m, k, NilV))
    mkMapOf(m)
  def "disj", proc (a: openArray[Value]): Value =
    if a[0].kind == kNil: return NilV
    var m = a[0].m
    for i in 1 ..< a.len: m = mapDissoc(m, a[i])
    mkSetOf(m)
  def "dissoc", proc (a: openArray[Value]): Value =
    if a[0].kind == kNil: return NilV
    var m = a[0].m
    for i in 1 ..< a.len: m = mapDissoc(m, a[i])
    mkMapOf(m)
  def "find", proc (a: openArray[Value]): Value =
    if a[0].kind == kMap and mapContains(a[0].m, a[1]):
      mkVector(@[a[1], mapGet(a[0].m, a[1], NilV)])
    else: NilV
  def "key", proc (a: openArray[Value]): Value = seqFirst(a[0])
  def "val", proc (a: openArray[Value]): Value = seqFirst(seqRest(a[0]))
  def "not-empty", proc (a: openArray[Value]): Value =
    (if seqIsEmpty(a[0]): NilV else: a[0])
  def "empty", proc (a: openArray[Value]): Value =
    case a[0].kind
    of kMap: mkMapOf(emptyPMap())
    of kSet: mkSetOf(emptyPMap())
    of kVector: mkVector(newSeq[Value]())
    of kNil: NilV
    else: mkList(newSeq[Value]())
  def "peek", proc (a: openArray[Value]): Value =
    case a[0].kind
    of kVector: (if a[0].vec.cnt == 0: NilV else: vecNth(a[0].vec, a[0].vec.cnt - 1))
    of kNil: NilV
    else: seqFirst(a[0])
  def "pop", proc (a: openArray[Value]): Value =
    case a[0].kind
    of kVector:
      if a[0].vec.cnt == 0: err("Can't pop empty vector")
      let xs = vecToSeq(a[0].vec)
      mkVector(xs[0 ..< xs.len - 1])
    of kNil: NilV
    else: seqRest(a[0])
  def "subvec", proc (a: openArray[Value]): Value =
    let xs = vecToSeq(a[0].vec)
    let st = int(intOf(a[1]))
    let en = (if a.len > 2: int(intOf(a[2])) else: xs.len)
    if st < 0 or en > xs.len or st > en: err("Index out of bounds")
    mkVector(xs[st ..< en])
  def "assoc-in", proc (a: openArray[Value]): Value =
    let ks = toSeq(a[1])
    if ks.len == 0: return assocOne(a[0], NilV, a[2])
    assocInImpl(a[0], ks, 0, a[2])
  def "update-in", proc (a: openArray[Value]): Value =
    let ks = toSeq(a[1])
    updateInImpl(a[0], ks, 0, a[2], @(a[3 .. ^1]))
  def "keep", proc (a: openArray[Value]): Value =
    var r: seq[Value] = @[]
    for x in elems(a[1]):
      let y = call(a[0], [x])
      if y.kind != kNil: r.add y
    mkList(r)
  def "max-key", proc (a: openArray[Value]): Value =
    result = a[1]
    var best = num(call(a[0], [a[1]]))
    for i in 2 ..< a.len:
      let k = num(call(a[0], [a[i]]))
      if k >= best: best = k; result = a[i]
  def "min-key", proc (a: openArray[Value]): Value =
    result = a[1]
    var best = num(call(a[0], [a[1]]))
    for i in 2 ..< a.len:
      let k = num(call(a[0], [a[i]]))
      if k <= best: best = k; result = a[i]
  def "ffirst", proc (a: openArray[Value]): Value = seqFirst(seqFirst(a[0]))
  def "fnext", proc (a: openArray[Value]): Value = seqFirst(seqRest(a[0]))
  def "nfirst", proc (a: openArray[Value]): Value =
    let r = seqRest(seqFirst(a[0]))
    (if seqIsEmpty(r): NilV else: r)
  def "nnext", proc (a: openArray[Value]): Value =
    let r = seqRest(seqRest(a[0]))
    (if seqIsEmpty(r): NilV else: r)
  def "nthnext", proc (a: openArray[Value]): Value =
    seqDropOrNil(a[0], int(intOf(a[1])))
  def "butlast", proc (a: openArray[Value]): Value =
    let xs = toSeq(a[0])
    (if xs.len <= 1: NilV else: mkList(xs[0 ..< xs.len - 1]))
  def "take-last", proc (a: openArray[Value]): Value =
    let xs = toSeq(a[1])
    let n = int(intOf(a[0]))
    (if xs.len == 0 or n <= 0: NilV else: mkList(xs[max(0, xs.len - n) .. ^1]))
  def "list*", proc (a: openArray[Value]): Value =
    var xs: seq[Value] = @[]
    for i in 0 ..< a.len - 1: xs.add a[i]
    for x in elems(a[^1]): xs.add x
    (if xs.len == 0: NilV else: mkList(xs))
  def "reduce-kv", proc (a: openArray[Value]): Value =
    result = a[1]
    if a[2].kind == kMap:
      for e in mapEntries(a[2].m): result = call(a[0], [result, e.key, e.val])
    elif a[2].kind == kVector:
      for i, x in vecToSeq(a[2].vec): result = call(a[0], [result, mkInt(i), x])
  def "run!", proc (a: openArray[Value]): Value =
    for x in elems(a[1]): discard call(a[0], [x])
    NilV
  def "interleave", proc (a: openArray[Value]): Value =
    var cs: seq[Cursor] = @[]
    for c in a: cs.add cursor(c)
    var r: seq[Value] = @[]
    block outer:
      while true:
        var row: seq[Value] = @[]
        for i in 0 ..< cs.len:
          if not hasNext(cs[i]): break outer
          row.add next(cs[i])
        r.add row
    mkList(r)
  def "flatten", proc (a: openArray[Value]): Value =
    var r: seq[Value] = @[]
    if a[0].kind in {kList, kVector, kCons, kChunk, kLazy}: flattenInto(a[0], r)
    mkList(r)
  def "hash", proc (a: openArray[Value]): Value = mkInt(int64(hashValue(a[0])))
  def "identical?", proc (a: openArray[Value]): Value =
    if a[0].kind != a[1].kind: return FalseV
    if a[0].obj.isNil: mkBool(a[0].raw == a[1].raw)
    else: mkBool(a[0].obj == a[1].obj)
  def "complement", proc (a: openArray[Value]): Value =
    let f = a[0]
    mkFn("complement", proc (args: openArray[Value]): Value =
      mkBool(not truthy(call(f, args))))
  def "fnil", proc (a: openArray[Value]): Value =
    let f = a[0]
    let dflts = @(a[1 .. ^1])
    mkFn("fnil", proc (args: openArray[Value]): Value =
      var xs = @args
      for i in 0 ..< min(xs.len, dflts.len):
        if xs[i].kind == kNil: xs[i] = dflts[i]
      call(f, xs))
  def "memoize", proc (a: openArray[Value]): Value =
    let f = a[0]
    var cache = emptyPMap()
    mkFn("memoize", proc (args: openArray[Value]): Value =
      let k = mkVector(@args)
      if mapContains(cache, k): return mapGet(cache, k, NilV)
      result = call(f, args)
      cache = mapAssoc(cache, k, result))
  def "sequential?", proc (a: openArray[Value]): Value =
    mkBool(a[0].kind in {kList, kVector, kCons, kChunk, kLazy})
  def "seqable?", proc (a: openArray[Value]): Value =
    mkBool(a[0].kind in {kNil, kList, kVector, kMap, kSet, kStr, kCons, kChunk, kLazy} or
           not objMethod(a[0], "seq").isNil)
  def "integer?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kInt)
  def "boolean?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kBool)
  def "double?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kFloat)
  def "ident?", proc (a: openArray[Value]): Value = mkBool(a[0].kind in {kKeyword, kSymbol})
  def "qualified-keyword?", proc (a: openArray[Value]): Value =
    mkBool(a[0].kind == kKeyword and splitName(a[0].s)[2])
  def "simple-keyword?", proc (a: openArray[Value]): Value =
    mkBool(a[0].kind == kKeyword and not splitName(a[0].s)[2])
  def "namespace", proc (a: openArray[Value]): Value =
    if a[0].kind notin {kKeyword, kSymbol}: err("namespace expects a keyword or symbol")
    let (ns, _, has) = splitName(a[0].s)
    (if has: mkStr(ns) else: NilV)
  # ---- clojure.set
  def "clojure.set/union", proc (a: openArray[Value]): Value =
    var m = emptyPMap()
    for s in a:
      for x in elems(s): m = mapAssoc(m, x, x)
    mkSetOf(m)
  def "clojure.set/intersection", proc (a: openArray[Value]): Value =
    var m = setOf(a[0])
    for i in 1 ..< a.len:
      let other = setOf(a[i])
      for e in mapEntries(m):
        if not mapContains(other, e.key): m = mapDissoc(m, e.key)
    mkSetOf(m)
  def "clojure.set/difference", proc (a: openArray[Value]): Value =
    var m = setOf(a[0])
    for i in 1 ..< a.len:
      for x in elems(a[i]): m = mapDissoc(m, x)
    mkSetOf(m)
  def "clojure.set/subset?", proc (a: openArray[Value]): Value =
    let b = setOf(a[1])
    for x in elems(a[0]):
      if not mapContains(b, x): return FalseV
    TrueV
  def "clojure.set/superset?", proc (a: openArray[Value]): Value =
    let b = setOf(a[0])
    for x in elems(a[1]):
      if not mapContains(b, x): return FalseV
    TrueV
  def "clojure.set/select", proc (a: openArray[Value]): Value =
    var m = emptyPMap()
    for x in elems(a[1]):
      if truthy(call(a[0], [x])): m = mapAssoc(m, x, x)
    mkSetOf(m)
  def "clojure.set/map-invert", proc (a: openArray[Value]): Value =
    var m = emptyPMap()
    for e in mapEntries(a[0].m): m = mapAssoc(m, e.val, e.key)
    mkMapOf(m)
  # ---- instants and uuids
  def "inst?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kInst)
  def "inst-ms", proc (a: openArray[Value]): Value =
    if a[0].kind != kInst: err("inst-ms expects an instant")
    mkInt(a[0].i)
  def "java.util.Date.", proc (a: openArray[Value]): Value =
    (if a.len == 0: mkInst(int64(epochTime() * 1000)) else: mkInst(intOf(a[0])))
  def "uuid?", proc (a: openArray[Value]): Value = mkBool(a[0].kind == kUuid)
  def "parse-uuid", proc (a: openArray[Value]): Value =
    (if validUuid(sOf(a[0])): mkUuid(sOf(a[0])) else: NilV)
  def "random-uuid", proc (a: openArray[Value]): Value = mkUuid(randomUuidStr())
  def "java.util.UUID/randomUUID", proc (a: openArray[Value]): Value =
    mkUuid(randomUuidStr())
  def "java.util.UUID/fromString", proc (a: openArray[Value]): Value =
    if not validUuid(sOf(a[0])): err("Invalid UUID string: " & sOf(a[0]))
    mkUuid(sOf(a[0]))
  # ---- reading data
  def "read-string", proc (a: openArray[Value]): Value =
    if a.len > 1: readOne(sOf(a[1]), ednTagFn(a[0]))
    else: readOne(sOf(a[0]))
  def "clojure.edn/read-string", proc (a: openArray[Value]): Value =
    let opts = (if a.len > 1: a[0] else: NilV)
    let src = (if a.len > 1: a[1] else: a[0])
    if src.kind == kNil: return NilV
    let eofV = (if opts.kind == kMap: mapGet(opts.m, mkKeyword("eof"), NilV) else: NilV)
    let hasEof = opts.kind == kMap and mapContains(opts.m, mkKeyword("eof"))
    readOne(sOf(src), ednTagFn(opts), eofV, not hasEof)
  # ---- objects
  def "clonim.rt/make-object", proc (a: openArray[Value]): Value =
    mkObject(sOf(a[0]), a[1])
  def "clonim.rt/invoke-method", proc (a: openArray[Value]): Value =
    ## (. obj method args...) on a reify/deftype instance.
    objCall(a[0], sOf(a[1]), a[2 .. ^1])
  def "clonim.rt/object-type", proc (a: openArray[Value]): Value =
    (if a[0].kind == kObject: mkStr(a[0].obj.otype) else: NilV)

proc registerCoreCollections*() =
  registerCoreData()
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
  def "update", proc (a: openArray[Value]): Value =
    let cur = getIn(a[0], a[1], NilV)
    assocOne(a[0], a[1], call(a[2], @[cur] & @(a[3 .. ^1])))
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

  def "partition-all", proc (a: openArray[Value]): Value =
    let n = int(intOf(a[0]))
    let step = (if a.len > 2: int(intOf(a[1])) else: n)
    let s = toSeq(a[^1])
    var r: seq[Value] = @[]
    var i = 0
    while i < s.len:
      r.add mkList(s[i ..< min(i + n, s.len)]); i += step
    mkList(r)
  def "partition-by", proc (a: openArray[Value]): Value =
    let s = toSeq(a[1])
    var r: seq[Value] = @[]
    var run: seq[Value] = @[]
    var key = NilV
    for x in s:
      let k = call(a[0], [x])
      if run.len == 0 or equals(k, key): run.add x
      else:
        r.add mkList(run); run = @[x]
      key = k
    if run.len > 0: r.add mkList(run)
    mkList(r)
  def "into", proc (a: openArray[Value]): Value =
    result = a[0]
    if a.len > 1:
      for x in elems(a[1]): result = conjOne(result, x)
  def "mapcat", proc (a: openArray[Value]): Value =
    ## Like map, then concat: the fn takes one element from each collection.
    var colls: seq[seq[Value]] = @[]
    for i in 1 ..< a.len: colls.add toSeq(a[i])
    var n = -1
    for c in colls: (if n < 0 or c.len < n: n = c.len)
    var r: seq[Value] = @[]
    for i in 0 ..< max(n, 0):
      var args: seq[Value] = @[]
      for c in colls: args.add c[i]
      for x in elems(call(a[0], args)): r.add x
    mkList(r)

proc registerCoreHigherOrder*() =
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

proc registerCoreStateHost*() =
  # ---- atoms (mutable boxes, modelled as a 1-slot vector)
  def "atom", proc (a: openArray[Value]): Value =
    var cell = a[0]
    mkFn("atom", proc (args: openArray[Value]): Value =
      # (a)        -> deref
      # (a :set v) -> reset
      if args.len == 0: return cell
      cell = args[1]
      cell)
  # ---- agents (cooperative, serialized state transitions)
  def "agent", proc (a: openArray[Value]): Value = mkAgent(a[0])
  def "send", proc (a: openArray[Value]): Value =
    if a.len < 2: err("send expects an agent and an action")
    agentSend(a[0], a[1], a[2 .. ^1])
  def "await", proc (a: openArray[Value]): Value = agentAwait(a)
  def "agent-error", proc (a: openArray[Value]): Value = agentError(a[0])
  def "restart-agent", proc (a: openArray[Value]): Value = restartAgent(a[0], a[1])
  def "deref", proc (a: openArray[Value]): Value =
    if a[0].kind == kAgent: agentDeref(a[0])
    elif a[0].kind == kObject: objCall(a[0], "deref", [])
    else: call(a[0], [])
  def "reset!", proc (a: openArray[Value]): Value = call(a[0], [mkKeyword("set"), a[1]])
  def "swap!", proc (a: openArray[Value]): Value =
    let cur = call(a[0], [])
    let nv = call(a[1], @[cur] & @(a[2 .. ^1]))
    call(a[0], [mkKeyword("set"), nv])

  def "ex-message", proc (a: openArray[Value]): Value =
    ## A thrown string reaches a catch clause as itself; ex-info as an object.
    if a[0].kind == kStr: a[0]
    elif not objMethod(a[0], "getMessage").isNil: objCall(a[0], "getMessage", [])
    else: NilV
  def "ex-data", proc (a: openArray[Value]): Value =
    (if objMethod(a[0], "getData").isNil: NilV else: objCall(a[0], "getData", []))
  def "volatile!", proc (a: openArray[Value]): Value =
    var cell = a[0]
    mkFn("volatile", proc (args: openArray[Value]): Value =
      if args.len == 0: return cell
      cell = args[1]
      cell)
  def "vreset!", proc (a: openArray[Value]): Value =
    call(a[0], [mkKeyword("set"), a[1]])
  def "vswap!", proc (a: openArray[Value]): Value =
    let cur = call(a[0], [])
    call(a[0], [mkKeyword("set"), call(a[1], @[cur] & @(a[2 .. ^1]))])
  def "boolean", proc (a: openArray[Value]): Value = mkBool(truthy(a[0]))
  def "class", proc (a: openArray[Value]): Value = mkKeyword($a[0].kind)
  def "instance?", proc (a: openArray[Value]): Value =
    if a[1].kind == kObject:
      return mkBool(a[0].kind in {kKeyword, kStr, kSymbol} and a[0].s == a[1].obj.otype)
    mkBool(a[0].kind == kKeyword and a[0].s == $a[1].kind)
  def "format", proc (a: openArray[Value]): Value = mkStr(javaFormat(sOf(a[0]), a[1 .. ^1]))
  def "System/exit", proc (a: openArray[Value]): Value =
    quit(if a.len > 0: int(intOf(a[0])) else: 0)
  def "System/currentTimeMillis", proc (a: openArray[Value]): Value =
    mkInt(int64(epochTime() * 1000))
  def "System/getProperty", proc (a: openArray[Value]): Value =
    ## Only the properties a hosted program can reasonably expect here.
    case sOf(a[0])
    of "java.io.tmpdir": mkStr(getTempDir().strip(leading = false, chars = {'/'}))
    of "user.dir": mkStr(getCurrentDir())
    of "user.name": mkStr(getEnv("USER"))
    of "line.separator": mkStr("\n")
    else: (if a.len > 1: a[1] else: NilV)
  def "clojure.string/blank?", proc (a: openArray[Value]): Value =
    mkBool(a[0].kind == kNil or sOf(a[0]).strip.len == 0)
  def "clojure.string/starts-with?", proc (a: openArray[Value]): Value =
    mkBool(sOf(a[0]).startsWith(sOf(a[1])))
  def "clojure.string/ends-with?", proc (a: openArray[Value]): Value =
    mkBool(sOf(a[0]).endsWith(sOf(a[1])))
  def "clojure.string/includes?", proc (a: openArray[Value]): Value =
    mkBool(sOf(a[1]) in sOf(a[0]))
  def "clojure.string/index-of", proc (a: openArray[Value]): Value =
    let i = sOf(a[0]).find(sOf(a[1]))
    (if i < 0: NilV else: mkInt(int64(i)))
  def "throw", proc (a: openArray[Value]): Value =
    if a[0].kind == kObject and not objMethod(a[0], "getMessage").isNil:
      throwValue(str(objCall(a[0], "getMessage", [])), a[0])
    err(str(a[0]))
  def "ex-info", proc (a: openArray[Value]): Value =
    exInfo(str(a[0]), (if a.len > 1: a[1] else: mkMapOf(emptyPMap())))
  def "time-ms", proc (a: openArray[Value]): Value = mkInt(int64(epochTime() * 1000))

proc aliasSelectedCore(names: openArray[string]) =
  for name in names:
    if (name == "/" or '/' notin name) and hasVar(name):
      globals["clojure.core/" & name] = varCell(name)

template registerSelected(names: openArray[string], body: untyped) =
  selectedCore = initHashSet[string]()
  for name in names: selectedCore.incl name
  selectingCore = true
  try:
    body
  finally:
    selectingCore = false
  aliasSelectedCore(names)

proc registerCoreArithmeticSelected*(names: openArray[string]) =
  registerSelected(names): registerCoreArithmetic()
proc registerCorePredicatesSelected*(names: openArray[string]) =
  registerSelected(names): registerCorePredicates()
proc registerCoreStringsIoSelected*(names: openArray[string]) =
  registerSelected(names): registerCoreStringsIo()
proc registerCoreCollectionsSelected*(names: openArray[string]) =
  registerSelected(names): registerCoreCollections()
proc registerCoreHigherOrderSelected*(names: openArray[string]) =
  registerSelected(names): registerCoreHigherOrder()
proc registerCoreStateHostSelected*(names: openArray[string]) =
  registerSelected(names): registerCoreStateHost()

proc registerCore*() =
  registerCoreArithmetic()
  registerCorePredicates()
  registerCoreStringsIo()
  registerCoreCollections()
  registerCoreHigherOrder()
  registerCoreStateHost()

proc registerCoreSelected*(names: openArray[string]) =
  ## Register only the statically reachable core vars in a generated program.
  ## Qualified clojure.core names share their unqualified cell, preserving the
  ## rebinding semantics of the full registry.
  selectedCore = initHashSet[string]()
  for name in names: selectedCore.incl name
  selectingCore = true
  try:
    registerCore()
  finally:
    selectingCore = false
  aliasSelectedCore(names)

proc coreRegistrationGroups*(names: openArray[string]): HashSet[int] =
  ## Used by the compiler process to discover which independently linked core
  ## registration families contain the resolved vars in a program.
  let saved = globals
  for group in 0 .. 5:
    globals = initTable[string, VarCell]()
    case group
    of 0: registerCoreArithmetic()
    of 1: registerCorePredicates()
    of 2: registerCoreStringsIo()
    of 3: registerCoreCollections()
    of 4: registerCoreHigherOrder()
    else: registerCoreStateHost()
    for name in names:
      if hasVar(name): result.incl group
  globals = saved
