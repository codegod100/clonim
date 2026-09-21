## clonim compiler — Clojure forms -> Nim source.
##
## Shape borrowed from jank: read to data, analyze into a small set of core
## special forms (everything else is expanded), then emit host-language code
## and let the host compiler do register allocation, inlining and codegen.
import std/[tables, strutils, sets]
import runtime, namespaces

type
  ## A fn whose arity is known at the call site, so it can be reached as a
  ## plain Nim proc instead of through a seq of boxed args.
  Direct = object
    prc: string                     # nim proc ident taking positional Values
    cell: string                    # var cell to guard on ("" = no guard)
    fnVal: string                   # nim ident of the fn Value to compare

  Env = ref object
    parent: Env
    locals: Table[string, string]   # clojure name -> nim identifier
    ints: HashSet[string]           # of those, the ones held as raw int64
    directs: Table[string, Direct]  # "name/arity" -> positional entry point
    intFns: Table[string, string]   # "name/arity" -> int-specialised proc
    intFnBoxes: HashSet[string]     # of those, the ones returning Value

  Ctx = ref object
    body: seq[string]               # emitted lines
    indent: int
    counter: int
    recurStack: seq[seq[string]]    # nim idents of the enclosing recur target
    recurInts: seq[seq[bool]]       # which of those are raw int64
    defined: HashSet[string]        # names def'd so far (for nicer errors)
    prelude: seq[string]            # hoisted var-cell resolutions
    cells: Table[string, string]    # clojure var name -> nim cell ident
    cores: Table[string, string]    # var name -> nim ident holding its core fn
    defCounts: CountTable[string]   # how many def forms target each name

proc newEnv(parent: Env = nil): Env =
  Env(parent: parent, locals: initTable[string, string](),
      ints: initHashSet[string](), directs: initTable[string, Direct](),
      intFns: initTable[string, string](), intFnBoxes: initHashSet[string]())

proc lookup(env: Env, name: string): string =
  var e = env
  while e != nil:
    if e.locals.hasKey(name): return e.locals[name]
    e = e.parent
  ""

proc isIntLocal(env: Env, name: string): bool =
  ## True when the name's Nim binding is an int64 rather than a Value.
  var e = env
  while e != nil:
    if e.locals.hasKey(name): return e.ints.contains(name)
    e = e.parent
  false

proc lookupIntFn(env: Env, name: string, arity: int): (string, bool) =
  ## The int-specialised entry point for a fn, and whether it returns a Value
  ## (true) or a raw int64 (false).
  let key = name & "/" & $arity
  var e = env
  while e != nil:
    if e.intFns.hasKey(key): return (e.intFns[key], e.intFnBoxes.contains(key))
    if e.locals.hasKey(name): return ("", false)
    e = e.parent
  ("", false)

proc lookupDirect(env: Env, name: string, arity: int): Direct =
  ## A local binding of the same name shadows the direct entry point.
  let key = name & "/" & $arity
  var e = env
  while e != nil:
    if e.directs.hasKey(key): return e.directs[key]
    if e.locals.hasKey(name): return Direct()
    e = e.parent
  Direct()

proc coreName(name: string): string =
  ## Normalize only core names for dispatch, never var or local identity.
  ## Other namespaces must not acquire core optimizations by basename.
  if name.startsWith("clojure.core/"): name[13 .. ^1] else: name

proc primStable(c: Ctx, name: string): bool =
  ## The runtime bridge aliases both core spellings to the same cell.
  let base = coreName(name)
  c.defCounts[base] == 0 and c.defCounts["clojure.core/" & base] == 0

proc fnStable(c: Ctx, name: string): bool =
  ## A user fn is reached by exactly one definition, so the one a call site was
  ## compiled against is the only one it can ever see.
  c.defCounts[name] <= 1

proc line(c: Ctx, s: string) =
  c.body.add repeat("  ", c.indent) & s

proc push(c: Ctx) = inc c.indent
proc pop(c: Ctx) = dec c.indent

proc gensym(c: Ctx, prefix: string): string =
  inc c.counter
  prefix & "_" & $c.counter

proc mangle(name: string): string =
  result = ""
  for ch in name:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9'}: result.add ch
    elif ch == '-': result.add 'X'
    else: result.add 'Y'
  if result.len == 0 or result[0] in {'0'..'9'}: result = "v" & result

proc nimStr(s: string): string =
  result = "\""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '\r': result.add "\\r"
    else:
      if ch.ord < 32: result.add "\\x" & toHex(ch.ord, 2)
      else: result.add ch
  result.add "\""

proc cellFor(c: Ctx, name: string): string =
  ## Resolve each referenced var exactly once, at program start.
  if c.cells.hasKey(name): return c.cells[name]
  inc c.counter
  result = "c_" & $c.counter
  c.cells[name] = result
  c.prelude.add "  let " & result & " = varCell(" & nimStr(name) & ")"

## Builtins with a cheap inline form. A call site at the matching arity emits
## the inline proc directly, guarded on the var still holding the core fn.
const intrinsics = {
  "+/2": "add2", "-/2": "sub2", "*/2": "mul2",
  "</2": "lt2", ">/2": "gt2", "<=/2": "le2", ">=/2": "ge2",
  "=/2": "eq2", "not=/2": "ne2", "inc/1": "inc1", "dec/1": "dec1",
}.toTable

## Heads that compile to statements, never to a single expression.
const specialHeads = ["quote", "if", "do", "let", "let*", "loop", "loop*",
  "recur", "fn", "fn*", "def", "defn", "defn-", "defmacro", "and", "or",
  "when", "when-not", "if-not", "cond", "when-let", "if-let", "->", "->>",
  "doseq", "dotimes", "try", "comment", "ns", "require", "in-ns", "use",
  "import", "set!", "declare"].toHashSet

const intOps = {"+": "+", "-": "-", "*": "*"}.toTable
const intCalls = {"quot": "idiv", "rem": "irem"}.toTable
const cmpOps = {"<": "<", ">": ">", "<=": "<=", ">=": ">=", "=": "==",
                "not=": "!="}.toTable

proc coreFor(c: Ctx, name: string): string =
  ## The value a core builtin had at program start, captured once, so call
  ## sites can tell whether the var still holds it.
  if c.cores.hasKey(name): return c.cores[name]
  let cell = c.cellFor(name)
  inc c.counter
  result = "k_" & $c.counter
  c.cores[name] = result
  c.prelude.add "  let " & result & " = cellGet(" & cell & ")"

