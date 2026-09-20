## clonim runtime — persistent-ish Clojure values for compiled Nim code.
import std/[tables, strutils]

type
  Kind* = enum
    kNil, kBool, kInt, kFloat, kStr, kKeyword, kSymbol,
    kList, kVector, kMap, kSet, kFn

  Value* = ref object
    case kind*: Kind
    of kNil: discard
    of kBool: b*: bool
    of kInt: i*: int64
    of kFloat: f*: float64
    of kStr, kKeyword, kSymbol: s*: string
    of kList, kVector, kSet: items*: seq[Value]
    of kMap: pairs*: seq[(Value, Value)]
    of kFn:
      fn*: proc (args: seq[Value]): Value {.closure.}
      name*: string

  CljError* = object of CatchableError

let NilV* = Value(kind: kNil)
let TrueV* = Value(kind: kBool, b: true)
let FalseV* = Value(kind: kBool, b: false)

proc mkBool*(x: bool): Value = (if x: TrueV else: FalseV)
proc mkInt*(x: int64): Value = Value(kind: kInt, i: x)
proc mkFloat*(x: float64): Value = Value(kind: kFloat, f: x)
proc mkStr*(x: string): Value = Value(kind: kStr, s: x)
proc mkKeyword*(x: string): Value = Value(kind: kKeyword, s: x)
proc mkSymbol*(x: string): Value = Value(kind: kSymbol, s: x)
proc mkList*(xs: seq[Value]): Value = Value(kind: kList, items: xs)
proc mkVector*(xs: seq[Value]): Value = Value(kind: kVector, items: xs)
proc mkSet*(xs: seq[Value]): Value
proc mkFn*(name: string, f: proc (args: seq[Value]): Value {.closure.}): Value =
  Value(kind: kFn, fn: f, name: name)

proc err*(msg: string) {.noreturn.} = raise newException(CljError, msg)

proc truthy*(v: Value): bool =
  if v == nil: return false
  case v.kind
  of kNil: false
  of kBool: v.b
  else: true

# ---------------------------------------------------------------- equality
proc equals*(a, b: Value): bool =
  if a.isNil or b.isNil: return a.isNil and b.isNil
  # numeric tower: int and float compare across types
  if a.kind == kInt and b.kind == kFloat: return float64(a.i) == b.f
  if a.kind == kFloat and b.kind == kInt: return a.f == float64(b.i)
  # lists and vectors are sequentially equal in Clojure
  if a.kind in {kList, kVector} and b.kind in {kList, kVector}:
    if a.items.len != b.items.len: return false
    for i in 0 ..< a.items.len:
      if not equals(a.items[i], b.items[i]): return false
    return true
  if a.kind != b.kind: return false
  case a.kind
  of kNil: true
  of kBool: a.b == b.b
  of kInt: a.i == b.i
  of kFloat: a.f == b.f
  of kStr, kKeyword, kSymbol: a.s == b.s
  of kSet:
    if a.items.len != b.items.len: return false
    for x in a.items:
      var found = false
      for y in b.items:
        if equals(x, y): found = true; break
      if not found: return false
    true
  of kMap:
    if a.pairs.len != b.pairs.len: return false
    for (k, v) in a.pairs:
      var found = false
      for (k2, v2) in b.pairs:
        if equals(k, k2):
          if not equals(v, v2): return false
          found = true; break
      if not found: return false
    true
  of kFn: a == b
  of kList, kVector: false  # handled above

proc mkSet*(xs: seq[Value]): Value =
  var acc: seq[Value] = @[]
  for x in xs:
    var dup = false
    for y in acc:
      if equals(x, y): dup = true; break
    if not dup: acc.add x
  Value(kind: kSet, items: acc)

