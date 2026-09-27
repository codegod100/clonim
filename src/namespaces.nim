## Static namespaces and dependency loading, before compiler.compileForms.
## This pass understands the compiler's fixed macro/binding forms, not arbitrary
## user macro expansion. Reader limitations (including syntax-quote and reader
## conditionals) still apply. Core discovery temporarily swaps runtime globals;
## like that runtime, this module is intended for single-threaded use.
## Core var references are canonical clojure.core/name symbols. Generated code
## must call registerNamespaceCore() after registerCore() (or register the same
## canonical cells itself). Syntax heads remain unqualified for the compiler.
import std/[os, tables, sets, strutils]
import runtime, reader, core

type
  MacroDef = object
    params: Value
    body: seq[Value]
  Namespace = ref object
    name: string
    aliases, refers: Table[string, string]
    defs, privateDefs, required: HashSet[string]
  Resolver = ref object
    roots: seq[string]
    cores, hosts: HashSet[string]
    spaces: Table[string, Namespace]
    active: seq[string]
    loaded: HashSet[string]
    macros: Table[string, MacroDef]
    output: seq[Value]
    gensym: int
    types: HashSet[string]     ## deftype names, qualified, for `Name.` calls

const syntaxHeads = ["quote", "if", "do", "let", "let*", "loop", "loop*",
  "recur", "fn", "fn*", "def", "defn", "defn-", "defmacro", "and", "or",
  "when", "when-not", "if-not", "cond", "when-let", "if-let", "->", "->>",
  "doseq", "dotimes", "try", "catch", "finally", "comment", "set!", "declare",
  "case", "for", "with-open", "assert", "binding", "reify", "deftype",
  "defprotocol", "."]

# Unlike macros, these heads cannot be shadowed in operator position.
const specialForms = ["quote", "if", "do", "let*", "loop*", "recur", "fn*",
  "def", "try", "catch", "finally", "set!"]
const namespaceHeads = ["ns", "require", "in-ns", "use", "import", "refer",
  "load", "load-file"]

proc fail(msg: string) {.noreturn.} = err("Namespace error: " & msg)
proc isSym(v: Value, s: string): bool = v.kind == kSymbol and v.s == s
proc headName(v: Value): string =
  if v.kind == kList and v.items.len > 0 and v.items[0].kind == kSymbol:
    result = v.items[0].s
    if result.startsWith("clojure.core/"): result = result[13 .. ^1]

proc simple(v: Value, what: string): string =
  if v.kind != kSymbol or v.s.len == 0 or ('/' in v.s and v.s != "/"):
    fail("expected unqualified " & what & ", got " & prStr(v))
  v.s

proc validNamespace(name: string) =
  for part in name.split('.'):
    if part.len == 0: fail("invalid namespace: " & name)
    for ch in part:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
        fail("invalid namespace: " & name)

proc registeredCoreNames(): HashSet[string] =
  # Isolate registration: do not overwrite caller values or mutate their cells.
  let saved = globals
  globals = initTable[string, VarCell]()
  try:
    registerCore()
    for name, cell in globals:
      if cell.bound and '/' notin name: result.incl name
    if globals.hasKey("/"): result.incl "/"
  finally:
    globals = saved

proc registeredHostNames(): HashSet[string] =
  ## Runtime functions in named host namespaces (for example clojure.string)
  ## do not need a shadow source file merely to be required by user code.
  let saved = globals
  globals = initTable[string, VarCell]()
  try:
    registerCore()
    for name, cell in globals:
      if cell.bound: result.incl name
  finally:
    globals = saved

proc hasHostNamespace(r: Resolver, name: string): bool =
  for candidate in r.hosts:
    if candidate.startsWith(name & "/"): return true

proc registerNamespaceCore*() =
  ## Call after registerCore in the generated program, before resolving cells.
  ## Both spellings share a cell, so rebinding remains coherent.
  let names = registeredCoreNames()
  for name in names:
    if not hasVar(name): fail("registerCore must precede registerNamespaceCore")
    globals["clojure.core/" & name] = varCell(name)

proc space(r: Resolver, name: string): Namespace =
  if not r.spaces.hasKey(name):
    r.spaces[name] = Namespace(name: name)
  r.spaces[name]

