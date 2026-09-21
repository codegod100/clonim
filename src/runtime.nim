## clonim runtime — persistent Clojure values for compiled Nim code.
##
## Vectors are 32-way tries with a tail buffer (Clojure's PersistentVector);
## maps and sets are HAMTs. Both share structure on update, so `assoc`/`conj`
## are O(log32 n) and copy a handful of 32-element nodes instead of the whole
## collection. Maps and sets additionally remember insertion order — every
## entry carries an `ord` stamp and iteration sorts by it — so printing and
## `keys`/`vals` stay predictable the way Clojure's small array-maps are.
import std/[tables, strutils, hashes, bitops, algorithm]

const
  Bits = 5
  Width = 1 shl Bits   # 32
  Mask = Width - 1
  MaxShift = 30        # beyond this a HAMT runs out of hash bits

type
  Kind* = enum
    kNil, kBool, kInt, kFloat, kStr, kKeyword, kSymbol,
    kList, kVector, kMap, kSet, kCons, kLazy, kFn

  VNode* = ref object
    ## A trie node: leaves hold values, internal nodes hold children.
    case leaf*: bool
    of true: vals*: seq[Value]
    of false: kids*: seq[VNode]

  PVec* = object
    cnt*: int          ## total element count
    shift*: int        ## bit offset of the root level
    root*: VNode       ## internal node (never nil)
    tail*: seq[Value]  ## up to 32 trailing elements, not yet in the trie

  MEntry* = object
    key*, val*: Value
    ord*: int          ## insertion stamp, for stable iteration order

  MSlotKind* = enum msEntry, msNode
  MSlot* = object
    case sk*: MSlotKind
    of msEntry: e*: MEntry
    of msNode: node*: MNode

  MNode* = ref object
    ## Bitmap-indexed node, or — once the hash bits run out — a linear
    ## collision bucket.
    case collision*: bool
    of false:
      bitmap*: uint32
      slots*: seq[MSlot]
    of true:
      kvs*: seq[MEntry]

  PMap* = object
    root*: MNode       ## nil when empty
    cnt*: int
    nextOrd*: int

  Value* = ref ValueObj
  ValueObj* = object
    case kind*: Kind
    of kNil: discard
    of kBool: b*: bool
    of kInt: i*: int64
    of kFloat: f*: float64
    of kStr, kKeyword, kSymbol: s*: string
    of kList: xs*: seq[Value]
    of kVector: vec*: PVec
    of kMap, kSet: m*: PMap
    of kCons:
      head*: Value
      tl*: Value       ## rest of the seq: a cons, a lazy seq, a coll, or nil
    of kLazy:
      thunk*: proc (): Value {.closure.}
      cached*: Value
      forced*: bool
    of kFn:
      fn*: proc (args: seq[Value]): Value {.closure.}
      name*: string

  CljError* = object of CatchableError

# ------------------------------------------------------------ teardown
## A realized lazy seq is a chain of `cons -> lazy -> cons -> …` refs, and ARC
## frees a chain by recursing into it — a million-element seq means a million
## destructor frames, i.e. a segfault at scope exit. So `kCons`/`kLazy` hand
## their tail to a worklist instead of letting the field drop inline, and the
## outermost destructor drains it in a loop. Nothing shared is mutated: a node
## another seq still holds simply survives with its refcount intact.
##
## Defining `=destroy` means the compiler stops generating field teardown for
## `ValueObj`, so every branch below has to release its own fields.

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
  of kCons:
    `=destroy`(x.head)
    if not x.tl.isNil: pendingFree.add x.tl   # +1, outlives the release below
    `=destroy`(x.tl)
  of kLazy:
    `=destroy`(x.thunk)
    if not x.cached.isNil: pendingFree.add x.cached
    `=destroy`(x.cached)
  of kNil, kBool, kInt, kFloat: discard
  if draining: return
  draining = true
  while pendingFree.len > 0:
    let v = pendingFree.pop()
    discard v      # dies here: its own tail is queued, not recursed into
  draining = false

let NilV* = Value(kind: kNil)
let TrueV* = Value(kind: kBool, b: true)
let FalseV* = Value(kind: kBool, b: false)

proc err*(msg: string) {.noreturn.} = raise newException(CljError, msg)