proc isSym(v: Value, name: string): bool =
  not v.isNil and v.kind == kSymbol and v.s == name

proc symName(v: Value): string =
  if v.isNil or v.kind != kSymbol: err("Expected a symbol, got: " & prStr(v))
  v.s

# ------------------------------------------------------------- quoted data
proc quoteLit(v: Value): string =
  if v.isNil: return "NilV"
  case v.kind
  of kNil: "NilV"
  of kBool: (if v.b: "TrueV" else: "FalseV")
  of kInt: "mkInt(" & $v.i & ")"
  of kFloat: "mkFloat(" & $v.f & ")"
  of kStr: "mkStr(" & nimStr(v.s) & ")"
  of kKeyword: "mkKeyword(" & nimStr(v.s) & ")"
  of kSymbol: "mkSymbol(" & nimStr(v.s) & ")"
  of kList, kVector, kSet:
    var parts: seq[string] = @[]
    for x in v.items: parts.add quoteLit(x)
    let ctor = (case v.kind
                of kList: "mkList"
                of kVector: "mkVector"
                else: "mkSet")
    ctor & "(@[" & parts.join(", ") & "])" &
      (if parts.len == 0: "" else: "")
  of kMap:
    var parts: seq[string] = @[]
    for (k, val) in v.pairs: parts.add "(" & quoteLit(k) & ", " & quoteLit(val) & ")"
    "mkMap(@[" & parts.join(", ") & "])"
  of kCons, kChunk, kLazy: err("Can't quote a lazy seq")
  of kFn: err("Can't quote a function")

proc emptySeqFix(s: string, elemType: string): string =
  ## `@[]` has no inferable element type in Nim; annotate it.
  s.replace("@[]", "newSeq[" & elemType & "]()")

# ------------------------------------------------------------- code gen
proc genInto(f: Value, dst: string, env: Env, c: Ctx)
proc tryExpr(f: Value, env: Env, c: Ctx): string
proc intExpr(f: Value, env: Env, c: Ctx): string
proc boolExpr(f: Value, env: Env, c: Ctx): string

proc genExpr(f: Value, env: Env, c: Ctx): string =
  ## A Nim expression denoting the form's value. Forms that compile to a single
  ## expression are returned as-is; the rest go through a temporary slot.
  result = tryExpr(f, env, c)
  if result.len > 0: return
  result = c.gensym("t")
  c.line("var " & result & ": Value = NilV")
  genInto(f, result, env, c)

proc genExprTemp(f: Value, env: Env, c: Ctx): string =
  ## Like genExpr, but always materialises the value into a fresh local. Used
  ## where the value is read more than once, or must be computed before a
  ## later statement can overwrite what it reads.
  let e = tryExpr(f, env, c)
  if e.len > 0:
    result = c.gensym("t")
    c.line("let " & result & ": Value = " & e)
    return
  result = c.gensym("t")
  c.line("var " & result & ": Value = NilV")
  genInto(f, result, env, c)

proc genCond(f: Value, env: Env, c: Ctx): string =
  ## A Nim bool for a test position. A comparison between provable integers
  ## becomes a machine compare; anything else falls back to truthy() on a Value.
  result = boolExpr(f, env, c)
  if result.len > 0: return
  result = "truthy(" & genExpr(f, env, c) & ")"

proc genStmt(f: Value, env: Env, c: Ctx) =
  ## A form evaluated only for its effects.
  let e = tryExpr(f, env, c)
  if e.len > 0:
    c.line("discard " & e)
    return
  discard genExpr(f, env, c)

proc genBody(forms: seq[Value], dst: string, env: Env, c: Ctx) =
  if forms.len == 0:
    c.line(dst & " = NilV")
    return
  for i in 0 ..< forms.len - 1:
    genStmt(forms[i], env, c)
  genInto(forms[^1], dst, env, c)

type
  FnClause = object
    params: seq[string]
    restParam: string
    body: seq[Value]

proc parseParams(v: Value): FnClause =
  if v.isNil or v.kind != kVector: err("Parameter list must be a vector, got: " & prStr(v))
  result = FnClause(params: @[], restParam: "", body: @[])
  var i = 0
  while i < v.items.len:
    let p = v.items[i]
    if isSym(p, "&"):
      if i + 1 >= v.items.len: err("Missing symbol after &")
      result.restParam = symName(v.items[i + 1])
      break
    result.params.add symName(p)
    inc i

proc genClauseBody(cl: FnClause, name, selfIdent: string, env: Env, c: Ctx,
                   bindTo: proc (i: int, p: string): string, res: string,
                   selfDirect = "", intParams = false) =
  ## Shared between the positional proc and the generic dispatcher: bind the
  ## params to mutable locals (recur assigns them), then run the body.
  let fenv = newEnv(env)
  if selfIdent.len > 0 and name.len > 0:
    fenv.locals[name] = selfIdent
  # Registered alongside the self local, and checked first, so a self-call at
  # the matching arity reaches the positional proc rather than the fn Value.
  if selfDirect.len > 0:
    fenv.directs[name & "/" & $cl.params.len] = Direct(prc: selfDirect)
  var recurIdents: seq[string] = @[]
  for i, p in cl.params:
    let id = c.gensym("p" & mangle(p))
    c.line("var " & id & (if intParams: ": int64 = " else: ": Value = ") &
           bindTo(i, p))
    fenv.locals[p] = id
    if intParams: fenv.ints.incl p
    recurIdents.add id
  if cl.restParam.len > 0:
    let id = c.gensym("p" & mangle(cl.restParam))
    c.line("var " & id & ": Value = " & bindTo(-1, cl.restParam))
    fenv.locals[cl.restParam] = id
  c.line("var " & res & ": Value = NilV")
  c.line("while true:")
  c.push
  c.recurStack.add recurIdents
  var recurIsInt = newSeq[bool](recurIdents.len)
  if intParams:
    for j in 0 ..< recurIsInt.len: recurIsInt[j] = true
  c.recurInts.add recurIsInt
  genBody(cl.body, res, fenv, c)
  discard c.recurStack.pop
  discard c.recurInts.pop
  c.line("break")
  c.pop

