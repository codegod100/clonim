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
    output: seq[Value]

const syntaxHeads = ["quote", "if", "do", "let", "let*", "loop", "loop*",
  "recur", "fn", "fn*", "def", "defn", "defn-", "defmacro", "and", "or",
  "when", "when-not", "if-not", "cond", "when-let", "if-let", "->", "->>",
  "doseq", "dotimes", "try", "catch", "finally", "comment", "set!", "declare"]

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
  let h = ns.syntaxHead(v, locals)
  if h in ["quote", "comment"]:
    xs[0] = mkSymbol(h)
    return mkList(xs)
  if h in namespaceHeads:
    fail(h & " is only supported as a static top-level ns/require declaration")
  if h in syntaxHeads: xs[0] = mkSymbol(h)
  case h
  of "fn", "fn*":
    var scope = locals
    var start = 1
    if xs.len > 1 and xs[1].kind == kSymbol:
      scope.incl simple(xs[1], "function name")
      start = 2
    return mkList(xs[0 ..< start] & r.fnTail(ns, xs[start .. ^1], scope))
  of "defn", "defn-", "defmacro":
    if xs.len < 3: fail(h & " requires a name and parameters")
    xs[1] = ns.define(xs[1], h == "defn-")
    var start = 2
    if start < xs.len and xs[start].kind == kStr: inc start
    if start < xs.len and xs[start].kind == kMap: inc start
    var scope = locals
    if h == "defmacro":
      scope.incl "&form"
      scope.incl "&env"
    return mkList(xs[0 ..< start] & r.fnTail(ns, xs[start .. ^1], scope))
  of "def", "declare":
    if xs.len < 2: fail(h & " requires a name")
    let stop = if h == "declare": xs.len else: 2
    for i in 1 ..< stop:
      xs[i] = ns.define(xs[i])
    for i in stop ..< xs.len: xs[i] = r.walk(ns, xs[i], locals)
    return mkList(xs)
  of "let", "let*", "loop", "loop*", "when-let", "if-let", "doseq", "dotimes":
    if xs.len < 2 or xs[1].kind != kVector: fail(h & " requires bindings")
    var bs = xs[1].items
    if bs.len mod 2 != 0: fail(h & " requires paired bindings")
    if h in ["when-let", "if-let", "doseq", "dotimes"] and bs.len != 2:
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
        r.output.add r.walk(ns, f, initHashSet[string]())
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
                   hosts: registeredHostNames())
  r.process(readAll(src))
  r.output
