## clonim compiler — Clojure forms -> Nim source.
##
## Shape borrowed from jank: read to data, analyze into a small set of core
## special forms (everything else is expanded), then emit host-language code
## and let the host compiler do register allocation, inlining and codegen.
import std/[tables, strutils, sets]
import runtime, reader

type
  Env = ref object
    parent: Env
    locals: Table[string, string]   # clojure name -> nim identifier

  Ctx = ref object
    body: seq[string]               # emitted lines
    indent: int
    counter: int
    recurStack: seq[seq[string]]    # nim idents of the enclosing recur target
    defined: HashSet[string]        # names def'd so far (for nicer errors)
    prelude: seq[string]            # hoisted var-cell resolutions
    cells: Table[string, string]    # clojure var name -> nim cell ident

proc newEnv(parent: Env = nil): Env =
  Env(parent: parent, locals: initTable[string, string]())

proc lookup(env: Env, name: string): string =
  var e = env
  while e != nil:
    if e.locals.hasKey(name): return e.locals[name]
    e = e.parent
  ""

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
  of kCons, kLazy: err("Can't quote a lazy seq")
  of kFn: err("Can't quote a function")

proc emptySeqFix(s: string, elemType: string): string =
  ## `@[]` has no inferable element type in Nim; annotate it.
  s.replace("@[]", "newSeq[" & elemType & "]()")

# ------------------------------------------------------------- code gen
proc genInto(f: Value, dst: string, env: Env, c: Ctx)

proc genExpr(f: Value, env: Env, c: Ctx): string =
  result = c.gensym("t")
  c.line("var " & result & ": Value = NilV")
  genInto(f, result, env, c)

proc genBody(forms: seq[Value], dst: string, env: Env, c: Ctx) =
  if forms.len == 0:
    c.line(dst & " = NilV")
    return
  for i in 0 ..< forms.len - 1:
    discard genExpr(forms[i], env, c)
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

proc genFn(name: string, clauses: seq[FnClause], selfIdent: string, env: Env, c: Ctx, dst: string) =
  let argsIdent = c.gensym("args")
  c.line(dst & " = mkFn(" & nimStr(name) & ", proc (" & argsIdent & ": seq[Value]): Value =")
  c.push
  var first = true
  for cl in clauses:
    let cond =
      if cl.restParam.len > 0: argsIdent & ".len >= " & $cl.params.len
      else: argsIdent & ".len == " & $cl.params.len
    c.line((if first: "if " else: "elif ") & cond & ":")
    first = false
    c.push
    let fenv = newEnv(env)
    if selfIdent.len > 0 and name.len > 0:
      fenv.locals[name] = selfIdent
    var recurIdents: seq[string] = @[]
    for i, p in cl.params:
      let id = c.gensym("p" & mangle(p))
      c.line("var " & id & ": Value = argAt(" & argsIdent & ", " & $i & ")")
      fenv.locals[p] = id
      recurIdents.add id
    if cl.restParam.len > 0:
      let id = c.gensym("p" & mangle(cl.restParam))
      c.line("var " & id & ": Value = restArgs(" & argsIdent & ", " & $cl.params.len & ")")
      fenv.locals[cl.restParam] = id
    let res = c.gensym("res")
    c.line("var " & res & ": Value = NilV")
    c.line("while true:")
    c.push
    c.recurStack.add recurIdents
    genBody(cl.body, res, fenv, c)
    discard c.recurStack.pop
    c.line("break")
    c.pop
    c.line("return " & res)
    c.pop
  c.line("else:")
  c.push
  c.line("err(\"Wrong number of args (\" & $" & argsIdent & ".len & \") passed to " &
         (if name.len > 0: name else: "fn") & "\")")
  c.pop
  c.pop
  c.line(")")