proc checkVar(r: Resolver, ns: Namespace, target, name: string,
              allowSyntax = false) =
  let canonical = target & "/" & name
  if target == "clojure.core":
    if name in r.cores or (allowSyntax and name in syntaxHeads): return
    fail("no definition " & canonical)
  # JVM-style host calls (for example System/arraycopy) are globally provided.
  if canonical in r.hosts: return
  if target != ns.name and target notin ns.required:
    fail("namespace " & target & " is not required by " & ns.name)
  if not r.spaces.hasKey(target) or name notin r.spaces[target].defs:
    fail("no definition " & canonical)
  if target != ns.name and name in r.spaces[target].privateDefs:
    fail("private var " & canonical & " is inaccessible from " & ns.name)

proc qualify(r: Resolver, ns: Namespace, name: string,
             locals: HashSet[string]): string =
  if name in locals: return name
  let slash = name.find('/')
  if slash > 0:
    let prefix = name[0 ..< slash]
    let target = ns.aliases.getOrDefault(prefix, prefix)
    let member = name[slash + 1 .. ^1]
    r.checkVar(ns, target, member)
    return target & "/" & member
  if name in ns.defs: return ns.name & "/" & name
  if ns.refers.hasKey(name):
    let target = ns.refers[name]
    let split = target.find('/')
    r.checkVar(ns, target[0 ..< split], target[split + 1 .. ^1])
    return target
  if name in r.cores: return "clojure.core/" & name
  fail("unable to resolve symbol " & name & " in " & ns.name)

proc syntaxHead(ns: Namespace, v: Value, locals: HashSet[string]): string =
  if v.kind != kList or v.items.len == 0 or v.items[0].kind != kSymbol: return
  let raw = v.items[0].s
  if raw in specialForms: return raw
  if raw in locals: return
  let slash = raw.find('/')
  var canonical: string
  if slash > 0:
    let prefix = raw[0 ..< slash]
    canonical = ns.aliases.getOrDefault(prefix, prefix) & raw[slash .. ^1]
  else:
    if raw in ns.defs: return
    canonical = ns.refers.getOrDefault(raw, "clojure.core/" & raw)
  if canonical.startsWith("clojure.core/"):
    let name = canonical[13 .. ^1]
    if name in syntaxHeads or name in namespaceHeads: return name

proc define(ns: Namespace, v: Value, private = false): Value =
  let name = simple(v, "definition name")
  if ns.refers.hasKey(name) and not ns.refers[name].startsWith("clojure.core/"):
    fail("definition conflicts with referred name: " & name)
  ns.defs.incl name
  if private: ns.privateDefs.incl name
  result = mkSymbol(ns.name & "/" & name)

proc walk(r: Resolver, ns: Namespace, v: Value, locals: HashSet[string]): Value

proc methodTable(specs: seq[Value]): Value =
  ## The method map of a reify/deftype body: interface and protocol names are
  ## markers only, and every (name [this ...] body) clause becomes an arity of
  ## the fn stored under "name". Dispatch is by method name at runtime.
  var order: seq[string] = @[]
  var arities = initTable[string, seq[Value]]()
  for spec in specs:
    if spec.kind == kSymbol: continue
    if spec.kind != kList or spec.items.len < 2 or spec.items[0].kind != kSymbol or
       spec.items[1].kind != kVector:
      fail("invalid method implementation: " & prStr(spec))
    let name = spec.items[0].s
    if name notin arities:
      order.add name
      arities[name] = @[]
    arities[name].add mkList(spec.items[1 .. ^1])
  var ps: seq[(Value, Value)] = @[]
  for name in order:
    ps.add (mkStr(name), mkList(@[mkSymbol("fn")] & arities[name]))
  mkMap(ps)

proc macroKey(r: Resolver, ns: Namespace, raw: string): string =
  let slash = raw.find('/')
  if slash > 0:
    let target = ns.aliases.getOrDefault(raw[0 ..< slash], raw[0 ..< slash])
    return target & raw[slash .. ^1]
  if raw in ns.defs: return ns.name & "/" & raw
  if ns.refers.hasKey(raw): return ns.refers[raw]

proc bindMacroParams(params: Value, args: seq[Value]): Table[string, Value] =
  if params.kind != kVector: fail("macro parameters must be a vector")
  result = initTable[string, Value]()
  var pi = 0
  var ai = 0
  while pi < params.items.len:
    let p = params.items[pi]
    if p.kind == kSymbol and p.s == "&":
      if pi + 1 >= params.items.len or params.items[pi + 1].kind != kSymbol:
        fail("macro & must be followed by a symbol")
      result[params.items[pi + 1].s] =
        (if ai < args.len: mkList(args[ai .. ^1]) else: NilV)
      return
    if p.kind != kSymbol: fail("macro parameters must be symbols")
    if ai >= args.len: fail("not enough arguments passed to macro")
    result[p.s] = args[ai]
    inc pi
    inc ai
  if ai != args.len: fail("too many arguments passed to macro")