proc collectRecurs(forms: seq[Value], into: var seq[seq[Value]]) =
  ## The recur forms belonging to the innermost enclosing loop. Nested fn and
  ## loop forms establish their own recur target, so their bodies are skipped.
  for f in forms:
    if f.isNil or f.kind != kList or f.items.len == 0: continue
    let head = f.items[0]
    if head.kind == kSymbol:
      if coreName(head.s) == "recur":
        into.add f.items[1 .. ^1]
        continue
      if coreName(head.s) in ["loop", "loop*", "fn", "fn*", "defn", "defn-"]: continue
    collectRecurs(f.items, into)

proc usesIntPrim(c: Ctx, forms: seq[Value]): bool =
  ## Whether an int-specialised twin could differ from the generic proc at all.
  ## Emitting one for a fn that never does arithmetic just doubles the work Nim
  ## has to do; this gate is an optimisation only, never a semantic decision.
  for f in forms:
    if f.isNil or f.kind != kList or f.items.len == 0: continue
    let head = f.items[0]
    if head.kind == kSymbol and c.primStable(head.s) and
       (intOps.hasKey(coreName(head.s)) or intCalls.hasKey(coreName(head.s)) or
        cmpOps.hasKey(coreName(head.s)) or coreName(head.s) in ["inc", "dec"]):
      return true
    if usesIntPrim(c, f.items): return true
  false

proc genFn(name: string, clauses: seq[FnClause], selfIdent: string, env: Env,
           c: Ctx, dst: string, directEnv: Env = nil, cell = "") =
  ## Each fixed-arity clause gets a real Nim proc taking its params
  ## positionally; the mkFn wrapper is just an arity dispatcher onto those, and
  ## call sites that know the arity skip the wrapper entirely.
  var directProcs: seq[string] = @[]   # parallel to clauses, "" for variadic
  for cl in clauses:
    if cl.restParam.len > 0:
      directProcs.add ""
      continue
    let prc = c.gensym("uf" & mangle(if name.len > 0: name else: "fn"))
    var params: seq[string] = @[]
    for i in 0 ..< cl.params.len: params.add "a" & $i & ": Value"
    c.line("proc " & prc & "(" & params.join(", ") & "): Value =")
    c.push
    let res = c.gensym("res")
    # selfDirect makes a self-call at this arity a plain recursive Nim call.
    genClauseBody(cl, name, selfIdent, env, c,
                  proc (i: int, p: string): string = "a" & $i, res, prc)
    c.line("return " & res)
    c.pop
    directProcs.add prc
    if directEnv != nil:
      directEnv.directs[name & "/" & $cl.params.len] =
        Direct(prc: prc, cell: cell, fnVal: dst)

    # An int-specialised twin, so a caller with integer arguments never boxes
    # them. Emitted beside the generic proc rather than replacing it: callers
    # that cannot prove their arguments are integers still need the Value one.
    if name.len > 0 and cl.params.len > 0 and c.usesIntPrim(cl.body):
      let key = name & "/" & $cl.params.len
      let iprc = c.gensym("ufi" & mangle(name))
      # Does the body yield an integer? Probe with the parameters typed and the
      # fn optimistically assumed to return one, so self-recursion types too.
      # A recur inside the clause reassigns the parameters, so every recur
      # value has to stay integral too. Anything less and the twin is dropped
      # rather than emitted with a mix of int64 and Value parameters.
      let probe = newEnv(env)
      for i, p in cl.params:
        probe.locals[p] = "a" & $i
        probe.ints.incl p
      probe.intFns[key] = iprc
      var recurSafe = true
      var myRecurs: seq[seq[Value]] = @[]
      collectRecurs(cl.body, myRecurs)
      for r in myRecurs:
        if r.len != cl.params.len: recurSafe = false; break
        for a in r:
          if intExpr(a, probe, c).len == 0: recurSafe = false; break
        if not recurSafe: break
      var boxes = true
      if cl.body.len == 1 and intExpr(cl.body[0], probe, c).len > 0:
        boxes = false
      if recurSafe:
        var iparams: seq[string] = @[]
        for i in 0 ..< cl.params.len: iparams.add "a" & $i & ": int64"
        c.line("proc " & iprc & "(" & iparams.join(", ") & "): " &
               (if boxes: "Value" else: "int64") & " =")
        c.push
        let ienv = newEnv(env)
        ienv.intFns[key] = iprc
        if boxes: ienv.intFnBoxes.incl key
        if boxes:
          let ires = c.gensym("res")
          genClauseBody(cl, name, selfIdent, ienv, c,
                        proc (i: int, p: string): string = "a" & $i, ires, "", true)
          c.line("return " & ires)
        else:
          for i, p in cl.params:
            ienv.locals[p] = "a" & $i
            ienv.ints.incl p
          c.line("return " & intExpr(cl.body[0], ienv, c))
        c.pop
        if directEnv != nil and c.fnStable(name):
          directEnv.intFns[key] = iprc
          if boxes: directEnv.intFnBoxes.incl key

  let argsIdent = c.gensym("args")
  c.line(dst & " = mkFn(" & nimStr(name) & ", proc (" & argsIdent & ": openArray[Value]): Value =")
  c.push
  var first = true
  for ci, cl in clauses:
    let cond =
      if cl.restParam.len > 0: argsIdent & ".len >= " & $cl.params.len
      else: argsIdent & ".len == " & $cl.params.len
    c.line((if first: "if " else: "elif ") & cond & ":")
    first = false
    c.push
    if directProcs[ci].len > 0:
      var fwd: seq[string] = @[]
      for i in 0 ..< cl.params.len: fwd.add "argAt(" & argsIdent & ", " & $i & ")"
      c.line("return " & directProcs[ci] & "(" & fwd.join(", ") & ")")
    else:
      let res = c.gensym("res")
      genClauseBody(cl, name, selfIdent, env, c,
        proc (i: int, p: string): string =
          if i < 0: "restArgs(" & argsIdent & ", " & $cl.params.len & ")"
          else: "argAt(" & argsIdent & ", " & $i & ")", res)
      c.line("return " & res)
    c.pop
  c.line("else:")
  c.push
  c.line("err(\"Wrong number of args (\" & $" & argsIdent & ".len & \") passed to " &
         (if name.len > 0: name else: "fn") & "\")")
  c.pop
  c.pop
  c.line(")")