proc genFnForm(args: seq[Value], env: Env, c: Ctx, dst: string, defName: string) =
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
    genFn(name, clauses, selfIdent, env, c, selfIdent)
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
        c.line("var " & id & ": Value = call(getVar(\"nth\"), @[" & v & ", mkInt(" &
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
            c.line("var " & id & ": Value = call(getVar(\"get\"), @[" & v &
                   ", mkKeyword(" & nimStr(nm) & ")])")
            lenv.locals[nm] = id
        else:
          let nm = symName(k)
          let id = c.gensym("l" & mangle(nm))
          let kv = genExpr(valForm, lenv, c)
          c.line("var " & id & ": Value = call(getVar(\"get\"), @[" & v & ", " & kv & "])")
          lenv.locals[nm] = id
    else:
      err("Unsupported binding form: " & prStr(target))
    i += 2
  genBody(body, dst, lenv, c)

proc genLoop(bindings: Value, body: seq[Value], dst: string, env: Env, c: Ctx) =
  if bindings.isNil or bindings.kind != kVector or bindings.items.len mod 2 != 0:
    err("loop requires an even-sized binding vector")
  let lenv = newEnv(env)
  var idents: seq[string] = @[]
  var i = 0
  while i < bindings.items.len:
    let nm = symName(bindings.items[i])
    let v = genExpr(bindings.items[i + 1], lenv, c)
    let id = c.gensym("l" & mangle(nm))
    c.line("var " & id & ": Value = " & v)
    lenv.locals[nm] = id
    idents.add id
    i += 2
  c.line("while true:")
  c.push
  c.recurStack.add idents
  genBody(body, dst, lenv, c)
  discard c.recurStack.pop
  c.line("break")
  c.pop

proc genCall(f: Value, args: seq[Value], dst: string, env: Env, c: Ctx) =
  let fv = genExpr(f, env, c)
  var argIdents: seq[string] = @[]
  for a in args: argIdents.add genExpr(a, env, c)
  if argIdents.len == 0:
    c.line(dst & " = call(" & fv & ", emptyArgs)")
  else:
    c.line(dst & " = call(" & fv & ", @[" & argIdents.join(", ") & "])")

proc genInto(f: Value, dst: string, env: Env, c: Ctx) =
  if f.isNil:
    c.line(dst & " = NilV"); return
  case f.kind
  of kNil, kBool, kInt, kFloat, kStr, kKeyword:
    c.line(dst & " = " & quoteLit(f))
  of kSymbol:
    let local = env.lookup(f.s)
    if local.len > 0: c.line(dst & " = " & local)
    else: c.line(dst & " = cellGet(" & c.cellFor(f.s) & ")")
  of kVector:
    var ids: seq[string] = @[]
    for x in f.items: ids.add genExpr(x, env, c)
    c.line(dst & " = mkVector(" &
      (if ids.len == 0: "newSeq[Value]()" else: "@[" & ids.join(", ") & "]") & ")")
  of kSet:
    var ids: seq[string] = @[]
    for x in f.items: ids.add genExpr(x, env, c)
    c.line(dst & " = mkSet(" &
      (if ids.len == 0: "newSeq[Value]()" else: "@[" & ids.join(", ") & "]") & ")")
  of kMap:
    var parts: seq[string] = @[]
    for (k, v) in f.pairs:
      let ki = genExpr(k, env, c)
      let vi = genExpr(v, env, c)
      parts.add "(" & ki & ", " & vi & ")"
    c.line(dst & " = mkMap(" &
      (if parts.len == 0: "newSeq[(Value, Value)]()" else: "@[" & parts.join(", ") & "]") & ")")
  of kFn:
    err("Can't emit a function literal")
  of kCons, kLazy:
    err("Can't emit a lazy seq literal")
  of kList:
    if f.items.len == 0:
      c.line(dst & " = mkList(newSeq[Value]())"); return
    let head = f.items[0]
    let args = f.items[1 .. ^1]
    if head.kind == kSymbol:
      case head.s
      of "quote":
        c.line(dst & " = " & quoteLit(args[0]))
        return
      of "if":
        if args.len < 2: err("Too few arguments to if")
        let cv = genExpr(args[0], env, c)
        c.line("if truthy(" & cv & "):")
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
        var tmps: seq[string] = @[]
        for a in args: tmps.add genExpr(a, env, c)
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
        genFnForm(rest, env, c, fv, nm)
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
        let cv = genExpr(args[0], env, c)
        c.line("if truthy(" & cv & "):")
        c.push; genBody(args[1 .. ^1], dst, env, c); c.pop
        c.line("else:")
        c.push; c.line(dst & " = NilV"); c.pop
        return
      of "when-not":
        let cv = genExpr(args[0], env, c)
        c.line("if not truthy(" & cv & "):")
        c.push; genBody(args[1 .. ^1], dst, env, c); c.pop
        c.line("else:")
        c.push; c.line(dst & " = NilV"); c.pop
        return
      of "if-not":
        let cv = genExpr(args[0], env, c)
        c.line("if not truthy(" & cv & "):")
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
          let cv = genExpr(args[i], env, c)
          c.line("if truthy(" & cv & "):")
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
        let tv = genExpr(b.items[1], env, c)
        c.line("if truthy(" & tv & "):")
        c.push
        let benv = newEnv(env)
        let id = c.gensym("l" & mangle(nm))
        c.line("var " & id & ": Value = " & tv)
        benv.locals[nm] = id
        if head.s == "when-let": genBody(args[1 .. ^1], dst, benv, c)
        else: genInto(args[1], dst, benv, c)
        c.pop
        c.line("else:")
        c.push
        if head.s == "if-let" and args.len > 2: genInto(args[2], dst, env, c)
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
import runtime, core

proc cljMain() =
"""

proc compileForms*(forms: seq[Value]): string =
  let c = Ctx(body: @[], indent: 1, counter: 0, recurStack: @[],
              defined: initHashSet[string](), prelude: @[],
              cells: initTable[string, string]())
  let env = newEnv()
  for f in forms:
    let t = c.gensym("top")
    c.line("var " & t & ": Value = NilV")
    genInto(f, t, env, c)
    c.line("discard " & t)
  var src = preamble & "  registerCore()\n" & c.prelude.join("\n") & "\n" &
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

proc compileSource*(src: string): string =
  compileForms(readAll(src))