proc evalMacro(v: Value, env: Table[string, Value]): Value

proc evalMacroBody(body: seq[Value], env: Table[string, Value]): Value =
  result = NilV
  for form in body: result = evalMacro(form, env)

proc evalMacro(v: Value, env: Table[string, Value]): Value =
  case v.kind
  of kSymbol:
    if env.hasKey(v.s): return env[v.s]
    if hasVar(v.s): return getVar(v.s)
    fail("macro evaluation cannot resolve " & v.s)
  of kVector:
    var xs: seq[Value]
    for x in v.items: xs.add evalMacro(x, env)
    return mkVector(xs)
  of kMap:
    var ps: seq[(Value, Value)]
    for (k, value) in v.pairs: ps.add (evalMacro(k, env), evalMacro(value, env))
    return mkMap(ps)
  of kSet:
    var xs: seq[Value]
    for x in v.items: xs.add evalMacro(x, env)
    return mkSet(xs)
  of kList: discard
  else: return v
  let xs = v.items
  if xs.len == 0: return v
  let head = if xs[0].kind == kSymbol: xs[0].s else: ""
  case head
  of "quote":
    if xs.len != 2: fail("quote in macro body expects one argument")
    return xs[1]
  of "if":
    if xs.len notin 3 .. 4: fail("if in macro body expects two or three arguments")
    if truthy(evalMacro(xs[1], env)): return evalMacro(xs[2], env)
    return (if xs.len == 4: evalMacro(xs[3], env) else: NilV)
  of "do": return evalMacroBody(xs[1 .. ^1], env)
  of "let", "let*":
    if xs.len < 3 or xs[1].kind != kVector or xs[1].items.len mod 2 != 0:
      fail("let in macro body requires paired bindings")
    var scope = env
    var i = 0
    while i < xs[1].items.len:
      let name = xs[1].items[i]
      if name.kind != kSymbol: fail("macro let bindings must be symbols")
      scope[name.s] = evalMacro(xs[1].items[i + 1], scope)
      i += 2
    return evalMacroBody(xs[2 .. ^1], scope)
  of "fn", "fn*":
    if xs.len < 3 or xs[1].kind != kVector:
      fail("fn in macro body requires a parameter vector")
    let params = xs[1]
    let body = xs[2 .. ^1]
    let captured = env
    return mkFn("macro-fn", proc (args: openArray[Value]): Value =
      var scope = captured
      let bound = bindMacroParams(params, @args)
      for name, value in bound: scope[name] = value
      evalMacroBody(body, scope))
  else: discard
  let f = evalMacro(xs[0], env)
  var args: seq[Value]
  for x in xs[1 .. ^1]: args.add evalMacro(x, env)
  call(f, args)

proc expandMacro(r: Resolver, ns: Namespace, form: Value,
                 locals: HashSet[string]): (bool, Value) =
  let key = r.macroKey(ns, form.items[0].s)
  if key.len == 0 or not r.macros.hasKey(key): return (false, NilV)
  let m = r.macros[key]
  var env = bindMacroParams(m.params, form.items[1 .. ^1])
  env["&form"] = form
  env["&env"] = mkMap(@[])
  result = (true, evalMacroBody(m.body, env))

proc bindNames(v: Value, locals: var HashSet[string]) =
  case v.kind
  of kSymbol:
    if v.s != "&": locals.incl simple(v, "local binding")
  of kVector:
    for x in v.items:
      if x.kind != kKeyword: bindNames(x, locals)
  of kMap:
    for (k, value) in v.pairs:
      if k.kind == kKeyword:
        let key = k.s.split('/')[^1]
        case key
        of "keys", "syms", "strs":
          if value.kind != kVector: fail("destructuring requires a vector")
          for x in value.items:
            if x.kind notin {kSymbol, kStr}: fail("invalid destructuring name")
            locals.incl x.s.split('/')[^1]
        of "as": bindNames(value, locals)
        of "or": discard
        else: fail("unsupported destructuring directive: " & k.s)
      else: bindNames(k, locals)
  else: fail("invalid binding pattern: " & prStr(v))

proc pattern(r: Resolver, ns: Namespace, v: Value,
             locals: HashSet[string]): Value =
  # Patterns are data except for :or defaults, which are expressions.
  if v.kind == kMap:
    var ps: seq[(Value, Value)]
    for (k, value) in v.pairs:
      if k.kind == kKeyword and k.s == "or":
        if value.kind != kMap: fail(":or requires a map")
        var defaults: seq[(Value, Value)]
        for (key, expr) in value.pairs:
          defaults.add (key, r.walk(ns, expr, locals))
        ps.add (k, mkMap(defaults))
      elif k.kind != kKeyword:
        ps.add (r.pattern(ns, k, locals), value)
      else: ps.add (k, value)
    return mkMap(ps)
  if v.kind == kVector:
    var xs: seq[Value]
    for x in v.items: xs.add r.pattern(ns, x, locals)
    return mkVector(xs)
  v

