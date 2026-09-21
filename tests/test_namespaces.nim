## Run with: nim r --hints:off --path:src tests/test_namespaces.nim
import std/[unittest, os, tempfiles, strutils, tables]
import runtime, reader, core, namespaces

proc checkForms(src, expected: string, roots: seq[string] = @[]) =
  let actual = resolveSource(src, roots)
  let wanted = readAll(expected)
  check actual.len == wanted.len
  if actual.len == wanted.len:
    for i in 0 ..< actual.len:
      checkpoint "actual: " & prStr(actual[i]) & "; expected: " & prStr(wanted[i])
      check equals(actual[i], wanted[i])

proc rejects(src, message: string, roots: seq[string] = @[]) =
  var rejected = false
  try:
    discard resolveSource(src, roots)
  except CljError as e:
    rejected = true
    checkpoint e.msg
    check message in e.msg
  check rejected

suite "static namespace resolution":
  test "regex literals preserve their pattern source":
    let forms = readAll("#\"(?i)^did:[a-z0-9]+:\"")
    check forms.len == 1
    check forms[0].kind == kStr
    check forms[0].s == "(?i)^did:[a-z0-9]+:"

  test "host namespaces resolve without placeholder source files":
    checkForms("(ns user (:require [clojure.string :as str])) (str/trim \" hi \")",
      "(clojure.string/trim \" hi \")")

  test "definitions resolve sequentially, including core shadowing":
    checkForms("(inc 1) (def inc (fn [x] x)) (inc 2)",
      "(clojure.core/inc 1) (def user/inc (fn [x] x)) (user/inc 2)")
    checkForms("(defn before [x] (inc x)) (def inc (fn [x] x))",
      "(defn user/before [x] (clojure.core/inc x)) (def user/inc (fn [x] x))")
    checkForms("(when true 1) (def when (fn [x] x)) (when 2)",
      "(when true 1) (def user/when (fn [x] x)) (user/when 2)")

  test "unknown symbols and forward references require declare":
    rejects("missing", "unable to resolve symbol missing")
    rejects("(defn first [] (later)) (defn later [] 1)", "unable to resolve symbol later")
    checkForms("(declare later) (defn first [] (later)) (defn later [] 1)",
      "(declare user/later) (defn user/first [] (user/later)) (defn user/later [] 1)")

  test "definitions are visible in their own bodies":
    checkForms("(defn f [x] (f x)) (defn- hidden [] (hidden))",
      "(defn user/f [x] (user/f x)) (defn- user/hidden [] (user/hidden))")
    checkForms("(def f (fn [] f))", "(def user/f (fn [] user/f))")

  test "locals shadow macros, including comment and binding macros":
    checkForms("(let [when +] (when 1 2))",
      "(let [when clojure.core/+] ((do when) 1 2))")
    checkForms("(fn [comment let -> require] [(comment 1) (let 2) (-> 3) (require 4)])",
      "(fn [comment let -> require] [((do comment) 1) ((do let) 2) ((do ->) 3) ((do require) 4)])")
    checkForms("(fn when [x] (when x))", "(fn when [x] ((do when) x))")
    checkForms("(let [when +] (clojure.core/when true (when 1 2)))",
      "(let [when clojure.core/+] (when true ((do when) 1 2)))")

  test "true special forms are not shadowed in operator position":
    checkForms("(let [if +] (if true 1 2))", "(let [if clojure.core/+] (if true 1 2))")

  test "ordinary locals, sequential bindings, functions and destructuring":
    checkForms("(let [x 1 y x] (fn self ([z] (self z y)) ([z q] (+ x z q))))",
      "(let [x 1 y x] (fn self ([z] (self z y)) ([z q] (clojure.core/+ x z q))))")
    checkForms("(def fallback 9) (let [{:keys [x] :or {x fallback} :as m} {}] [x m])",
      "(def user/fallback 9) (let [{:keys [x] :or {x user/fallback} :as m} {}] [x m])")
    checkForms("(loop [[x & more :as all] [1 2]] (recur all))",
      "(loop [[x & more :as all] [1 2]] (recur all))")
    rejects("(let [x y y 1] x)", "unable to resolve symbol y")

  test "conditional bindings and catch scope do not leak":
    rejects("(if-let [x 1] x x)", "unable to resolve symbol x")
    checkForms("(def x 2) (if-let [x 1] x x)",
      "(def user/x 2) (if-let [x 1] x user/x)")
    checkForms("(try 1 (catch Exception e (str e)) (finally 2))",
      "(try 1 (catch Exception e (clojure.core/str e)) (finally 2))")
    rejects("(try 1 (catch Exception e e) (finally e))", "unable to resolve symbol e")

  test "quotes and comments are data and do not declare vars":
    checkForms("'(missing missing.ns/x (def imaginary 1)) (comment missing)",
      "(quote (missing missing.ns/x (def imaginary 1))) (comment missing)")
    rejects("'(def imaginary 1) imaginary", "unable to resolve symbol imaginary")
    rejects("(comment (def imaginary 1)) imaginary", "unable to resolve symbol imaginary")

  test "macro bindings and threading keep their scopes":
    checkForms("(defmacro m [x] (list 'quote x &form &env))",
      "(defmacro user/m [x] (clojure.core/list (quote quote) x &form &env))")
    checkForms("(let [when +] (-> 1 (when 2)))",
      "(let [when clojure.core/+] ((do when) 1 2))")

  test "qualified core and current namespace names are checked":
    checkForms("(def x 1) user/x (clojure.core// 6 2)",
      "(def user/x 1) user/x (clojure.core// 6 2)")
    rejects("user/nope", "no definition user/nope")
    rejects("clojure.core/nope", "no definition clojure.core/nope")
    rejects("stranger/x", "namespace stranger is not required")

  test "dynamic namespace operations and unsupported imports fail":
    for src in ["(require variable)", "(apply require [])", "(fn [] (require 'foo))",
                "(import 'Thing)", "(ns app (:import Thing))", "(require '[foo :refer :all])"]:
      rejects(src, "Namespace error")

  test "core discovery preserves caller cells even after analysis failure":
    let saved = globals
    globals = initTable[string, VarCell]()
    try:
      registerCore()
      discard setVar("inc", mkInt(42))
      let cell = varCell("inc")
      checkForms("(inc 1)", "(clojure.core/inc 1)")
      rejects("missing", "unable to resolve")
      check varCell("inc") == cell
      check getVar("inc").i == 42
      registerNamespaceCore()
      check varCell("clojure.core/inc") == cell
    finally:
      globals = saved