proc genFnForm(args: seq[Value], env: Env, c: Ctx, dst: string, defName: string,
               directEnv: Env = nil, cell = "") =
  ## (fn name? [params] body...) or (fn name? ([params] body...) ...)
  var i = 0
  var name = defName
  var selfIdent = ""
  if i < args.len and not args[i].isNil and args[i].kind == kSymbol:
    name = symName(args[i]); inc i
  var clauses: seq[FnClause] = @[]
  if i < args.len and args[i].kind == kVector:
    var cl = parseParams(args[i])
    cl.body = args[i + 1 .. ^1]
    clauses.add cl
  else:
    while i < args.len:
      let cf = args[i]
      if cf.kind != kList or cf.items.len == 0: err("Bad fn arity form: " & prStr(cf))
      var cl = parseParams(cf.items[0])
      cl.body = cf.items[1 .. ^1]
      clauses.add cl
      inc i
  if clauses.len == 0: err("fn requires at least one arity")
  if name.len > 0:
    # bind the fn to a local so it can recur by name
    selfIdent = c.gensym("self" & mangle(name))
    c.line("var " & selfIdent & ": Value = NilV")
    genFn(name, clauses, selfIdent, env, c, selfIdent, directEnv, cell)
    c.line(dst & " = " & selfIdent)
  else:
    genFn("fn", clauses, "", env, c, dst)

proc genLet(bindings: Value, body: seq[Value], dst: string, env: Env, c: Ctx) =
  if bindings.isNil or bindings.kind != kVector:
    err("let requires a vector for its bindings")
  if bindings.items.len mod 2 != 0:
    err("let requires an even number of forms in its binding vector")
  let lenv = newEnv(env)
  var i = 0
  while i < bindings.items.len:
    let target = bindings.items[i]
    let initForm = bindings.items[i + 1]
    let v = genExpr(initForm, lenv, c)
    if target.kind == kSymbol:
      let id = c.gensym("l" & mangle(target.s))
      c.line("var " & id & ": Value = " & v)
      lenv.locals[target.s] = id
    elif target.kind == kVector:
      # sequential destructuring: [a b & rest]
      var idx = 0
      var j = 0
      while j < target.items.len:
        let p = target.items[j]
        if isSym(p, "&"):
          let restSym = symName(target.items[j + 1])
          let id = c.gensym("l" & mangle(restSym))
          c.line("var " & id & ": Value = seqDrop(" & v & ", " & $idx & ")")
          lenv.locals[restSym] = id
          break
        let id = c.gensym("l" & mangle(symName(p)))
        c.line("var " & id & ": Value = call(getVar(\"clojure.core/nth\"), [" & v & ", mkInt(" &
               $idx & "), NilV])")
        lenv.locals[symName(p)] = id
        inc idx; inc j
    elif target.kind == kMap:
      # associative destructuring: {a :a, :keys [b c]}
      for (k, valForm) in target.pairs:
        if k.kind == kKeyword and k.s == "keys":
          for ks in valForm.items:
            let nm = symName(ks)
            let id = c.gensym("l" & mangle(nm))
            c.line("var " & id & ": Value = call(getVar(\"clojure.core/get\"), [" & v &
                   ", mkKeyword(" & nimStr(nm) & ")])")
            lenv.locals[nm] = id
        else:
          let nm = symName(k)
          let id = c.gensym("l" & mangle(nm))
          let kv = genExpr(valForm, lenv, c)
          c.line("var " & id & ": Value = call(getVar(\"clojure.core/get\"), [" & v & ", " & kv & "])")
          lenv.locals[nm] = id
    else:
      err("Unsupported binding form: " & prStr(target))
    i += 2
  genBody(body, dst, lenv, c)

proc genLoop(bindings: Value, body: seq[Value], dst: string, env: Env, c: Ctx) =
  if bindings.isNil or bindings.kind != kVector or bindings.items.len mod 2 != 0:
    err("loop requires an even-sized binding vector")
  var names: seq[string] = @[]
  var inits: seq[Value] = @[]
  var i = 0
  while i < bindings.items.len:
    names.add symName(bindings.items[i])
    inits.add bindings.items[i + 1]
    i += 2

  # Which loop variables can be held as raw int64? A variable qualifies when
  # its initialiser is provably an integer and so is every recur value for its
  # slot. Those recur values usually mention the loop variables themselves, so
  # start optimistic and demote until the set stops shrinking.
  var recurs: seq[seq[Value]] = @[]
  collectRecurs(body, recurs)
  for r in recurs:
    if r.len != names.len: recurs = @[]; break   # arity error, reported later
  var isInt: seq[bool] = @[]
  for n in names: isInt.add true
  var probeIdents: seq[string] = @[]
  for n in names: probeIdents.add "probe"
  while true:
    let probe = newEnv(env)
    for j, n in names:
      probe.locals[n] = probeIdents[j]
      if isInt[j]: probe.ints.incl n
    var changed = false
    for j, n in names:
      if not isInt[j]: continue
      # an initialiser only sees the bindings before it, as in let
      let ienv = newEnv(env)
      for k in 0 ..< j:
        ienv.locals[names[k]] = probeIdents[k]
        if isInt[k]: ienv.ints.incl names[k]
      if intExpr(inits[j], ienv, c).len == 0:
        isInt[j] = false; changed = true; continue
      for r in recurs:
        if intExpr(r[j], probe, c).len == 0:
          isInt[j] = false; changed = true; break
    if not changed: break

  let lenv = newEnv(env)
  var idents: seq[string] = @[]
  for j, n in names:
    let id = c.gensym("l" & mangle(n))
    if isInt[j]:
      c.line("var " & id & ": int64 = " & intExpr(inits[j], lenv, c))
    else:
      c.line("var " & id & ": Value = " & genExpr(inits[j], lenv, c))
    lenv.locals[n] = id
    if isInt[j]: lenv.ints.incl n
    idents.add id
  c.line("while true:")
  c.push
  c.recurStack.add idents
  c.recurInts.add isInt
  genBody(body, dst, lenv, c)
  discard c.recurStack.pop
  discard c.recurInts.pop
  c.line("break")
  c.pop

proc fusableStage(c: Ctx, env: Env, f: Value): bool =
  ## A map/filter/remove call whose result is this expression and nothing else.
  if f.kind != kList or f.items.len != 3: return false
  let h = f.items[0]
  if h.kind != kSymbol: return false
  if coreName(h.s) notin ["map", "filter", "remove"]: return false
  env.lookup(h.s).len == 0 and c.primStable(h.s)