proc fnTail(r: Resolver, ns: Namespace, xs: seq[Value],
            locals: HashSet[string]): seq[Value] =
  if xs.len == 0: fail("function requires parameters")
  if xs[0].kind == kVector:
    var scope = locals
    bindNames(xs[0], scope)
    result.add r.pattern(ns, xs[0], locals)
    for i in 1 ..< xs.len: result.add r.walk(ns, xs[i], scope)
  else:
    for clause in xs:
      if clause.kind != kList: fail("invalid function arity")
      result.add mkList(r.fnTail(ns, clause.items, locals))

proc walk(r: Resolver, ns: Namespace, v: Value, locals: HashSet[string]): Value =
  case v.kind
  of kSymbol:
    if ns.syntaxHead(mkList(@[v]), locals) in namespaceHeads:
      fail("dynamic namespace operation is unsupported: " & v.s)
    return mkSymbol(r.qualify(ns, v.s, locals))
  of kMap:
    var ps: seq[(Value, Value)]
    for (k, value) in v.pairs:
      ps.add (r.walk(ns, k, locals), r.walk(ns, value, locals))
    return mkMap(ps)
  of kVector, kSet:
    var xs: seq[Value]
    for x in v.items: xs.add r.walk(ns, x, locals)
    if v.kind == kVector: return mkVector(xs)
    return mkSet(xs)
  of kList: discard
  else: return v
  var xs = v.items
  if xs.len == 0: return v
  if xs[0].kind == kSymbol and xs[0].s notin locals:
    let head = xs[0].s
    if head.len > 1 and head[0] == '.' and head != ".." and head notin r.cores and
       head notin r.hosts:
      # (.method obj args...) on a reify/deftype instance
      if xs.len < 2: fail("method call requires a target: " & prStr(v))
      return r.walk(ns, mkList(@[mkSymbol("clonim.rt/invoke-method"), xs[1],
                                 mkStr(head[1 .. ^1])] & xs[2 .. ^1]), locals)
    if head.len > 1 and head[^1] == '.' and head[0] != '.' and
       (ns.name & "/" & head[0 ..< head.len - 1]) in r.types:
      # (Name. fields...) constructs a deftype
      return r.walk(ns, mkList(@[mkSymbol("->" & head[0 ..< head.len - 1])] &
                               xs[1 .. ^1]), locals)
    let (isMacro, expanded) = r.expandMacro(ns, v, locals)
    if isMacro: return r.walk(ns, expanded, locals)
  let h = ns.syntaxHead(v, locals)
  if h in ["quote", "comment"]:
    xs[0] = mkSymbol(h)
    return mkList(xs)
  if h in namespaceHeads:
    fail(h & " is only supported as a static top-level ns/require declaration")
  if h in syntaxHeads: xs[0] = mkSymbol(h)
  case h
  of ".":
    # (. obj method args...) or (. obj (method args...))
    if xs.len < 3: fail(". requires a target and a method")
    var meth = xs[2]
    var args = xs[3 .. ^1]
    if meth.kind == kList and meth.items.len > 0:
      args = meth.items[1 .. ^1]
      meth = meth.items[0]
    if meth.kind != kSymbol: fail(". requires a method name")
    return r.walk(ns, mkList(@[mkSymbol("clonim.rt/invoke-method"), xs[1],
                               mkStr(meth.s)] & args), locals)
  of "reify":
    return r.walk(ns, mkList(@[mkSymbol("clonim.rt/make-object"), mkStr("reify"),
                               methodTable(xs[1 .. ^1])]), locals)
  of "deftype":
    # (deftype Name [fields] Iface (method [this ...] ...) ...): a constructor
    # whose methods close over the fields, plus a var naming the type.
    if xs.len < 3 or xs[1].kind != kSymbol or xs[2].kind != kVector:
      fail("deftype requires a name and a field vector")
    let tname = simple(xs[1], "type name")
    let qualified = ns.name & "." & tname
    r.types.incl ns.name & "/" & tname
    let ctor = mkList(@[mkSymbol("defn"), mkSymbol("->" & tname), xs[2],
      mkList(@[mkSymbol("clonim.rt/make-object"), mkStr(qualified),
               methodTable(xs[3 .. ^1])])])
    let tvar = mkList(@[mkSymbol("def"), xs[1], mkStr(qualified)])
    return mkList(@[mkSymbol("do"), r.walk(ns, tvar, locals),
                    r.walk(ns, ctor, locals)])
  of "defprotocol":
    # Each signature becomes a fn that dispatches on its first argument's
    # methods, which is what a deftype or reify implementing it provides.
    if xs.len < 2: fail("defprotocol requires a name")
    var forms: seq[Value] = @[mkSymbol("do"),
      r.walk(ns, mkList(@[mkSymbol("def"), xs[1], mkStr(ns.name & "." & xs[1].s)]), locals)]
    for sig in xs[2 .. ^1]:
      if sig.kind != kList or sig.items.len == 0: continue
      let mname = simple(sig.items[0], "protocol method")
      forms.add r.walk(ns, mkList(@[mkSymbol("defn"), sig.items[0],
        mkVector(@[mkSymbol("this"), mkSymbol("&"), mkSymbol("args")]),
        mkList(@[mkSymbol("apply"), mkSymbol("clonim.rt/invoke-method"),
                 mkSymbol("this"), mkStr(mname), mkSymbol("args")])]), locals)
    return mkList(forms)
  of "fn", "fn*":
    var scope = locals
    var start = 1
    if xs.len > 1 and xs[1].kind == kSymbol:
      scope.incl simple(xs[1], "function name")
      start = 2
    return mkList(xs[0 ..< start] & r.fnTail(ns, xs[start .. ^1], scope))
  of "defmacro":
    if xs.len < 4: fail("defmacro requires a name, parameters, and body")
    xs[1] = ns.define(xs[1])
    var start = 2
    if xs[start].kind == kStr: inc start
    if start < xs.len and xs[start].kind == kMap: inc start
    if start >= xs.len or xs[start].kind != kVector:
      fail("defmacro requires a parameter vector")
    var scope = locals
    bindNames(xs[start], scope)
    scope.incl "&form"
    scope.incl "&env"
    var body: seq[Value]
    for i in start + 1 ..< xs.len: body.add r.walk(ns, xs[i], scope)
    r.macros[xs[1].s] = MacroDef(params: xs[start], body: body)
    return mkList(@[mkSymbol("defmacro"), xs[1]])
  of "defn", "defn-":
    if xs.len < 3: fail(h & " requires a name and parameters")
    xs[1] = ns.define(xs[1], h == "defn-")
    var start = 2
    if start < xs.len and xs[start].kind == kStr: inc start
    if start < xs.len and xs[start].kind == kMap: inc start
    var scope = locals
    return mkList(xs[0 ..< start] & r.fnTail(ns, xs[start .. ^1], scope))
  of "def", "declare":
    if xs.len < 2: fail(h & " requires a name")
    let stop = if h == "declare": xs.len else: 2
    for i in 1 ..< stop:
      xs[i] = ns.define(xs[i])
    for i in stop ..< xs.len: xs[i] = r.walk(ns, xs[i], locals)
    return mkList(xs)
  of "doseq":
    # Nested bindings, modifiers and destructuring become nested single-symbol
    # doseqs, which is the only shape the code generator handles.
    if xs.len < 2 or xs[1].kind != kVector or xs[1].items.len mod 2 != 0:
      fail("doseq requires paired bindings")
    let bs = xs[1].items
    if bs.len != 2 or bs[0].kind != kSymbol:
      proc nest(i: int): Value =
        if i >= bs.len: return mkList(@[mkSymbol("do")] & xs[2 .. ^1])
        let target = bs[i]
        if target.kind == kKeyword:
          case target.s
          of "when": return mkList(@[mkSymbol("when"), bs[i + 1], nest(i + 2)])
          of "let": return mkList(@[mkSymbol("let"), bs[i + 1], nest(i + 2)])
          else: fail("unsupported doseq modifier: :" & target.s)
        var coll = bs[i + 1]
        var j = i + 2
        # :while belongs to the binding it follows: stop that level's walk.
        while j < bs.len and bs[j].kind == kKeyword and bs[j].s == "while":
          coll = mkList(@[mkSymbol("take-while"),
                          mkList(@[mkSymbol("fn"), mkVector(@[target]), bs[j + 1]]), coll])
          j += 2
        if target.kind == kSymbol:
          return mkList(@[mkSymbol("doseq"), mkVector(@[target, coll]), nest(j)])
        inc r.gensym
        let g = mkSymbol("seq__" & $r.gensym)
        mkList(@[mkSymbol("doseq"), mkVector(@[g, coll]),
                 mkList(@[mkSymbol("let"), mkVector(@[target, g]), nest(j)])])
      return r.walk(ns, nest(0), locals)
    var scope = locals
    var bs2 = bs
    bs2[1] = r.walk(ns, bs2[1], scope)
    bindNames(bs[0], scope)
    xs[1] = mkVector(bs2)
    for j in 2 ..< xs.len: xs[j] = r.walk(ns, xs[j], scope)
    return mkList(xs)
  of "when-let", "if-let":
    if xs.len < 3 or xs[1].kind != kVector or xs[1].items.len != 2:
      fail(h & " requires exactly one binding")
    let target = xs[1].items[0]
    if target.kind != kSymbol:
      # (when-let [[a b] x] ...) tests x, then destructures it
      inc r.gensym
      let g = mkSymbol("test__" & $r.gensym)
      var form = @[xs[0], mkVector(@[g, xs[1].items[1]]),
                   mkList(@[mkSymbol("let"), mkVector(@[target, g])] &
                          (if h == "when-let": xs[2 .. ^1] else: @[xs[2]]))]
      if h == "if-let" and xs.len > 3: form.add xs[3]
      return r.walk(ns, mkList(form), locals)
    var scope = locals
    var bs = xs[1].items
    bs[1] = r.walk(ns, bs[1], scope)
    scope.incl simple(target, "local binding")
    xs[1] = mkVector(bs)
    for j in 2 ..< xs.len:
      xs[j] = r.walk(ns, xs[j], if h == "if-let" and j >= 3: locals else: scope)
    return mkList(xs)
  of "let", "let*", "loop", "loop*", "dotimes":
    if xs.len < 2 or xs[1].kind != kVector: fail(h & " requires bindings")
    var bs = xs[1].items
    if bs.len mod 2 != 0: fail(h & " requires paired bindings")
    if h == "dotimes" and bs.len != 2:
      fail(h & " supports exactly one binding")
    var scope = locals
    var i = 0
    while i < bs.len:
      bs[i + 1] = r.walk(ns, bs[i + 1], scope)
      let original = bs[i]
      bs[i] = r.pattern(ns, original, scope)
      bindNames(original, scope)
      i += 2
    xs[1] = mkVector(bs)
    for j in 2 ..< xs.len:
      xs[j] = r.walk(ns, xs[j], if h == "if-let" and j >= 3: locals else: scope)
    return mkList(xs)
  of "catch":
    if xs.len < 3: fail("catch requires a class and binding")
    var scope = locals
    scope.incl simple(xs[2], "catch binding")
    for i in 3 ..< xs.len: xs[i] = r.walk(ns, xs[i], scope)
    return mkList(xs)
  of "case":
    # (case e test-constant result ... default?) — the constants are literal,
    # so they are quoted rather than resolved.
    if xs.len < 3: fail("case requires an expression and at least one clause")
    inc r.gensym
    let sym = mkSymbol("case__" & $r.gensym)
    var clauses: seq[Value] = @[]
    var i = 2
    while i + 1 < xs.len:
      let test = xs[i]
      var pred: Value
      if test.kind in {kList, kVector} and test.items.len > 0:
        # a group of constants shares one result
        var alts: seq[Value] = @[mkSymbol("or")]
        for t in test.items:
          alts.add mkList(@[mkSymbol("="), sym, mkList(@[mkSymbol("quote"), t])])
        pred = mkList(alts)
      else:
        pred = mkList(@[mkSymbol("="), sym, mkList(@[mkSymbol("quote"), test])])
      clauses.add pred
      clauses.add xs[i + 1]
      i += 2
    clauses.add mkSymbol("else")
    if i < xs.len: clauses.add xs[i]
    else:
      clauses.add mkList(@[mkSymbol("throw"),
                           mkList(@[mkSymbol("str"), mkStr("No matching clause: "), sym])])
    return r.walk(ns, mkList(@[mkSymbol("let"), mkVector(@[sym, xs[1]]),
                               mkList(@[mkSymbol("cond")] & clauses)]), locals)
  of "for":
    if xs.len < 3 or xs[1].kind != kVector: fail("for requires [sym coll] bindings")
    var bs = xs[1].items
    if bs.len == 0 or bs.len mod 2 != 0: fail("for requires paired bindings")
    var modifiers = false
    for j in countup(0, bs.len - 1, 2):
      if bs[j].kind == kKeyword: modifiers = true
    if modifiers:
      # :when, :let and :while: each binding level is a mapcat whose innermost
      # body yields a one-element list, or nothing when a :when fails.
      proc level(i: int): Value =
        if i >= bs.len:
          return mkList(@[mkSymbol("list"), mkList(@[mkSymbol("do")] & xs[2 .. ^1])])
        let target = bs[i]
        if target.kind == kKeyword:
          case target.s
          of "when":
            return mkList(@[mkSymbol("if"), bs[i + 1], level(i + 2),
                            mkList(@[mkSymbol("list")])])
          of "let": return mkList(@[mkSymbol("let"), bs[i + 1], level(i + 2)])
          else: fail("unsupported for modifier: :" & target.s)
        var coll = bs[i + 1]
        var j = i + 2
        while j < bs.len and bs[j].kind == kKeyword and bs[j].s == "while":
          coll = mkList(@[mkSymbol("take-while"),
                          mkList(@[mkSymbol("fn"), mkVector(@[target]), bs[j + 1]]), coll])
          j += 2
        mkList(@[mkSymbol("mapcat"),
                 mkList(@[mkSymbol("fn"), mkVector(@[target]), level(j)]), coll])
      return r.walk(ns, level(0), locals)
    var body = mkList(@[mkSymbol("do")] & xs[2 .. ^1])
    var j = bs.len - 2
    while j >= 0:
      let combine = (if j == bs.len - 2: "map" else: "mapcat")
      body = mkList(@[mkSymbol(combine),
                      mkList(@[mkSymbol("fn"), mkVector(@[bs[j]]), body]),
                      bs[j + 1]])
      j -= 2
    return r.walk(ns, body, locals)
  of "with-open":
    if xs.len < 2 or xs[1].kind != kVector or xs[1].items.len != 2:
      fail("with-open requires [sym resource]")
    let bs = xs[1].items
    let body = mkList(@[mkSymbol("do")] & xs[2 .. ^1])
    let cleanup = mkList(@[mkSymbol("finally"), mkList(@[mkSymbol(".close"), bs[0]])])
    return r.walk(ns, mkList(@[mkSymbol("let"), mkVector(bs),
                               mkList(@[mkSymbol("try"), body, cleanup])]), locals)
  of "assert":
    if xs.len < 2: fail("assert requires a test")
    var msg = mkList(@[mkSymbol("str"), mkStr("Assert failed: " & prStr(xs[1]))])
    if xs.len > 2:
      msg = mkList(@[mkSymbol("str"), mkStr("Assert failed: "), xs[2]])
    return r.walk(ns, mkList(@[mkSymbol("when-not"), xs[1],
                               mkList(@[mkSymbol("throw"), msg])]), locals)
  of "->", "->>":
    # Expand before resolving: a bare step can be a syntax head (e.g. do).
    if xs.len < 2: fail(h & " requires an expression")
    var acc = xs[1]
    for i in 2 ..< xs.len:
      let step = xs[i]
      if step.kind == kList and step.items.len > 0:
        let parts = step.items
        if h == "->": acc = mkList(@[parts[0], acc] & parts[1 .. ^1])
        else: acc = mkList(parts & @[acc])
      else: acc = mkList(@[step, acc])
    return r.walk(ns, acc, locals)
  else: discard
  for i in 0 ..< xs.len:
    if i == 0 and h in syntaxHeads: continue
    if h == "cond" and i mod 2 == 1 and isSym(xs[i], "else"): continue
    xs[i] = r.walk(ns, xs[i], locals)
  if h.len == 0 and xs[0].kind == kSymbol and xs[0].s in locals and
      (xs[0].s in syntaxHeads or xs[0].s in namespaceHeads):
    # The compiler dispatches by head spelling before consulting its locals.
    # An expression head keeps this a value call without renaming bindings.
    xs[0] = mkList(@[mkSymbol("do"), xs[0]])
  mkList(xs)