# ---------------------------------------------------------------- printing
proc escapeStr(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '\r': result.add "\\r"
    else: result.add c
  result.add "\""

proc toStr*(v: Value, readable: bool): string =
  if v.isNil: return "nil"
  case v.kind
  of kNil: "nil"
  of kBool: (if v.b: "true" else: "false")
  of kInt: $v.i
  of kFloat:
    var s = $v.f
    if '.' notin s and 'e' notin s and 'n' notin s and 'i' notin s: s &= ".0"
    s
  of kStr: (if readable: escapeStr(v.s) else: v.s)
  of kKeyword: ":" & v.s
  of kSymbol: v.s
  of kList:
    var parts: seq[string] = @[]
    for x in v.items: parts.add toStr(x, readable)
    "(" & parts.join(" ") & ")"
  of kVector:
    var parts: seq[string] = @[]
    for x in v.items: parts.add toStr(x, readable)
    "[" & parts.join(" ") & "]"
  of kSet:
    var parts: seq[string] = @[]
    for x in v.items: parts.add toStr(x, readable)
    "#{" & parts.join(" ") & "}"
  of kMap:
    var parts: seq[string] = @[]
    for (k, val) in v.pairs: parts.add toStr(k, readable) & " " & toStr(val, readable)
    "{" & parts.join(", ") & "}"
  of kFn: "#<fn " & v.name & ">"

proc prStr*(v: Value): string = toStr(v, true)
proc str*(v: Value): string = toStr(v, false)

# ---------------------------------------------------------------- vars
## Vars are cells, as in Clojure: compiled code resolves the cell once and
## reads through it, so a call site costs one pointer deref, not a hash lookup,
## while `def` can still rebind the var later.
type VarCell* = ref object
  name*: string
  bound*: bool
  v*: Value

var globals*: Table[string, VarCell] = initTable[string, VarCell]()

proc varCell*(name: string): VarCell =
  if globals.hasKey(name): return globals[name]
  result = VarCell(name: name, bound: false, v: NilV)
  globals[name] = result

proc setVar*(name: string, v: Value): Value {.discardable.} =
  let c = varCell(name)
  c.v = v
  c.bound = true
  v

proc cellGet*(c: VarCell): Value {.inline.} =
  if not c.bound: err("Unable to resolve symbol: " & c.name)
  c.v

proc getVar*(name: string): Value =
  cellGet(varCell(name))

proc hasVar*(name: string): bool =
  globals.hasKey(name) and globals[name].bound

# ---------------------------------------------------------------- calling
proc call*(f: Value, args: seq[Value]): Value =
  if f.isNil: err("Can't call nil")
  case f.kind
  of kFn: f.fn(args)
  of kKeyword:
    # (:k m) => lookup
    if args.len == 0: err("Wrong number of args to keyword")
    let m = args[0]
    if m.isNil or m.kind != kMap: return NilV
    for (k, v) in m.pairs:
      if equals(k, f): return v
    (if args.len > 1: args[1] else: NilV)
  of kMap:
    if args.len == 0: err("Wrong number of args to map")
    for (k, v) in f.pairs:
      if equals(k, args[0]): return v
    (if args.len > 1: args[1] else: NilV)
  of kVector:
    if args.len != 1 or args[0].kind != kInt: err("Vector lookup needs one int")
    let i = int(args[0].i)
    if i < 0 or i >= f.items.len: err("Index out of bounds: " & $i)
    f.items[i]
  else: err("Can't call value of kind " & $f.kind & ": " & prStr(f))

proc argAt*(args: seq[Value], i: int): Value =
  if i < args.len: args[i] else: NilV

proc restArgs*(args: seq[Value], i: int): Value =
  if i >= args.len: return NilV
  mkList(args[i .. ^1])

proc arity*(name: string, args: seq[Value], n: int) =
  if args.len != n:
    err("Wrong number of args (" & $args.len & ") passed to " & name)

# ---------------------------------------------------------------- seqs
proc toSeq*(v: Value): seq[Value] =
  if v.isNil: return @[]
  case v.kind
  of kNil: @[]
  of kList, kVector, kSet: v.items
  of kStr:
    var r: seq[Value] = @[]
    for c in v.s: r.add mkStr($c)
    r
  of kMap:
    var r: seq[Value] = @[]
    for (k, val) in v.pairs: r.add mkVector(@[k, val])
    r
  else: err("Don't know how to create seq from: " & prStr(v))

proc mkMap*(ps: seq[(Value, Value)]): Value = Value(kind: kMap, pairs: ps)
let emptyArgs*: seq[Value] = @[]