proc fusableCall(c: Ctx, env: Env, head: string, args: seq[Value]): bool =
  ## Whether this is a pipeline tryFuse will take.
  if env.lookup(head).len > 0 or not c.primStable(head): return false
  var collIdx = -1
  if coreName(head) == "reduce" and args.len in {2, 3}: collIdx = args.len - 1
  elif coreName(head) == "count" and args.len == 1: collIdx = 0
  else: return false
  c.fusableStage(env, args[collIdx])

proc tryFuse(c: Ctx, env: Env, head: string, args: seq[Value],
             dst: string): bool =
  ## `(reduce f (map g (filter p src)))` and `(count (map g src))` build their
  ## intermediate sequences only to walk them once. Those intermediates are
  ## temporaries -- no name refers to them, so nothing can observe their
  ## memoisation -- which makes it safe to run the whole chain as one loop.
  ## A named pipeline is left alone: `(def ys (map f xs))` must still cache.
  if not c.fusableCall(env, head, args): return false
  let collIdx = (if coreName(head) == "count": 0 else: args.len - 1)

  # Operands are emitted in source order: the reducing fn, then each stage's
  # fn from outermost in, then the base. That is the order Clojure evaluates
  # them in, and the order the unfused calls would have used.
  var fixed: seq[string] = @[]
  for i in 0 ..< collIdx: fixed.add genExprTemp(args[i], env, c)
  var ops: seq[string] = @[]
  var cur = args[collIdx]
  while c.fusableStage(env, cur):
    let stage = coreName(symName(cur.items[0]))
    let fnIdent = genExprTemp(cur.items[1], env, c)
    ops.add(if stage == "map": "FusedOp(isMap: true, fn: " & fnIdent & ")"
            else: "FusedOp(isMap: false, fn: " & fnIdent & ", keep: " &
                  (if stage == "filter": "true" else: "false") & ")")
    cur = cur.items[2]
  let baseIdent = genExprTemp(cur, env, c)
  let opsLit = "[" & ops.join(", ") & "]"
  if coreName(head) == "count":
    c.line(dst & " = fusedCount(" & baseIdent & ", " & opsLit & ")")
  elif fixed.len == 1:
    c.line(dst & " = fusedReduce(" & fixed[0] & ", NilV, false, " &
           baseIdent & ", " & opsLit & ")")
  else:
    c.line(dst & " = fusedReduce(" & fixed[0] & ", " & fixed[1] & ", true, " &
           baseIdent & ", " & opsLit & ")")
  true

proc genCall(f: Value, args: seq[Value], dst: string, env: Env, c: Ctx) =
  # A call to a fn whose arity is known here becomes a direct Nim call: no
  # argument seq, no closure dispatch. When the target came from `def` the
  # name can still be rebound at runtime, so guard on the var cell.
  if f.kind == kSymbol:
    let d = lookupDirect(env, f.s, args.len)
    if d.prc.len > 0:
      var argIdents: seq[string] = @[]
      for a in args: argIdents.add genExprTemp(a, env, c)
      let direct = d.prc & "(" & argIdents.join(", ") & ")"
      if d.cell.len == 0:
        c.line(dst & " = " & direct)
      else:
        c.line("if cellIs(" & d.cell & ", " & d.fnVal & "):")
        c.push; c.line(dst & " = " & direct); c.pop
        c.line("else:")
        c.push
        c.line(dst & " = call(cellGet(" & d.cell & "), " &
               (if argIdents.len == 0: "emptyArgs" else: "[" & argIdents.join(", ") & "]") & ")")
        c.pop
      return
    let key = coreName(f.s) & "/" & $args.len
    if intrinsics.hasKey(key) and env.lookup(f.s).len == 0 and
       c.primStable(f.s):
      var argIdents: seq[string] = @[]
      for a in args: argIdents.add genExprTemp(a, env, c)
      c.line(dst & " = " & intrinsics[key] & "(" & argIdents.join(", ") & ")")
      return
    if intrinsics.hasKey(key) and env.lookup(f.s).len == 0:
      var argIdents: seq[string] = @[]
      for a in args: argIdents.add genExprTemp(a, env, c)
      let cell = c.cellFor(f.s)
      let k = c.coreFor(f.s)
      c.line("if cellIs(" & cell & ", " & k & "):")
      c.push
      c.line(dst & " = " & intrinsics[key] & "(" & argIdents.join(", ") & ")")
      c.pop
      c.line("else:")
      c.push
      c.line(dst & " = call(cellGet(" & cell & "), [" & argIdents.join(", ") & "])")
      c.pop
      return
  let fv = genExprTemp(f, env, c)
  var argIdents: seq[string] = @[]
  for a in args: argIdents.add genExprTemp(a, env, c)
  if argIdents.len == 0:
    c.line(dst & " = call(" & fv & ", emptyArgs)")
  else:
    c.line(dst & " = call(" & fv & ", [" & argIdents.join(", ") & "])")

## ------------------------------------------------------- int specialisation
##
## The remaining cost of a numeric loop is that every intermediate integer is a
## 24-byte Value moving through memory. These two compile a form straight to a
## Nim int64 or bool expression when that is provably what it yields, so the C
## compiler sees an ordinary integer loop and can keep it in registers.
##
## "Provably" leans on primStable: with no eval, no defmacro and no def of the
## name anywhere in the program, `+` is arithmetic for the life of the process,
## so no runtime guard is needed on this path.