proc process(r: Resolver, forms: seq[Value], expected = "")
proc load(r: Resolver, name: string) =
  validNamespace(name)
  if name == "clojure.core": return
  if r.hasHostNamespace(name):
    discard r.space(name)
    r.loaded.incl name
    return
  if name in r.active: fail("dependency cycle: " & (r.active & @[name]).join(" -> "))
  if name in r.loaded: return
  let relative = name.replace('.', '/').replace('-', '_')
  var path = ""
  for root in r.roots:
    for ext in [".clj", ".cljc"]:
      let candidate = root / (relative & ext)
      if fileExists(candidate):
        path = candidate
        break
    if path.len > 0: break
  if path.len == 0: fail("cannot find " & name & " in source roots: " & r.roots.join(", "))
  try:
    r.process(readAll(readFile(path)), name)
  except IOError as e:
    fail("cannot read " & path & ": " & e.msg)

proc requireSpec(r: Resolver, ns: Namespace, spec: Value) =
  var xs: seq[Value]
  if spec.kind == kSymbol: xs = @[spec]
  elif spec.kind == kVector: xs = spec.items
  else: fail("require expects a symbol or vector libspec")
  if xs.len == 0: fail("empty require libspec")
  let name = simple(xs[0], "required namespace")
  validNamespace(name)
  var alias = ""
  var refers: seq[string]
  var seen: HashSet[string]
  var i = 1
  while i < xs.len:
    if i + 1 >= xs.len or xs[i].kind != kKeyword: fail("invalid require options")
    let option = xs[i].s
    if option in seen: fail("duplicate require option: " & option)
    seen.incl option
    case option
    of "as": alias = simple(xs[i + 1], "alias")
    of "refer":
      if xs[i + 1].kind != kVector: fail(":refer supports only an explicit vector")
      for x in xs[i + 1].items: refers.add simple(x, "referred name")
    else: fail("unsupported require option: :" & option)
    i += 2
  r.load(name)
  ns.required.incl name
  if alias.len > 0:
    if ns.aliases.hasKey(alias) and ns.aliases[alias] != name:
      fail("conflicting alias: " & alias)
    ns.aliases[alias] = name
  for local in refers:
    r.checkVar(ns, name, local, allowSyntax = true)
    let target = name & "/" & local
    if local in ns.defs or (ns.refers.hasKey(local) and ns.refers[local] != target):
      fail("conflicting referred name: " & local)
    ns.refers[local] = target