proc equals*(a, b: Value): bool
proc hashValue*(v: Value): uint32
proc prStr*(v: Value): string
proc toSeq*(v: Value): seq[Value]

# ------------------------------------------------------- persistent vector
let emptyVNode = VNode(leaf: false, kids: @[])

proc emptyPVec*(): PVec = PVec(cnt: 0, shift: Bits, root: emptyVNode, tail: @[])

proc tailOff(v: PVec): int =
  if v.cnt < Width: 0 else: ((v.cnt - 1) shr Bits) shl Bits

proc leafFor(v: PVec, i: int): seq[Value] =
  if i >= tailOff(v): return v.tail
  var node = v.root
  var level = v.shift
  while level > 0:
    node = node.kids[(i shr level) and Mask]
    level -= Bits
  node.vals

proc vecNth*(v: PVec, i: int): Value =
  if i < 0 or i >= v.cnt: err("Index out of bounds: " & $i)
  leafFor(v, i)[i and Mask]

proc newPath(level: int, node: VNode): VNode =
  if level == 0: node
  else: VNode(leaf: false, kids: @[newPath(level - Bits, node)])

proc pushTail(cnt, level: int, parent, tailNode: VNode): VNode =
  let subIdx = ((cnt - 1) shr level) and Mask
  var kids = parent.kids
  let child =
    if level == Bits: tailNode
    elif subIdx < kids.len: pushTail(cnt, level - Bits, kids[subIdx], tailNode)
    else: newPath(level - Bits, tailNode)
  if subIdx < kids.len: kids[subIdx] = child
  else: kids.add child
  VNode(leaf: false, kids: kids)

proc vecConj*(v: PVec, x: Value): PVec =
  if v.tail.len < Width:
    return PVec(cnt: v.cnt + 1, shift: v.shift, root: v.root, tail: v.tail & x)
  let tailNode = VNode(leaf: true, vals: v.tail)
  var shift = v.shift
  var root: VNode
  if (v.cnt shr Bits) > (1 shl v.shift):  # root overflow: grow a level
    root = VNode(leaf: false, kids: @[v.root, newPath(v.shift, tailNode)])
    shift += Bits
  else:
    root = pushTail(v.cnt, v.shift, v.root, tailNode)
  PVec(cnt: v.cnt + 1, shift: shift, root: root, tail: @[x])

proc doAssoc(level: int, node: VNode, i: int, x: Value): VNode =
  if level == 0:
    var vals = node.vals
    vals[i and Mask] = x
    VNode(leaf: true, vals: vals)
  else:
    var kids = node.kids
    let sub = (i shr level) and Mask
    kids[sub] = doAssoc(level - Bits, kids[sub], i, x)
    VNode(leaf: false, kids: kids)

proc vecAssoc*(v: PVec, i: int, x: Value): PVec =
  if i == v.cnt: return vecConj(v, x)
  if i < 0 or i > v.cnt: err("Index out of bounds: " & $i)
  if i >= tailOff(v):
    var tail = v.tail
    tail[i - tailOff(v)] = x
    return PVec(cnt: v.cnt, shift: v.shift, root: v.root, tail: tail)
  PVec(cnt: v.cnt, shift: v.shift, root: doAssoc(v.shift, v.root, i, x),
       tail: v.tail)

proc vecToSeq*(v: PVec): seq[Value] =
  result = newSeqOfCap[Value](v.cnt)
  var i = 0
  while i < v.cnt:
    let leaf = leafFor(v, i)
    let base = i and not Mask
    for j in 0 ..< leaf.len:
      if base + j >= v.cnt: break
      result.add leaf[j]
    i = base + leaf.len

proc toPVec*(xs: seq[Value]): PVec =
  result = emptyPVec()
  for x in xs: result = vecConj(result, x)