proc intExpr(f: Value, env: Env, c: Ctx): string =
  ## A Nim int64 expression, or "" when the form is not provably an integer.
  case f.kind
  of kInt:
    "int64(" & $f.i & ")"
  of kSymbol:
    if env.isIntLocal(f.s): env.lookup(f.s) else: ""
  of kList:
    if f.items.len == 0: return ""
    let head = f.items[0]
    if head.kind != kSymbol: return ""
    let args = f.items[1 .. ^1]
    # (if c a b) is an int when both arms are
    if coreName(head.s) == "if" and args.len == 3:
      let cond = boolExpr(args[0], env, c)
      if cond.len == 0: return ""
      let a = intExpr(args[1], env, c)
      if a.len == 0: return ""
      let b = intExpr(args[2], env, c)
      if b.len == 0: return ""
      return "(if " & cond & ": " & a & " else: " & b & ")"
    if specialHeads.contains(coreName(head.s)): return ""
    if env.lookup(head.s).len == 0 and c.primStable(head.s):
      if args.len == 2 and (intOps.hasKey(coreName(head.s)) or intCalls.hasKey(coreName(head.s))):
        let a = intExpr(args[0], env, c)
        if a.len == 0: return ""
        let b = intExpr(args[1], env, c)
        if b.len == 0: return ""
        if intCalls.hasKey(coreName(head.s)):
          return intCalls[coreName(head.s)] & "(" & a & ", " & b & ")"
        return "(" & a & " " & intOps[coreName(head.s)] & " " & b & ")"
      if args.len == 1 and (coreName(head.s) == "inc" or coreName(head.s) == "dec"):
        let a = intExpr(args[0], env, c)
        if a.len == 0: return ""
        return "(" & a & (if coreName(head.s) == "inc": " + 1" else: " - 1") & ")"
    # a call to an int-specialised fn that returns a raw int64
    let (prc, boxes) = env.lookupIntFn(head.s, args.len)
    if prc.len > 0 and not boxes:
      var ids: seq[string] = @[]
      for a in args:
        let e = intExpr(a, env, c)
        if e.len == 0: return ""
        ids.add e
      return prc & "(" & ids.join(", ") & ")"
    ""
  else:
    ""

proc boolExpr(f: Value, env: Env, c: Ctx): string =
  ## A Nim bool expression for a comparison between provable integers.
  if f.kind != kList or f.items.len != 3: return ""
  let head = f.items[0]
  if head.kind != kSymbol or not cmpOps.hasKey(coreName(head.s)): return ""
  if env.lookup(head.s).len > 0 or not c.primStable(head.s): return ""
  let a = intExpr(f.items[1], env, c)
  if a.len == 0: return ""
  let b = intExpr(f.items[2], env, c)
  if b.len == 0: return ""
  "(" & a & " " & cmpOps[coreName(head.s)] & " " & b & ")"

proc tryExprs(xs: seq[Value], env: Env, c: Ctx, ids: var seq[string]): bool =
  ## All-or-nothing: if any subform needs statements, the caller must fall back
  ## for every one of them, or an earlier operand could be read after a later
  ## operand's statements have run.
  for x in xs:
    let e = tryExpr(x, env, c)
    if e.len == 0: return false
    ids.add e
  true

proc tryExpr(f: Value, env: Env, c: Ctx): string =
  ## Compile a form to a single Nim expression, or "" if it needs statements.
  ## Keeping a subexpression as an expression is what lets the C compiler hold
  ## it in a register instead of round-tripping it through a Value slot.
  case f.kind
  of kNil, kBool, kInt, kFloat, kStr, kKeyword:
    quoteLit(f)
  of kSymbol:
    let local = env.lookup(f.s)
    if local.len == 0: return "cellGet(" & c.cellFor(f.s) & ")"
    if env.isIntLocal(f.s): "mkInt(" & local & ")" else: local
  of kVector, kSet:
    var ids: seq[string] = @[]
    if not tryExprs(f.items, env, c, ids): return ""
    (if f.kind == kVector: "mkVector(" else: "mkSet(") &
      (if ids.len == 0: "newSeq[Value]()" else: "@[" & ids.join(", ") & "]") & ")"
  of kMap:
    var parts: seq[string] = @[]
    for (k, v) in f.pairs:
      let ke = tryExpr(k, env, c)
      if ke.len == 0: return ""
      let ve = tryExpr(v, env, c)
      if ve.len == 0: return ""
      parts.add "(" & ke & ", " & ve & ")"
    "mkMap(" & (if parts.len == 0: "newSeq[(Value, Value)]()"
                else: "@[" & parts.join(", ") & "]") & ")"
  of kList:
    if f.items.len == 0: return "mkList(newSeq[Value]())"
    let head = f.items[0]
    let args = f.items[1 .. ^1]
    if head.kind == kSymbol and specialHeads.contains(coreName(head.s)): return ""
    # A fusable pipeline is compiled as statements, so its operands are
    # evaluated in source order rather than in Nim argument order.
    if head.kind == kSymbol and c.fusableCall(env, head.s, args): return ""
    var ids: seq[string] = @[]
    if not tryExprs(args, env, c, ids): return ""
    if head.kind == kSymbol:
      let (iprc, iboxes) = env.lookupIntFn(head.s, args.len)
      if iprc.len > 0:
        var iids: seq[string] = @[]
        var ok = true
        for a in args:
          let e = intExpr(a, env, c)
          if e.len == 0: ok = false; break
          iids.add e
        if ok:
          let callI = iprc & "(" & iids.join(", ") & ")"
          return (if iboxes: callI else: "mkInt(" & callI & ")")
      let d = lookupDirect(env, head.s, args.len)
      if d.prc.len > 0 and (d.cell.len == 0 or c.fnStable(head.s)):
        # a self-call, or a name only one def form ever targets
        return d.prc & "(" & ids.join(", ") & ")"
      if d.prc.len == 0:
        let key = coreName(head.s) & "/" & $args.len
        if intrinsics.hasKey(key) and env.lookup(head.s).len == 0:
          if c.primStable(head.s):
            return intrinsics[key] & "(" & ids.join(", ") & ")"
          return intrinsics[key] & "g(" & c.cellFor(head.s) & ", " &
                 c.coreFor(head.s) & ", " & ids.join(", ") & ")"
    let hv = tryExpr(head, env, c)
    if hv.len == 0: return ""
    "call(" & hv & ", " &
      (if ids.len == 0: "emptyArgs" else: "[" & ids.join(", ") & "]") & ")"
  of kFn, kCons, kChunk, kLazy:
    ""