proc flatten(forms: seq[Value]): seq[Value] =
  for f in forms:
    if headName(f) == "do": result.add flatten(f.items[1 .. ^1])
    else: result.add f

proc process(r: Resolver, forms: seq[Value], expected = "") =
  let flat = flatten(forms)
  var name = "user"
  var declaration = -1
  for i, f in flat:
    if headName(f) == "ns":
      if declaration >= 0 or i != 0: fail("ns must be the first form and occur once per source")
      if f.items.len < 2: fail("ns requires a name")
      name = simple(f.items[1], "namespace name")
      validNamespace(name)
      declaration = i
  if expected.len > 0 and (declaration < 0 or name != expected):
    fail("source for " & expected & " must declare (ns " & expected & ")")
  if name in r.active: fail("dependency cycle: " & (r.active & @[name]).join(" -> "))
  let ns = r.space(name)

  r.active.add name
  try:
    for f in flat:
      case ns.syntaxHead(f, initHashSet[string]())
      of "ns":
        let xs = f.items
        var start = 2
        if start < xs.len and xs[start].kind == kStr: inc start
        if start < xs.len and xs[start].kind == kMap: inc start
        for i in start ..< xs.len:
          let clause = xs[i]
          if clause.kind != kList or clause.items.len == 0 or
             clause.items[0].kind != kKeyword or clause.items[0].s != "require":
            fail("only :require clauses are supported in ns")
          for spec in clause.items[1 .. ^1]: r.requireSpec(ns, spec)
      of "require":
        if f.items.len < 2: fail("require expects quoted libspecs")
        for arg in f.items[1 .. ^1]:
          if headName(arg) != "quote" or arg.items.len != 2:
            fail("dynamic require is unsupported; quote each libspec")
          r.requireSpec(ns, arg.items[1])
      else:
        let walked = r.walk(ns, f, initHashSet[string]())
        if headName(walked) != "defmacro": r.output.add walked
    r.loaded.incl name
  finally:
    discard r.active.pop()

proc resolveSource*(src: string, sourceRoots: seq[string]): seq[Value] =
  ## Read source text and splice dependencies at their first require, once per
  ## call. Roots are searched in order, .clj before .cljc. Missing/mismatched
  ## namespaces, cycles, unsupported imports and dynamic requires raise CljError.
  ## No namespace state or load cache survives a call. Definitions are visible
  ## from their declaration onward (including their own initializer/body).
  ## Forward references require declare. Qualified references require a direct
  ## require, except for the current namespace and implicit clojure.core.
  ## Unknown and externally private vars are rejected during analysis.
  let r = Resolver(roots: sourceRoots, cores: registeredCoreNames(),
                   hosts: registeredHostNames(),
                   macros: initTable[string, MacroDef]())
  let saved = globals
  globals = initTable[string, VarCell]()
  try:
    registerCore()
    registerNamespaceCore()
    r.process(readAll(src))
    result = r.output
  finally:
    globals = saved