suite "namespace source loader":
  var root: string
  setup:
    root = createTempDir("clonim-namespaces-", "")
    createDir(root / "sample")
    writeFile(root / "sample" / "lib_one.clj", """
      (ns sample.lib-one)
      (def value 7)
      (defn- hidden [] value)
      (defn public [] (hidden))
      (def when (fn [x] x))
    """)
    writeFile(root / "consumer.clj", """
      (ns consumer (:require [sample.lib-one :as inner :refer [value]]))
      (def result inner/value)
    """)
    writeFile(root / "other.clj", """
      (ns other (:require sample.lib-one))
      (def result sample.lib-one/value)
    """)
  teardown:
    removeDir(root)

  test "alias, refer and plain require produce the same canonical var":
    let forms = resolveSource("""
      (ns app (:require [sample.lib-one :as lib :refer [value]]))
      (require 'sample.lib-one)
      [lib/value value sample.lib-one/value]
    """, @[root])
    check forms.len == 5
    check prStr(forms[^1]) == "[sample.lib-one/value sample.lib-one/value sample.lib-one/value]"
    check prStr(forms[2]) == "(defn sample.lib-one/public [] (sample.lib-one/hidden))"

  test "plain require imports no unqualified names or aliases":
    rejects("(require 'sample.lib-one) value", "unable to resolve symbol value", @[root])
    rejects("(require 'sample.lib-one) lib/value", "namespace lib is not required", @[root])
    let forms = resolveSource("(require 'sample.lib-one) sample.lib-one/value", @[root])
    check prStr(forms[^1]) == "sample.lib-one/value"

  test "alias require imports no unqualified names":
    rejects("(require '[sample.lib-one :as lib]) value", "unable to resolve symbol value", @[root])

  test "aliases and refers do not leak from dependencies":
    rejects("(require 'consumer) inner/value", "namespace inner is not required", @[root])
    rejects("(require 'consumer) value", "unable to resolve symbol value", @[root])
    rejects("(require 'consumer) sample.lib-one/value", "namespace sample.lib-one is not required", @[root])
    rejects("(require '[sample.lib-one :as lib]) (require 'consumer) inner/value",
      "namespace inner is not required", @[root])

  test "required missing vars and private vars fail through all spellings":
    for member in ["missing", "hidden"]:
      let reason = if member == "hidden": "private var sample.lib-one/hidden" else: "no definition sample.lib-one/missing"
      rejects("(require 'sample.lib-one) sample.lib-one/" & member, reason, @[root])
      rejects("(require '[sample.lib-one :as lib]) lib/" & member, reason, @[root])
      rejects("(require '[sample.lib-one :refer [" & member & "]])", reason, @[root])

  test "referred and aliased vars can shadow core macro names":
    let forms = resolveSource("(require '[sample.lib-one :as lib :refer [when]]) (when 1) (lib/when 2)", @[root])
    check prStr(forms[^2]) == "(sample.lib-one/when 1)"
    check prStr(forms[^1]) == "(sample.lib-one/when 2)"

  test "core aliases and explicit core syntax referrals":
    checkForms("(ns app (:require [clojure.core :as c :refer [when]])) (c/when true (c/inc 1)) (when true 2)",
      "(when true (clojure.core/inc 1)) (when true 2)")

  test "conflicting aliases, referrals and definitions are rejected":
    rejects("(require '[sample.lib-one :as lib] '[consumer :as lib])", "conflicting alias", @[root])
    rejects("(require '[consumer :refer [result]] '[other :refer [result]])", "conflicting referred name", @[root])
    rejects("(require '[sample.lib-one :refer [value]]) (def value 1)", "definition conflicts", @[root])
    rejects("(def value 1) (require '[sample.lib-one :refer [value]])", "conflicting referred name", @[root])

  test "diamond dependencies are loaded once in dependency order":
    let forms = resolveSource("(require 'consumer 'other 'sample.lib-one 'consumer)", @[root])
    check forms.len == 6
    check prStr(forms[0]) == "(def sample.lib-one/value 7)"
    check prStr(forms[^2]) == "(def consumer/result sample.lib-one/value)"
    check prStr(forms[^1]) == "(def other/result sample.lib-one/value)"
    # A new resolver call has its own load cache.
    check resolveSource("(require 'consumer 'other)", @[root]).len == 6
    rejects("consumer/result", "namespace consumer is not required", @[root])

  test "missing source and mismatched declarations are rejected":
    rejects("(require 'absent)", "cannot find absent", @[root])
    writeFile(root / "wrong.clj", "(ns different)")
    rejects("(require 'wrong)", "must declare (ns wrong)", @[root])
    writeFile(root / "bare.clj", "(def x 1)")
    rejects("(require 'bare)", "must declare (ns bare)", @[root])

  test "cycles report the dependency chain including the root":
    writeFile(root / "a.clj", "(ns a (:require b))")
    writeFile(root / "b.clj", "(ns b (:require a))")
    rejects("(require 'a)", "user -> a -> b -> a", @[root])
    rejects("(ns a (:require b))", "a -> b -> a", @[root])

  test "definitions cannot see requires occurring later":
    rejects("sample.lib-one/value (require 'sample.lib-one)",
      "namespace sample.lib-one is not required", @[root])

  test "clj is preferred to cljc and roots retain their order":
    writeFile(root / "choice.clj", "(ns choice) (def value 1)")
    writeFile(root / "choice.cljc", "(ns choice) (def value 2)")
    createDir(root / "first")
    writeFile(root / "first" / "choice.cljc", "(ns choice) (def value 3)")
    checkForms("(require 'choice)", "(def choice/value 1)", @[root])
    checkForms("(require 'choice)", "(def choice/value 3)", @[root / "first", root])