proc genInto(f: Value, dst: string, env: Env, c: Ctx) =
  if f.isNil:
    c.line(dst & " = NilV"); return
  let e = tryExpr(f, env, c)
  if e.len > 0:
    c.line(dst & " = " & e); return
  case f.kind
  of kNil, kBool, kInt, kFloat, kStr, kKeyword:
    c.line(dst & " = " & quoteLit(f))
  of kSymbol:
    let local = env.lookup(f.s)
    if local.len > 0: c.line(dst & " = " & local)
    else: c.line(dst & " = cellGet(" & c.cellFor(f.s) & ")")
  of kVector:
    var ids: seq[string] = @[]
    for x in f.items: ids.add genExprTemp(x, env, c)
    c.line(dst & " = mkVector(" &
      (if ids.len == 0: "newSeq[Value]()" else: "@[" & ids.join(", ") & "]") & ")")
  of kSet:
    var ids: seq[string] = @[]
    for x in f.items: ids.add genExprTemp(x, env, c)
    c.line(dst & " = mkSet(" &
      (if ids.len == 0: "newSeq[Value]()" else: "@[" & ids.join(", ") & "]") & ")")
  of kMap:
    var parts: seq[string] = @[]
    for (k, v) in f.pairs:
      let ki = genExprTemp(k, env, c)
      let vi = genExprTemp(v, env, c)
      parts.add "(" & ki & ", " & vi & ")"
    c.line(dst & " = mkMap(" &
      (if parts.len == 0: "newSeq[(Value, Value)]()" else: "@[" & parts.join(", ") & "]") & ")")
  of kFn:
    err("Can't emit a function literal")
  of kCons, kChunk, kLazy:
    err("Can't emit a lazy seq literal")
  of kList:
    if f.items.len == 0:
      c.line(dst & " = mkList(newSeq[Value]())"); return
    let head = f.items[0]
    let args = f.items[1 .. ^1]
    if head.kind == kSymbol and c.tryFuse(env, head.s, args, dst): return
    if head.kind == kSymbol:
      case coreName(head.s)
      of "quote":
        c.line(dst & " = " & quoteLit(args[0]))
        return
      of "if":
        if args.len < 2: err("Too few arguments to if")
        c.line("if " & genCond(args[0], env, c) & ":")
        c.push; genInto(args[1], dst, env, c); c.pop
        c.line("else:")
        c.push
        if args.len > 2: genInto(args[2], dst, env, c)
        else: c.line(dst & " = NilV")
        c.pop
        return
      of "do":
        genBody(args, dst, env, c)
        return
      of "let", "let*":
        if args.len == 0: err("let requires bindings")
        genLet(args[0], args[1 .. ^1], dst, env, c)
        return
      of "loop", "loop*":
        if args.len == 0: err("loop requires bindings")
        genLoop(args[0], args[1 .. ^1], dst, env, c)
        return
      of "recur":
        if c.recurStack.len == 0: err("recur outside of loop or fn")
        let targets = c.recurStack[^1]
        if targets.len != args.len:
          err("Mismatched argument count to recur: expected " & $targets.len &
              ", got " & $args.len)
        let targetInts = c.recurInts[^1]
        var tmps: seq[string] = @[]
        for i, a in args:
          if targetInts[i]:
            let e = intExpr(a, env, c)
            let t = c.gensym("t")
            c.line("let " & t & ": int64 = " & e)
            tmps.add t
          else:
            tmps.add genExprTemp(a, env, c)
        for i, t in tmps: c.line(targets[i] & " = " & t)
        c.line("continue")
        return
      of "fn", "fn*":
        genFnForm(args, env, c, dst, "")
        return
      of "def":
        if args.len == 0: err("def requires a name")
        let nm = symName(args[0])
        c.defined.incl nm
        var body = args[1 .. ^1]
        # drop a docstring: (def x "doc" val) / (defn ...) handled separately
        if body.len == 0:
          c.line(dst & " = setVar(" & nimStr(nm) & ", NilV)")
        else:
          let v = genExpr(body[^1], env, c)
          c.line(dst & " = setVar(" & nimStr(nm) & ", " & v & ")")
        return
      of "defn", "defn-":
        if args.len < 2: err("defn requires a name and a parameter vector")
        let nm = symName(args[0])
        c.defined.incl nm
        var rest = args[1 .. ^1]
        if rest.len > 0 and rest[0].kind == kStr: rest = rest[1 .. ^1]  # docstring
        if rest.len > 0 and rest[0].kind == kMap: rest = rest[1 .. ^1]  # attr map
        let fv = c.gensym("fn")
        c.line("var " & fv & ": Value = NilV")
        genFnForm(rest, env, c, fv, nm, env, c.cellFor(nm))
        c.line(dst & " = setVar(" & nimStr(nm) & ", " & fv & ")")
        return
      of "defmacro":
        err("defmacro is not supported yet (clonim expands a fixed macro set)")
      of "and":
        if args.len == 0: c.line(dst & " = TrueV"); return
        c.line(dst & " = TrueV")
        var depth = 0
        for i, a in args:
          genInto(a, dst, env, c)
          if i < args.len - 1:
            c.line("if truthy(" & dst & "):")
            c.push; inc depth
        for _ in 0 ..< depth: c.pop
        return
      of "or":
        if args.len == 0: c.line(dst & " = NilV"); return
        c.line(dst & " = NilV")
        var depth = 0
        for i, a in args:
          genInto(a, dst, env, c)
          if i < args.len - 1:
            c.line("if not truthy(" & dst & "):")
            c.push; inc depth
        for _ in 0 ..< depth: c.pop
        return
      of "when":
        if args.len == 0: err("when requires a test")
        c.line("if " & genCond(args[0], env, c) & ":")
        c.push; genBody(args[1 .. ^1], dst, env, c); c.pop
        c.line("else:")
        c.push; c.line(dst & " = NilV"); c.pop
        return
      of "when-not":
        c.line("if not (" & genCond(args[0], env, c) & "):")
        c.push; genBody(args[1 .. ^1], dst, env, c); c.pop
        c.line("else:")
        c.push; c.line(dst & " = NilV"); c.pop
        return
      of "if-not":
        c.line("if not (" & genCond(args[0], env, c) & "):")
        c.push; genInto(args[1], dst, env, c); c.pop
        c.line("else:")
        c.push
        if args.len > 2: genInto(args[2], dst, env, c) else: c.line(dst & " = NilV")
        c.pop
        return
      of "cond":
        if args.len mod 2 != 0: err("cond requires an even number of forms")
        c.line(dst & " = NilV")
        var depth = 0
        var i = 0
        while i < args.len:
          if isSym(args[i], "else") or (args[i].kind == kKeyword and args[i].s == "else"):
            genInto(args[i + 1], dst, env, c)
            break
          c.line("if " & genCond(args[i], env, c) & ":")
          c.push
          genInto(args[i + 1], dst, env, c)
          c.pop
          c.line("else:")
          c.push; inc depth
          i += 2
        for _ in 0 ..< depth: c.pop
        return
      of "when-let", "if-let":
        let b = args[0]
        if b.kind != kVector or b.items.len != 2: err(head.s & " requires [sym test]")
        let nm = symName(b.items[0])
        let id = c.gensym("l" & mangle(nm))
        c.line("var " & id & ": Value = " & genExpr(b.items[1], env, c))
        c.line("if truthy(" & id & "):")
        c.push
        let benv = newEnv(env)
        benv.locals[nm] = id
        if coreName(head.s) == "when-let": genBody(args[1 .. ^1], dst, benv, c)
        else: genInto(args[1], dst, benv, c)
        c.pop
        c.line("else:")
        c.push
        if coreName(head.s) == "if-let" and args.len > 2: genInto(args[2], dst, env, c)
        else: c.line(dst & " = NilV")
        c.pop
        return
      of "->":
        var acc = args[0]
        for i in 1 ..< args.len:
          let step = args[i]
          if step.kind == kList:
            acc = mkList(@[step.items[0], acc] & step.items[1 .. ^1])
          else:
            acc = mkList(@[step, acc])
        genInto(acc, dst, env, c)
        return
      of "->>":
        var acc = args[0]
        for i in 1 ..< args.len:
          let step = args[i]
          if step.kind == kList:
            acc = mkList(step.items & @[acc])
          else:
            acc = mkList(@[step, acc])
        genInto(acc, dst, env, c)
        return
      of "doseq":
        let b = args[0]
        if b.kind != kVector or b.items.len != 2: err("doseq requires [sym coll]")
        let nm = symName(b.items[0])
        let cv = genExpr(b.items[1], env, c)
        let it = c.gensym("it")
        c.line("for " & it & " in elems(" & cv & "):")
        c.push
        let benv = newEnv(env)
        let id = c.gensym("l" & mangle(nm))
        c.line("var " & id & ": Value = " & it)
        benv.locals[nm] = id
        let throwaway = c.gensym("t")
        c.line("var " & throwaway & ": Value = NilV")
        genBody(args[1 .. ^1], throwaway, benv, c)
        c.pop
        c.line(dst & " = NilV")
        return
      of "dotimes":
        let b = args[0]
        if b.kind != kVector or b.items.len != 2: err("dotimes requires [sym n]")
        let nm = symName(b.items[0])
        let cv = genExpr(b.items[1], env, c)
        let it = c.gensym("i")
        c.line("for " & it & " in 0 ..< int(" & cv & ".i):")
        c.push
        let benv = newEnv(env)
        let id = c.gensym("l" & mangle(nm))
        c.line("var " & id & ": Value = mkInt(int64(" & it & "))")
        benv.locals[nm] = id
        let throwaway = c.gensym("t")
        c.line("var " & throwaway & ": Value = NilV")
        genBody(args[1 .. ^1], throwaway, benv, c)
        c.pop
        c.line(dst & " = NilV")
        return
      of "try":
        var bodyForms: seq[Value] = @[]
        var catchSym = ""
        var catchBody: seq[Value] = @[]
        var finallyBody: seq[Value] = @[]
        for a in args:
          if a.kind == kList and a.items.len > 0 and isSym(a.items[0], "catch"):
            catchSym = symName(a.items[2])
            catchBody = a.items[3 .. ^1]
          elif a.kind == kList and a.items.len > 0 and isSym(a.items[0], "finally"):
            finallyBody = a.items[1 .. ^1]
          else:
            bodyForms.add a
        c.line("try:")
        c.push; genBody(bodyForms, dst, env, c); c.pop
        if catchSym.len > 0:
          c.line("except CatchableError as " & c.gensym("e") & "X:")
          c.push
          let benv = newEnv(env)
          let id = c.gensym("l" & mangle(catchSym))
          c.line("var " & id & ": Value = mkStr(getCurrentExceptionMsg())")
          benv.locals[catchSym] = id
          genBody(catchBody, dst, benv, c)
          c.pop
        if finallyBody.len > 0:
          c.line("finally:")
          c.push
          let throwaway = c.gensym("t")
          c.line("var " & throwaway & ": Value = NilV")
          genBody(finallyBody, throwaway, env, c)
          c.pop
        return
      of "comment":
        c.line(dst & " = NilV")
        return
      of "ns", "require", "in-ns", "use", "import", "set!", "declare":
        c.line(dst & " = NilV")
        return
      else: discard
    genCall(head, args, dst, env, c)

