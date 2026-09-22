## ABI shared by generated clonim programs and the private static runtime.
## This is not a public interface: it is built and shipped as one versioned
## unit with the matching compiler and runtime archive.

type
  Kind* = enum
    kNil, kBool, kInt, kFloat, kChar, kStr, kKeyword, kSymbol,
    kList, kVector, kMap, kSet, kCons, kChunk, kLazy, kFn, kAgent

  AgentAction* = object
    fn*: Value
    args*: seq[Value]

  Agent* = ref object
    ## Actions are queued in send order and run one at a time when observed.
    state*: Value
    queue*: seq[AgentAction]
    failure*: Value
    draining*: bool

  VNode* = ref object
    case leaf*: bool
    of true: vals*: seq[Value]
    of false: kids*: seq[VNode]

  PVec* = object
    cnt*, shift*: int
    root*: VNode
    tail*: seq[Value]

  MEntry* = object
    key*, val*: Value
    ord*: int

  MSlotKind* = enum msEntry, msNode
  MSlot* = object
    case sk*: MSlotKind
    of msEntry: e*: MEntry
    of msNode: node*: MNode

  MNode* = ref object
    case collision*: bool
    of false:
      bitmap*: uint32
      slots*: seq[MSlot]
    of true:
      kvs*: seq[MEntry]

  PMap* = object
    root*: MNode
    cnt*, nextOrd*: int

  RecipeKind* = enum rkRange, rkMap, rkFilter
  Recipe* = ref object
    case rk*: RecipeKind
    of rkRange:
      lo*, hi*, step*: int64
      bounded*: bool
    of rkMap, rkFilter:
      rfn*: Value
      keep*: bool
      src*: Value

  Obj* = ref ValueObj
  ValueObj* = object
    case kind*: Kind
    of kNil, kBool, kInt, kFloat, kChar: discard
    of kStr, kKeyword, kSymbol: s*: string
    of kList: xs*: seq[Value]
    of kVector: vec*: PVec
    of kMap, kSet: m*: PMap
    of kCons:
      head*, tl*: Value
    of kChunk:
      chunk*: seq[Value]
      coff*: int
      ctl*: Value
    of kLazy:
      thunk*: proc (): Value {.closure.}
      cached*: Value
      forced*: bool
      rec*: Recipe
    of kFn:
      fn*: proc (args: openArray[Value]): Value {.closure.}
      name*: string
    of kAgent:
      agent*: Agent

  Value* = object
    kind*: Kind
    raw*: int64
    obj*: Obj

  CljError* = object of CatchableError

  VarCell* = ref object
    name*: string
    bound*: bool
    v*: Value

  FusedOp* = object
    isMap*: bool
    fn*: Value
    keep*: bool

proc i*(v: Value): int64 {.inline.} = v.raw
proc b*(v: Value): bool {.inline.} = v.raw != 0
proc f*(v: Value): float64 {.inline.} = cast[float64](v.raw)
proc s*(v: Value): lent string {.inline.} = v.obj.s
proc xs*(v: Value): lent seq[Value] {.inline.} = v.obj.xs
proc vec*(v: Value): lent PVec {.inline.} = v.obj.vec
proc m*(v: Value): lent PMap {.inline.} = v.obj.m
proc head*(v: Value): lent Value {.inline.} = v.obj.head
proc tl*(v: Value): lent Value {.inline.} = v.obj.tl
proc chunk*(v: Value): lent seq[Value] {.inline.} = v.obj.chunk
proc coff*(v: Value): int {.inline.} = v.obj.coff
proc ctl*(v: Value): lent Value {.inline.} = v.obj.ctl
proc cached*(v: Value): lent Value {.inline.} = v.obj.cached
proc forced*(v: Value): bool {.inline.} = v.obj.forced
proc thunk*(v: Value): auto {.inline.} = v.obj.thunk
proc fn*(v: Value): auto {.inline.} = v.obj.fn
proc name*(v: Value): lent string {.inline.} = v.obj.name
proc isNil*(v: Value): bool {.inline.} = v.kind == kNil

var pendingFree: seq[Value] = @[]
var draining = false

proc `=destroy`*(x: var ValueObj) =
  case x.kind
  of kStr, kKeyword, kSymbol: `=destroy`(x.s)
  of kList: `=destroy`(x.xs)
  of kVector: `=destroy`(x.vec)
  of kMap, kSet: `=destroy`(x.m)
  of kFn:
    `=destroy`(x.fn)
    `=destroy`(x.name)
  of kAgent: `=destroy`(x.agent)
  of kCons:
    `=destroy`(x.head)
    if not x.tl.isNil: pendingFree.add x.tl
    `=destroy`(x.tl)
  of kChunk:
    `=destroy`(x.chunk)
    if not x.ctl.isNil: pendingFree.add x.ctl
    `=destroy`(x.ctl)
  of kLazy:
    `=destroy`(x.thunk)
    if not x.cached.isNil: pendingFree.add x.cached
    `=destroy`(x.cached)
  of kNil, kBool, kInt, kFloat, kChar: discard
  if draining: return
  draining = true
  while pendingFree.len > 0:
    let v = pendingFree.pop()
    discard v
  draining = false

let NilV* = Value(kind: kNil)
let TrueV* = Value(kind: kBool, raw: 1)
let FalseV* = Value(kind: kBool, raw: 0)
let emptyArgs*: array[0, Value] = []