# ----------------------------------------------------------------- hashing
proc mixHash(a, b: uint32): uint32 =
  ## Boost-style combine; cheap and good enough for trie index bits.
  a xor (b + 0x9e3779b9'u32 + (a shl 6) + (a shr 2))

# ---------------------------------------------------------- persistent map
proc bitPos(h: uint32, shift: int): uint32 = 1'u32 shl ((h shr shift) and Mask)
proc slotIdx(bitmap, bit: uint32): int = countSetBits(bitmap and (bit - 1))

proc emptyPMap*(): PMap = PMap(root: nil, cnt: 0, nextOrd: 0)

proc mergeEntries(shift: int, h1: uint32, e1: MEntry,
                  h2: uint32, e2: MEntry): MNode =
  if shift > MaxShift:
    return MNode(collision: true, kvs: @[e1, e2])
  let b1 = bitPos(h1, shift)
  let b2 = bitPos(h2, shift)
  if b1 == b2:
    MNode(collision: false, bitmap: b1,
          slots: @[MSlot(sk: msNode,
                         node: mergeEntries(shift + Bits, h1, e1, h2, e2))])
  elif b1 < b2:
    MNode(collision: false, bitmap: b1 or b2,
          slots: @[MSlot(sk: msEntry, e: e1), MSlot(sk: msEntry, e: e2)])
  else:
    MNode(collision: false, bitmap: b1 or b2,
          slots: @[MSlot(sk: msEntry, e: e2), MSlot(sk: msEntry, e: e1)])

proc nodeAssoc(n: MNode, shift: int, h: uint32, k, v: Value, newOrd: int,
               added: var bool): MNode =
  if n.collision:
    for i in 0 ..< n.kvs.len:
      if equals(n.kvs[i].key, k):
        var kvs = n.kvs
        kvs[i].val = v
        return MNode(collision: true, kvs: kvs)
    added = true
    return MNode(collision: true,
                 kvs: n.kvs & MEntry(key: k, val: v, ord: newOrd))
  let bit = bitPos(h, shift)
  let idx = slotIdx(n.bitmap, bit)
  var slots = n.slots
  if (n.bitmap and bit) != 0:
    case slots[idx].sk
    of msNode:
      slots[idx] = MSlot(sk: msNode,
        node: nodeAssoc(slots[idx].node, shift + Bits, h, k, v, newOrd, added))
    of msEntry:
      let e = slots[idx].e
      if equals(e.key, k):
        slots[idx] = MSlot(sk: msEntry, e: MEntry(key: k, val: v, ord: e.ord))
      else:
        added = true
        slots[idx] = MSlot(sk: msNode,
          node: mergeEntries(shift + Bits, hashValue(e.key), e, h,
                             MEntry(key: k, val: v, ord: newOrd)))
    return MNode(collision: false, bitmap: n.bitmap, slots: slots)
  added = true
  slots.insert(MSlot(sk: msEntry, e: MEntry(key: k, val: v, ord: newOrd)), idx)
  MNode(collision: false, bitmap: n.bitmap or bit, slots: slots)

proc mapAssoc*(m: PMap, k, v: Value): PMap =
  let h = hashValue(k)
  var added = false
  if m.root.isNil:
    return PMap(root: MNode(collision: false, bitmap: bitPos(h, 0),
                            slots: @[MSlot(sk: msEntry,
                                           e: MEntry(key: k, val: v, ord: 0))]),
                cnt: 1, nextOrd: 1)
  let root = nodeAssoc(m.root, 0, h, k, v, m.nextOrd, added)
  PMap(root: root, cnt: m.cnt + (if added: 1 else: 0),
       nextOrd: m.nextOrd + (if added: 1 else: 0))

proc nodeFind(n: MNode, shift: int, h: uint32, k: Value,
              found: var bool): Value =
  if n.isNil: return NilV
  if n.collision:
    for e in n.kvs:
      if equals(e.key, k):
        found = true
        return e.val
    return NilV
  let bit = bitPos(h, shift)
  if (n.bitmap and bit) == 0: return NilV
  let slot = n.slots[slotIdx(n.bitmap, bit)]
  case slot.sk
  of msNode: nodeFind(slot.node, shift + Bits, h, k, found)
  of msEntry:
    if equals(slot.e.key, k):
      found = true
      slot.e.val
    else: NilV

proc mapGet*(m: PMap, k: Value, dflt: Value): Value =
  var found = false
  let v = nodeFind(m.root, 0, hashValue(k), k, found)
  if found: v else: dflt

proc mapContains*(m: PMap, k: Value): bool =
  var found = false
  discard nodeFind(m.root, 0, hashValue(k), k, found)
  found

proc nodeDissoc(n: MNode, shift: int, h: uint32, k: Value,
                removed: var bool): MNode =
  if n.collision:
    var kvs: seq[MEntry] = @[]
    for e in n.kvs:
      if equals(e.key, k): removed = true
      else: kvs.add e
    return (if kvs.len == 0: nil else: MNode(collision: true, kvs: kvs))
  let bit = bitPos(h, shift)
  if (n.bitmap and bit) == 0: return n
  let idx = slotIdx(n.bitmap, bit)
  var slots = n.slots
  case slots[idx].sk
  of msNode:
    let child = nodeDissoc(slots[idx].node, shift + Bits, h, k, removed)
    if child.isNil:
      slots.delete(idx)
      return (if slots.len == 0: nil
              else: MNode(collision: false, bitmap: n.bitmap and not bit,
                          slots: slots))
    slots[idx] = MSlot(sk: msNode, node: child)
    MNode(collision: false, bitmap: n.bitmap, slots: slots)
  of msEntry:
    if not equals(slots[idx].e.key, k): return n
    removed = true
    slots.delete(idx)
    if slots.len == 0: nil
    else: MNode(collision: false, bitmap: n.bitmap and not bit, slots: slots)

proc mapDissoc*(m: PMap, k: Value): PMap =
  if m.root.isNil: return m
  var removed = false
  let root = nodeDissoc(m.root, 0, hashValue(k), k, removed)
  if not removed: return m
  PMap(root: root, cnt: m.cnt - 1, nextOrd: m.nextOrd)

proc collect(n: MNode, acc: var seq[MEntry]) =
  if n.isNil: return
  if n.collision:
    for e in n.kvs: acc.add e
    return
  for slot in n.slots:
    case slot.sk
    of msEntry: acc.add slot.e
    of msNode: collect(slot.node, acc)

proc mapEntries*(m: PMap): seq[MEntry] =
  ## Entries in insertion order.
  result = newSeqOfCap[MEntry](m.cnt)
  collect(m.root, result)
  result.sort(proc (a, b: MEntry): int = cmp(a.ord, b.ord))

# ------------------------------------------------------------ constructors
proc mkBool*(x: bool): Value = (if x: TrueV else: FalseV)
proc mkInt*(x: int64): Value = Value(kind: kInt, i: x)
proc mkFloat*(x: float64): Value = Value(kind: kFloat, f: x)
proc mkStr*(x: string): Value = Value(kind: kStr, s: x)
proc mkKeyword*(x: string): Value = Value(kind: kKeyword, s: x)
proc mkSymbol*(x: string): Value = Value(kind: kSymbol, s: x)
proc mkList*(xs: seq[Value]): Value = Value(kind: kList, xs: xs)
proc mkVector*(xs: seq[Value]): Value = Value(kind: kVector, vec: toPVec(xs))
proc mkVec*(v: PVec): Value = Value(kind: kVector, vec: v)
proc mkMapOf*(m: PMap): Value = Value(kind: kMap, m: m)
proc mkSetOf*(m: PMap): Value = Value(kind: kSet, m: m)

proc mkMap*(ps: seq[(Value, Value)]): Value =
  var m = emptyPMap()
  for (k, v) in ps: m = mapAssoc(m, k, v)
  Value(kind: kMap, m: m)

proc mkSet*(xs: seq[Value]): Value =
  var m = emptyPMap()
  for x in xs:
    if not mapContains(m, x): m = mapAssoc(m, x, x)
  Value(kind: kSet, m: m)

proc mkFn*(name: string, f: proc (args: seq[Value]): Value {.closure.}): Value =
  Value(kind: kFn, fn: f, name: name)

# --------------------------------------------------------------- lazy seqs
## A lazy seq is a thunk that, when forced, yields either nil/`kNil` (the end)
## or a cons cell whose tail is usually another lazy seq. Forcing is memoized
## in place, so each element is computed once no matter how often it is walked.
## Nothing here recurses per element: `force` loops, and so does every producer
## in core, which is what keeps `(nth (iterate inc 0) 1000000)` from blowing the
## stack.

proc mkCons*(h, t: Value): Value = Value(kind: kCons, head: h, tl: t)

proc mkLazy*(f: proc (): Value {.closure.}): Value =
  Value(kind: kLazy, thunk: f, cached: nil, forced: false)

proc force*(v: Value): Value =
  ## Realize one step: follow a chain of lazy seqs down to a cons, a concrete
  ## collection, or the end of the seq.
  var cur = v
  while not cur.isNil and cur.kind == kLazy:
    if not cur.forced:
      cur.cached = cur.thunk()
      cur.forced = true
      cur.thunk = nil       # drop the closure so its captures can be collected
    cur = cur.cached
  cur

proc isSeqNode(v: Value): bool =
  not v.isNil and v.kind in {kCons, kLazy}

type Cursor* = object
  ## Walks any seqable value without materializing it. Cons/lazy chains are
  ## followed link by link; concrete collections are indexed.
  node: Value
  backing: seq[Value]
  idx: int
  isNode: bool

proc cursor*(v: Value): Cursor =
  ## Forces nothing: a cons/lazy value is walked link by link, and `hasNext`
  ## is the only thing that ever forces. So building `(take 3 (map f xs))`
  ## runs `f` zero times until something asks for an element.
  if v.isNil: return Cursor(isNode: false)
  if v.kind in {kCons, kLazy, kNil}: Cursor(isNode: true, node: v)
  else: Cursor(isNode: false, backing: toSeq(v))

proc hasNext*(c: var Cursor): bool =
  if not c.isNode: return c.idx < c.backing.len
  c.node = force(c.node)
  if c.node.isNil or c.node.kind == kNil: return false
  if c.node.kind == kCons: return true
  # The tail bottomed out in a concrete collection, as `(cons x [1 2])` does.
  # Switch to indexing it rather than reporting the seq as finished.
  c.isNode = false
  c.backing = toSeq(c.node)
  c.idx = 0
  c.idx < c.backing.len

proc next*(c: var Cursor): Value =
  if c.isNode:
    result = c.node.head
    c.node = c.node.tl
  else:
    result = c.backing[c.idx]
    inc c.idx

iterator elems*(v: Value): Value =
  ## The one way to walk a collection in core: works for lists, vectors, maps,
  ## sets, strings and lazy seqs alike, and never realizes more than it is asked
  ## for.
  var c = cursor(v)
  while hasNext(c): yield next(c)

proc seqFirst*(v: Value): Value =
  let f = force(v)
  if f.isNil: return NilV
  if f.kind == kCons: return f.head
  var c = cursor(f)
  (if hasNext(c): next(c) else: NilV)

proc seqRest*(v: Value): Value =
  ## The rest of a seq, as a seq. Empty is an empty list, never nil — `next`
  ## is the one that nils out.
  let f = force(v)
  if f.isNil or f.kind == kNil: return mkList(@[])
  if f.kind == kCons: return (if f.tl.isNil: mkList(@[]) else: f.tl)
  let xs = toSeq(f)
  (if xs.len <= 1: mkList(@[]) else: mkList(xs[1 .. ^1]))

proc seqIsEmpty*(v: Value): bool =
  ## O(1) for lazy seqs: forces at most the first element.
  var c = cursor(v)
  not hasNext(c)

proc seqDrop*(v: Value, n: int): Value =
  ## Skip n elements. Used by `& rest` destructuring, so it must not realize
  ## anything past the n-th link — `(let [[a b & more] (range)] …)` works.
  result = v
  var k = n
  while k > 0:
    if seqIsEmpty(result): return mkList(@[])
    result = seqRest(result)
    dec k

proc hashValue*(v: Value): uint32 =
  if v.isNil: return 0
  case v.kind
  of kNil: 0'u32
  of kBool: (if v.b: 0x9e3779b9'u32 else: 0x85ebca6b'u32)
  of kInt: uint32(hash(v.i))
  of kFloat:
    # ints and floats compare equal across kinds, so they must hash alike
    if v.f == float64(int64(v.f)): uint32(hash(int64(v.f)))
    else: uint32(hash(v.f))
  of kStr: mixHash(1'u32, uint32(hash(v.s)))
  of kKeyword: mixHash(2'u32, uint32(hash(v.s)))
  of kSymbol: mixHash(3'u32, uint32(hash(v.s)))
  of kList, kVector, kCons, kLazy:
    # sequentials are `=` when their elements are, so they hash alike
    var h = 7'u32
    for x in elems(v): h = mixHash(h, hashValue(x))
    h
  of kSet:
    var h = 0'u32                       # xor: independent of iteration order
    for e in mapEntries(v.m): h = h xor hashValue(e.key)
    h
  of kMap:
    var h = 0'u32
    for e in mapEntries(v.m):
      h = h xor mixHash(hashValue(e.key), hashValue(e.val))
    h
  of kFn: uint32(hash(cast[int](cast[pointer](v))))

# --------------------------------------------------------------- accessors
proc items*(v: Value): seq[Value] =
  ## Elements of any sequential value, in order. O(n) — prefer `count`/`nth`
  ## when you only need one element.
  if v.isNil: return @[]
  case v.kind
  of kList: v.xs
  of kVector: vecToSeq(v.vec)
  of kSet:
    var r = newSeqOfCap[Value](v.m.cnt)
    for e in mapEntries(v.m): r.add e.key
    r
  of kCons, kLazy:
    var r: seq[Value] = @[]
    var c = cursor(v)
    while hasNext(c): r.add next(c)
    r
  else: @[]

proc pairs*(v: Value): seq[(Value, Value)] =
  if v.isNil or v.kind != kMap: return @[]
  result = newSeqOfCap[(Value, Value)](v.m.cnt)
  for e in mapEntries(v.m): result.add (e.key, e.val)

proc count*(v: Value): int =
  if v.isNil: return 0
  case v.kind
  of kNil: 0
  of kList: v.xs.len
  of kVector: v.vec.cnt
  of kMap, kSet: v.m.cnt
  of kStr: v.s.len
  of kCons, kLazy:
    # realizes the whole seq, which is the honest cost of counting one
    var n = 0
    var c = cursor(v)
    while hasNext(c): discard next(c); inc n
    n
  else: err("Don't know how to count: " & prStr(v))

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
  # every sequential thing is `=` to every other with the same elements
  const Seqs = {kList, kVector, kCons, kLazy}
  if a.kind in Seqs and b.kind in Seqs:
    var ca = cursor(a)
    var cb = cursor(b)
    while true:
      let ha = hasNext(ca)
      if ha != hasNext(cb): return false
      if not ha: return true
      if not equals(next(ca), next(cb)): return false
  if a.kind != b.kind: return false
  case a.kind
  of kNil: true
  of kBool: a.b == b.b
  of kInt: a.i == b.i
  of kFloat: a.f == b.f
  of kStr, kKeyword, kSymbol: a.s == b.s
  of kSet:
    if a.m.cnt != b.m.cnt: return false
    for e in mapEntries(a.m):
      if not mapContains(b.m, e.key): return false
    true
  of kMap:
    if a.m.cnt != b.m.cnt: return false
    let missing = Value(kind: kKeyword, s: "%clonim-missing")
    for e in mapEntries(a.m):
      if not equals(e.val, mapGet(b.m, e.key, missing)): return false
    true
  of kFn: a == b
  of kList, kVector, kCons, kLazy: false  # handled above
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
  of kList, kCons, kLazy:
    # printing a lazy seq realizes it, exactly as in Clojure
    var parts: seq[string] = @[]
    for x in elems(v): parts.add toStr(x, readable)
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
    mapGet(m.m, f, (if args.len > 1: args[1] else: NilV))
  of kMap:
    if args.len == 0: err("Wrong number of args to map")
    mapGet(f.m, args[0], (if args.len > 1: args[1] else: NilV))
  of kVector:
    if args.len != 1 or args[0].kind != kInt: err("Vector lookup needs one int")
    vecNth(f.vec, int(args[0].i))
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
  of kList, kVector, kSet, kCons, kLazy: v.items
  of kStr:
    var r: seq[Value] = @[]
    for c in v.s: r.add mkStr($c)
    r
  of kMap:
    var r: seq[Value] = @[]
    for e in mapEntries(v.m): r.add mkVector(@[e.key, e.val])
    r
  else: err("Don't know how to create seq from: " & prStr(v))

let emptyArgs*: seq[Value] = @[]

## True while a var still holds the exact fn a call site was compiled against.
## Call sites that bind a known-arity fn or an inlined primitive directly guard
## on this, so a later `def` that rebinds the name still takes effect.
proc cellIs*(c: VarCell, v: Value): bool {.inline.} =
  c.bound and c.v == v