# ------------------------------------------------------------- entry point
const preamble = """
## Generated by clonim. Do not edit.
import app_runtime

proc cljMain() =
"""

proc collectDefs(f: Value, into: var CountTable[string]) =
  ## Every name this program can rebind at runtime. `def` and `defn` are the
  ## only paths to setVar, and clonim has no eval, no defmacro and no intern,
  ## so a name that no def form targets holds whatever registerCore gave it for
  ## the life of the process. That is what lets call sites drop the cell guard
  ## and lets the analyzer trust `+` to be arithmetic.
  if f.isNil or f.kind != kList or f.items.len == 0: return
  let head = f.items[0]
  if head.kind == kSymbol and coreName(head.s) in ["def", "defn", "defn-"] and
     f.items.len > 1 and f.items[1].kind == kSymbol:
    into.inc f.items[1].s
  for x in f.items: collectDefs(x, into)

proc compileForms*(forms: seq[Value]): string =
  let c = Ctx(body: @[], indent: 1, counter: 0, recurStack: @[],
              recurInts: @[], cores: initTable[string, string](),
              defined: initHashSet[string](), prelude: @[],
              cells: initTable[string, string](),
              defCounts: initCountTable[string]())
  for f in forms: collectDefs(f, c.defCounts)
  let env = newEnv()
  for f in forms:
    let t = c.gensym("top")
    c.line("var " & t & ": Value = NilV")
    genInto(f, t, env, c)
    c.line("discard " & t)
  var src = preamble & "  initClonimRuntime()\n  registerCore()\n  registerNamespaceCore()\n" & c.prelude.join("\n") & "\n" &
            c.body.join("\n") & "\n\n"
  src &= """
when isMainModule:
  try:
    cljMain()
  except CljError as e:
    stderr.writeLine("clonim: " & e.msg)
    quit(1)
"""
  src

proc compileSource*(src: string, sourceRoots: seq[string] = @[]): string =
  compileForms(resolveSource(src, sourceRoots))
