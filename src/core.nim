## clonim core — clojure.core builtins, registered into the global var table.
import std/[strutils, math, times, random]
import runtime

proc num(v: Value): float64 =
  case v.kind
  of kInt: float64(v.i)
  of kFloat: v.f
  else: err("Not a number: " & prStr(v))

proc isFloaty(vs: seq[Value]): bool =
  for v in vs:
    if v.kind == kFloat: return true
  false

proc intOf(v: Value): int64 =
  case v.kind
  of kInt: v.i
  of kFloat: int64(v.f)
  else: err("Not a number: " & prStr(v))

proc arith(name: string, args: seq[Value], unit: int64,
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

proc cmpChain(args: seq[Value], ok: proc (c: int): bool): Value =
  for i in 0 ..< args.len - 1:
    let a = num(args[i])
    let b = num(args[i + 1])
    let c = (if a < b: -1 elif a > b: 1 else: 0)
    if not ok(c): return FalseV
  TrueV

proc getIn(coll, k, dflt: Value): Value =
  if coll.isNil or coll.kind == kNil: return dflt
  case coll.kind
  of kMap:
    for (kk, vv) in coll.pairs:
      if equals(kk, k): return vv
    dflt
  of kVector, kList:
    if k.kind != kInt: return dflt
    let i = int(k.i)
    if i < 0 or i >= coll.items.len: dflt else: coll.items[i]
  of kSet:
    for x in coll.items:
      if equals(x, k): return x
    dflt
  of kStr:
    if k.kind != kInt: return dflt
    let i = int(k.i)
    if i < 0 or i >= coll.s.len: dflt else: mkStr($coll.s[i])
  else: dflt

proc assocOne(coll, k, v: Value): Value =
  if coll.isNil or coll.kind == kNil:
    return Value(kind: kMap, pairs: @[(k, v)])
  case coll.kind
  of kMap:
    var ps = coll.pairs
    for i in 0 ..< ps.len:
      if equals(ps[i][0], k):
        ps[i] = (k, v)
        return Value(kind: kMap, pairs: ps)
    ps.add (k, v)
    Value(kind: kMap, pairs: ps)
  of kVector:
    if k.kind != kInt: err("Vector index must be an integer")
    var xs = coll.items
    let i = int(k.i)
    if i == xs.len: xs.add v
    elif i >= 0 and i < xs.len: xs[i] = v
    else: err("Index out of bounds: " & $i)
    mkVector(xs)
  else: err("assoc not supported on " & prStr(coll))

proc conjOne(coll, x: Value): Value =
  if coll.isNil or coll.kind == kNil: return mkList(@[x])
  case coll.kind
  of kVector: mkVector(coll.items & @[x])
  of kList: mkList(@[x] & coll.items)
  of kSet: mkSet(coll.items & @[x])
  of kMap:
    if x.kind in {kVector, kList} and x.items.len == 2:
      assocOne(coll, x.items[0], x.items[1])
    elif x.kind == kMap:
      var m = coll
      for (k, v) in x.pairs: m = assocOne(m, k, v)
      m
    else: err("conj on map needs a pair")
  else: err("conj not supported on " & prStr(coll))

proc def(name: string, f: proc (args: seq[Value]): Value {.closure.}) =
  setVar(name, mkFn(name, f))

proc registerCore*() =
  # ---- arithmetic
  def "+", proc (a: seq[Value]): Value =
    arith("+", a, 0, proc (x, y: int64): int64 = x + y, proc (x, y: float64): float64 = x + y)
  def "-", proc (a: seq[Value]): Value =
    arith("-", a, 0, proc (x, y: int64): int64 = x - y, proc (x, y: float64): float64 = x - y)
  def "*", proc (a: seq[Value]): Value =
    arith("*", a, 1, proc (x, y: int64): int64 = x * y, proc (x, y: float64): float64 = x * y)
  def "/", proc (a: seq[Value]): Value =
    if isFloaty(a) or a.len == 1:
      arith("/", a, 1, proc (x, y: int64): int64 = x div y, proc (x, y: float64): float64 = x / y)
    else:
      for i in 1 ..< a.len:
        if a[i].kind == kInt and a[i].i == 0: err("Divide by zero")
      arith("/", a, 1, proc (x, y: int64): int64 = x div y, proc (x, y: float64): float64 = x / y)
  def "quot", proc (a: seq[Value]): Value = mkInt(intOf(a[0]) div intOf(a[1]))
  def "rem", proc (a: seq[Value]): Value = mkInt(intOf(a[0]) mod intOf(a[1]))
  def "mod", proc (a: seq[Value]): Value =
    let x = intOf(a[0]); let y = intOf(a[1])
    var r = x mod y
    if r != 0 and ((r < 0) != (y < 0)): r += y
    mkInt(r)
  def "inc", proc (a: seq[Value]): Value =
    (if a[0].kind == kFloat: mkFloat(a[0].f + 1.0) else: mkInt(a[0].i + 1))
  def "dec", proc (a: seq[Value]): Value =
    (if a[0].kind == kFloat: mkFloat(a[0].f - 1.0) else: mkInt(a[0].i - 1))
  def "max", proc (a: seq[Value]): Value =
    result = a[0]
    for x in a: (if num(x) > num(result): result = x)
  def "min", proc (a: seq[Value]): Value =
    result = a[0]
    for x in a: (if num(x) < num(result): result = x)
  def "abs", proc (a: seq[Value]): Value =
    (if a[0].kind == kFloat: mkFloat(abs(a[0].f)) else: mkInt(abs(a[0].i)))
  def "Math/sqrt", proc (a: seq[Value]): Value = mkFloat(sqrt(num(a[0])))
  def "Math/pow", proc (a: seq[Value]): Value = mkFloat(pow(num(a[0]), num(a[1])))
  def "rand-int", proc (a: seq[Value]): Value = mkInt(rand(int(intOf(a[0])) - 1))
  def "double", proc (a: seq[Value]): Value = mkFloat(num(a[0]))
  def "int", proc (a: seq[Value]): Value = mkInt(intOf(a[0]))

  # ---- comparison / predicates
  def "=", proc (a: seq[Value]): Value =
    for i in 0 ..< a.len - 1:
      if not equals(a[i], a[i + 1]): return FalseV
    TrueV
  def "not=", proc (a: seq[Value]): Value =
    for i in 0 ..< a.len - 1:
      if not equals(a[i], a[i + 1]): return TrueV
    FalseV
  def "<", proc (a: seq[Value]): Value = cmpChain(a, proc (c: int): bool = c < 0)
  def ">", proc (a: seq[Value]): Value = cmpChain(a, proc (c: int): bool = c > 0)
  def "<=", proc (a: seq[Value]): Value = cmpChain(a, proc (c: int): bool = c <= 0)
  def ">=", proc (a: seq[Value]): Value = cmpChain(a, proc (c: int): bool = c >= 0)
  def "not", proc (a: seq[Value]): Value = mkBool(not truthy(a[0]))
  def "nil?", proc (a: seq[Value]): Value = mkBool(a[0].isNil or a[0].kind == kNil)
  def "some?", proc (a: seq[Value]): Value = mkBool(not (a[0].isNil or a[0].kind == kNil))
  def "true?", proc (a: seq[Value]): Value = mkBool(a[0].kind == kBool and a[0].b)
  def "false?", proc (a: seq[Value]): Value = mkBool(a[0].kind == kBool and not a[0].b)
  def "zero?", proc (a: seq[Value]): Value = mkBool(num(a[0]) == 0.0)
  def "pos?", proc (a: seq[Value]): Value = mkBool(num(a[0]) > 0.0)
  def "neg?", proc (a: seq[Value]): Value = mkBool(num(a[0]) < 0.0)
  def "even?", proc (a: seq[Value]): Value = mkBool(intOf(a[0]) mod 2 == 0)
  def "odd?", proc (a: seq[Value]): Value = mkBool(intOf(a[0]) mod 2 != 0)
  def "string?", proc (a: seq[Value]): Value = mkBool(a[0].kind == kStr)
  def "number?", proc (a: seq[Value]): Value = mkBool(a[0].kind in {kInt, kFloat})
  def "int?", proc (a: seq[Value]): Value = mkBool(a[0].kind == kInt)
  def "keyword?", proc (a: seq[Value]): Value = mkBool(a[0].kind == kKeyword)
  def "symbol?", proc (a: seq[Value]): Value = mkBool(a[0].kind == kSymbol)
  def "vector?", proc (a: seq[Value]): Value = mkBool(a[0].kind == kVector)
  def "list?", proc (a: seq[Value]): Value = mkBool(a[0].kind == kList)
  def "map?", proc (a: seq[Value]): Value = mkBool(a[0].kind == kMap)
  def "set?", proc (a: seq[Value]): Value = mkBool(a[0].kind == kSet)
  def "coll?", proc (a: seq[Value]): Value =
    mkBool(a[0].kind in {kList, kVector, kMap, kSet})
  def "fn?", proc (a: seq[Value]): Value = mkBool(a[0].kind == kFn)
  def "empty?", proc (a: seq[Value]): Value = mkBool(toSeq(a[0]).len == 0)
  def "contains?", proc (a: seq[Value]): Value =
    let c = a[0]
    if c.isNil or c.kind == kNil: return FalseV
    case c.kind
    of kMap:
      for (k, _) in c.pairs:
        if equals(k, a[1]): return TrueV
      FalseV
    of kSet:
      for x in c.items:
        if equals(x, a[1]): return TrueV
      FalseV
    of kVector:
      mkBool(a[1].kind == kInt and a[1].i >= 0 and a[1].i < c.items.len)
    else: FalseV

  # ---- strings / IO
  def "str", proc (a: seq[Value]): Value =
    var s = ""
    for x in a: s &= str(x)
    mkStr(s)
  def "pr-str", proc (a: seq[Value]): Value =
    var parts: seq[string] = @[]
    for x in a: parts.add prStr(x)
    mkStr(parts.join(" "))
  def "println", proc (a: seq[Value]): Value =
    var parts: seq[string] = @[]
    for x in a: parts.add str(x)
    echo parts.join(" ")
    NilV
  def "prn", proc (a: seq[Value]): Value =
    var parts: seq[string] = @[]
    for x in a: parts.add prStr(x)
    echo parts.join(" ")
    NilV
  def "print", proc (a: seq[Value]): Value =
    var parts: seq[string] = @[]
    for x in a: parts.add str(x)
    stdout.write parts.join(" ")
    NilV
  def "name", proc (a: seq[Value]): Value =
    case a[0].kind
    of kKeyword, kSymbol, kStr: mkStr(a[0].s)
    else: err("name expects keyword/symbol/string")
  def "keyword", proc (a: seq[Value]): Value = mkKeyword(str(a[0]))
  def "symbol", proc (a: seq[Value]): Value = mkSymbol(str(a[0]))
  def "subs", proc (a: seq[Value]): Value =
    let s = a[0].s
    let st = int(intOf(a[1]))
    let en = (if a.len > 2: int(intOf(a[2])) else: s.len)
    mkStr(s[st ..< en])
  def "clojure.string/upper-case", proc (a: seq[Value]): Value = mkStr(a[0].s.toUpperAscii)
  def "clojure.string/lower-case", proc (a: seq[Value]): Value = mkStr(a[0].s.toLowerAscii)
  def "clojure.string/trim", proc (a: seq[Value]): Value = mkStr(a[0].s.strip)
  def "clojure.string/split", proc (a: seq[Value]): Value =
    var r: seq[Value] = @[]
    for piece in a[0].s.split(a[1].s): r.add mkStr(piece)
    mkVector(r)
  def "clojure.string/join", proc (a: seq[Value]): Value =
    let sep = (if a.len > 1: str(a[0]) else: "")
    let coll = (if a.len > 1: a[1] else: a[0])
    var parts: seq[string] = @[]
    for x in toSeq(coll): parts.add str(x)
    mkStr(parts.join(sep))
  def "read-line", proc (a: seq[Value]): Value =
    try: mkStr(stdin.readLine()) except CatchableError: NilV
  def "slurp", proc (a: seq[Value]): Value = mkStr(readFile(a[0].s))
  def "spit", proc (a: seq[Value]): Value =
    writeFile(a[0].s, str(a[1])); NilV
  def "now-ms", proc (a: seq[Value]): Value = mkInt(int64(epochTime() * 1000))

  # ---- collections
  def "list", proc (a: seq[Value]): Value = mkList(a)
  def "vector", proc (a: seq[Value]): Value = mkVector(a)
  def "hash-map", proc (a: seq[Value]): Value =
    var m: Value = Value(kind: kMap, pairs: @[])
    var i = 0
    while i + 1 < a.len:
      m = assocOne(m, a[i], a[i + 1]); i += 2
    m
  def "hash-set", proc (a: seq[Value]): Value = mkSet(a)
  def "set", proc (a: seq[Value]): Value = mkSet(toSeq(a[0]))
  def "vec", proc (a: seq[Value]): Value = mkVector(toSeq(a[0]))
  def "seq", proc (a: seq[Value]): Value =
    let s = toSeq(a[0])
    (if s.len == 0: NilV else: mkList(s))
  def "count", proc (a: seq[Value]): Value =
    if a[0].isNil or a[0].kind == kNil: return mkInt(0)
    if a[0].kind == kStr: return mkInt(a[0].s.len)
    if a[0].kind == kMap: return mkInt(a[0].pairs.len)
    mkInt(toSeq(a[0]).len)
  def "conj", proc (a: seq[Value]): Value =
    result = a[0]
    for i in 1 ..< a.len: result = conjOne(result, a[i])
  def "cons", proc (a: seq[Value]): Value = mkList(@[a[0]] & toSeq(a[1]))
  def "first", proc (a: seq[Value]): Value =
    let s = toSeq(a[0])
    (if s.len == 0: NilV else: s[0])
  def "second", proc (a: seq[Value]): Value =
    let s = toSeq(a[0])
    (if s.len < 2: NilV else: s[1])
  def "last", proc (a: seq[Value]): Value =
    let s = toSeq(a[0])
    (if s.len == 0: NilV else: s[^1])
  def "rest", proc (a: seq[Value]): Value =
    let s = toSeq(a[0])
    (if s.len <= 1: mkList(@[]) else: mkList(s[1 .. ^1]))
  def "next", proc (a: seq[Value]): Value =
    let s = toSeq(a[0])
    (if s.len <= 1: NilV else: mkList(s[1 .. ^1]))
  def "nth", proc (a: seq[Value]): Value =
    let s = toSeq(a[0])
    let i = int(intOf(a[1]))
    if i >= 0 and i < s.len: s[i]
    elif a.len > 2: a[2]
    else: err("Index out of bounds: " & $i)
  def "get", proc (a: seq[Value]): Value =
    getIn(a[0], a[1], (if a.len > 2: a[2] else: NilV))
  def "get-in", proc (a: seq[Value]): Value =
    var cur = a[0]
    for k in toSeq(a[1]):
      cur = getIn(cur, k, NilV)
    (if (cur.isNil or cur.kind == kNil) and a.len > 2: a[2] else: cur)
  def "assoc", proc (a: seq[Value]): Value =
    result = a[0]
    var i = 1
    while i + 1 < a.len:
      result = assocOne(result, a[i], a[i + 1]); i += 2
  def "dissoc", proc (a: seq[Value]): Value =
    var ps = a[0].pairs
    for i in 1 ..< a.len:
      var keep: seq[(Value, Value)] = @[]
      for (k, v) in ps:
        if not equals(k, a[i]): keep.add (k, v)
      ps = keep
    Value(kind: kMap, pairs: ps)
  def "update", proc (a: seq[Value]): Value =
    let cur = getIn(a[0], a[1], NilV)
    assocOne(a[0], a[1], call(a[2], @[cur] & a[3 .. ^1]))
  def "keys", proc (a: seq[Value]): Value =
    var r: seq[Value] = @[]
    for (k, _) in a[0].pairs: r.add k
    (if r.len == 0: NilV else: mkList(r))
  def "vals", proc (a: seq[Value]): Value =
    var r: seq[Value] = @[]
    for (_, v) in a[0].pairs: r.add v
    (if r.len == 0: NilV else: mkList(r))
  def "reverse", proc (a: seq[Value]): Value =
    var s = toSeq(a[0])
    var r: seq[Value] = @[]
    for i in countdown(s.len - 1, 0): r.add s[i]
    mkList(r)
  def "range", proc (a: seq[Value]): Value =
    var lo: int64 = 0
    var hi: int64 = 0
    var step: int64 = 1
    if a.len == 1: hi = intOf(a[0])
    elif a.len >= 2:
      lo = intOf(a[0]); hi = intOf(a[1])
      if a.len > 2: step = intOf(a[2])
    var r: seq[Value] = @[]
    if step > 0:
      var i = lo
      while i < hi: r.add mkInt(i); i += step
    elif step < 0:
      var i = lo
      while i > hi: r.add mkInt(i); i += step
    mkList(r)
  def "take", proc (a: seq[Value]): Value =
    let n = int(intOf(a[0]))
    let s = toSeq(a[1])
    mkList(s[0 ..< min(n, s.len)])
  def "drop", proc (a: seq[Value]): Value =
    let n = int(intOf(a[0]))
    let s = toSeq(a[1])
    (if n >= s.len: mkList(@[]) else: mkList(s[n .. ^1]))
  def "concat", proc (a: seq[Value]): Value =
    var r: seq[Value] = @[]
    for x in a: r.add toSeq(x)
    mkList(r)
  def "sort", proc (a: seq[Value]): Value =
    var s = toSeq(a[^1])
    let cmpFn = (if a.len > 1: a[0] else: NilV)
    # insertion sort keeps it simple and stable
    for i in 1 ..< s.len:
      var j = i
      while j > 0:
        let before =
          if cmpFn.kind == kFn: truthy(call(cmpFn, @[s[j], s[j - 1]]))
          elif s[j].kind == kStr: s[j].s < s[j - 1].s
          else: num(s[j]) < num(s[j - 1])
        if not before: break
        swap(s[j], s[j - 1]); dec j
    mkList(s)
  def "sort-by", proc (a: seq[Value]): Value =
    var s = toSeq(a[^1])
    let kf = a[0]
    for i in 1 ..< s.len:
      var j = i
      while j > 0:
        let ka = call(kf, @[s[j]])
        let kb = call(kf, @[s[j - 1]])
        let before = (if ka.kind == kStr: ka.s < kb.s else: num(ka) < num(kb))
        if not before: break
        swap(s[j], s[j - 1]); dec j
    mkList(s)
  def "distinct", proc (a: seq[Value]): Value =
    var r: seq[Value] = @[]
    for x in toSeq(a[0]):
      var dup = false
      for y in r:
        if equals(x, y): dup = true; break
      if not dup: r.add x
    mkList(r)
  def "interpose", proc (a: seq[Value]): Value =
    var r: seq[Value] = @[]
    for x in toSeq(a[1]):
      if r.len > 0: r.add a[0]
      r.add x
    mkList(r)
  def "partition", proc (a: seq[Value]): Value =
    let n = int(intOf(a[0]))
    let s = toSeq(a[^1])
    var r: seq[Value] = @[]
    var i = 0
    while i + n <= s.len:
      r.add mkList(s[i ..< i + n]); i += n
    mkList(r)

  # ---- higher order
  def "apply", proc (a: seq[Value]): Value =
    var callArgs: seq[Value] = @[]
    for i in 1 ..< a.len - 1: callArgs.add a[i]
    callArgs.add toSeq(a[^1])
    call(a[0], callArgs)
  def "map", proc (a: seq[Value]): Value =
    let f = a[0]
    if a.len == 2:
      var r: seq[Value] = @[]
      for x in toSeq(a[1]): r.add call(f, @[x])
      return mkList(r)
    var colls: seq[seq[Value]] = @[]
    for i in 1 ..< a.len: colls.add toSeq(a[i])
    var n = colls[0].len
    for c in colls: n = min(n, c.len)
    var r: seq[Value] = @[]
    for i in 0 ..< n:
      var args: seq[Value] = @[]
      for c in colls: args.add c[i]
      r.add call(f, args)
    mkList(r)
  def "mapv", proc (a: seq[Value]): Value =
    var r: seq[Value] = @[]
    for x in toSeq(a[1]): r.add call(a[0], @[x])
    mkVector(r)
  def "map-indexed", proc (a: seq[Value]): Value =
    var r: seq[Value] = @[]
    var i = 0
    for x in toSeq(a[1]):
      r.add call(a[0], @[mkInt(i), x]); inc i
    mkList(r)
  def "filter", proc (a: seq[Value]): Value =
    var r: seq[Value] = @[]
    for x in toSeq(a[1]):
      if truthy(call(a[0], @[x])): r.add x
    mkList(r)
  def "remove", proc (a: seq[Value]): Value =
    var r: seq[Value] = @[]
    for x in toSeq(a[1]):
      if not truthy(call(a[0], @[x])): r.add x
    mkList(r)
  def "reduce", proc (a: seq[Value]): Value =
    let f = a[0]
    if a.len == 2:
      let s = toSeq(a[1])
      if s.len == 0: return call(f, @[])
      var acc = s[0]
      for i in 1 ..< s.len: acc = call(f, @[acc, s[i]])
      return acc
    var acc = a[1]
    for x in toSeq(a[2]): acc = call(f, @[acc, x])
    acc
  def "some", proc (a: seq[Value]): Value =
    for x in toSeq(a[1]):
      let r = call(a[0], @[x])
      if truthy(r): return r
    NilV
  def "every?", proc (a: seq[Value]): Value =
    for x in toSeq(a[1]):
      if not truthy(call(a[0], @[x])): return FalseV
    TrueV
  def "take-while", proc (a: seq[Value]): Value =
    var r: seq[Value] = @[]
    for x in toSeq(a[1]):
      if not truthy(call(a[0], @[x])): break
      r.add x
    mkList(r)
  def "drop-while", proc (a: seq[Value]): Value =
    var r: seq[Value] = @[]
    var dropping = true
    for x in toSeq(a[1]):
      if dropping and truthy(call(a[0], @[x])): continue
      dropping = false
      r.add x
    mkList(r)
  def "group-by", proc (a: seq[Value]): Value =
    var m: Value = Value(kind: kMap, pairs: @[])
    for x in toSeq(a[1]):
      let k = call(a[0], @[x])
      let cur = getIn(m, k, mkVector(@[]))
      m = assocOne(m, k, conjOne(cur, x))
    m
  def "frequencies", proc (a: seq[Value]): Value =
    var m: Value = Value(kind: kMap, pairs: @[])
    for x in toSeq(a[0]):
      let cur = getIn(m, x, mkInt(0))
      m = assocOne(m, x, mkInt(cur.i + 1))
    m
  def "identity", proc (a: seq[Value]): Value = a[0]
  def "comp", proc (a: seq[Value]): Value =
    let fs = a
    mkFn("comp", proc (args: seq[Value]): Value =
      if fs.len == 0: return argAt(args, 0)
      var v = call(fs[^1], args)
      for i in countdown(fs.len - 2, 0): v = call(fs[i], @[v])
      v)
  def "partial", proc (a: seq[Value]): Value =
    let f = a[0]
    let bound = a[1 .. ^1]
    mkFn("partial", proc (args: seq[Value]): Value = call(f, bound & args))
  def "juxt", proc (a: seq[Value]): Value =
    let fs = a
    mkFn("juxt", proc (args: seq[Value]): Value =
      var r: seq[Value] = @[]
      for f in fs: r.add call(f, args)
      mkVector(r))
  def "constantly", proc (a: seq[Value]): Value =
    let v = a[0]
    mkFn("constantly", proc (args: seq[Value]): Value = v)

  # ---- atoms (mutable boxes, modelled as a 1-slot vector)
  def "atom", proc (a: seq[Value]): Value =
    var cell = a[0]
    mkFn("atom", proc (args: seq[Value]): Value =
      # (a)        -> deref
      # (a :set v) -> reset
      if args.len == 0: return cell
      cell = args[1]
      cell)
  def "deref", proc (a: seq[Value]): Value = call(a[0], @[])
  def "reset!", proc (a: seq[Value]): Value = call(a[0], @[mkKeyword("set"), a[1]])
  def "swap!", proc (a: seq[Value]): Value =
    let cur = call(a[0], @[])
    let nv = call(a[1], @[cur] & a[2 .. ^1])
    call(a[0], @[mkKeyword("set"), nv])

  def "throw", proc (a: seq[Value]): Value = err(str(a[0]))
  def "ex-info", proc (a: seq[Value]): Value = mkStr(str(a[0]))
  def "time-ms", proc (a: seq[Value]): Value = mkInt(int64(epochTime() * 1000))
