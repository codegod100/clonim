# clonim

A Clojure compiler hosted on Nim.

Inspired by [jank](https://jank-lang.org/), which compiles Clojure onto C++/LLVM
and gets C++'s codegen, inlining and native interop for free. clonim takes the
same bet with a smaller host: **read → analyze → emit Nim → let `nim c` do the
hard part.** The output is a single native binary with no VM and no JVM.

```bash
nim c --hints:off -o:bin/clonim src/clonim.nim   # build the compiler

./bin/clonim run   examples/tour.clj    # compile + run
./bin/clonim build examples/tour.clj    # native binary (-d:release)
./bin/clonim emit  examples/tour.clj    # show the generated Nim
```

There is a `justfile` too: `just build`, `just test`, `just bench`,
`just run <file>`, `just emit <file>`, `just accept` (re-record expectations).

`just bench-store` benchmarks against jolt-lang, commits a timestamped result,
and flags slowdowns above 10% versus the latest compatible run. Requires Jolt
and a clean working tree. Use `just bench-store 15` to change the threshold;
see [benchmark history](bench/README.md) for metrics and exit codes.

`just release` builds the compiler and its private static runtime. Every push
to `main` triggers the release workflow, which packages both into a single
Linux x86_64 AppImage together with Nim 2.2.12 and Zig 0.15.2 as the private C
compiler/linker. The AppImage has no external build dependencies. Generated
programs statically link the clonim runtime and are standalone.
Each push to `main` is tagged and released as the next patch version after the
highest `v*` tag in the series named by `clonim.nimble`'s version; bump that
version to start a new minor or major series. Each release also publishes a `.zsync` file, and the
AppImage embeds matching update information, so an installed copy can be
updated in place with
[AppImageUpdate](https://github.com/AppImageCommunity/AppImageUpdate)
(`appimageupdatetool clonim-linux-x86_64.AppImage`), which moves it to the
latest release.

Source-level libraries are loaded explicitly. Use
`(require '[clonim.core :refer [now-ms]])` to load `stdlib/clonim/core.clj`. Host-dependent operations remain small runtime primitives; for
example, the stdlib `now-ms` function wraps the `*epoch-time-ms*` primitive.

## Namespaces and libraries

Each file may start with a namespace declaration:

```clojure
(ns demo.main
  (:require [clonim.core :as clock]))

(println (clock/now-ms))
```

Top-level `(require 'clonim.core)` loads the library without importing names;
use `clonim.core/now-ms`, an `:as` alias, or an explicit `:refer [now-ms]`.
Definitions belong to their namespace (`user` for scripts without `ns`).
Locals shadow vars, and normal core functions resolve to `clojure.core`.
Forward references require `declare`. A later `def +` creates a var in the
current namespace rather than changing already-resolved core references.

Libraries are loaded once, before their dependents. Namespace names map to paths
with dots as separators and hyphens as underscores. Add search roots with the
repeatable `--source-path <directory>` CLI option; these precede the working
directory, input file's directory, and bundled `stdlib/`. Libraries are never
loaded implicitly merely because their source root is available.

This is a static subset: one leading `ns` per file, literal top-level `require`,
`:as`, explicit `:refer`, and `defn-` privacy. Dynamic namespace operations,
reload options, and `:refer :all` are unsupported.
Missing dependencies, missing vars, and dependency cycles produce errors.

## Pipeline

| stage | file | what it does |
|---|---|---|
| reader | `src/reader.nim` | text → data. Forms *are* runtime values (homoiconic), as in Clojure |
| analyzer + codegen | `src/compiler.nim` | expands the macro set to core special forms, emits Nim statements |
| runtime | `src/runtime.nim` | the `Value` tagged union, the persistent vector/map, equality, printing, var cells, `call`; precompiled into a private static archive |
| core | `src/core.nim` | ~140 `clojure.core` builtins as Nim closures |
| stdlib | `stdlib/clonim/core.clj` | source-level helpers loaded by explicit require |
| driver | `src/clonim.nim` | shells out to `nim c`, times each phase |

Codegen is statement-oriented: every form is compiled as "emit statements that
assign into this destination slot". That keeps Clojure's expression semantics
intact without fighting Nim's statement/expression split, and it makes
`recur` trivially correct.

### Two things worth pointing at

**`recur` becomes a real loop.** A `loop`/`fn` recur target emits `while true:`
over mutable Nim locals; `recur` assigns the new values and `continue`s. No
stack growth, no trampoline — `(sum-to 1000000)` runs in constant space.

**Vars are cells, resolved once.** Each referenced var becomes a `VarCell`
resolved in the program prelude, so a call site is a pointer deref rather than a
hash lookup, while `def` can still rebind it later. Worth ~20% on call-heavy
code.

**Collections share structure.** Vectors are 32-way tries with a tail buffer
(Clojure's `PersistentVector`); maps and sets are HAMTs. An `assoc` copies a
handful of 32-wide nodes and points at the rest of the old value, so it is
O(log₃₂ n) and the original stays valid — which is what makes the persistent
part of persistent data structures real rather than a spelling of "copy".

Maps and sets also keep insertion order: each entry carries an `ord` stamp and
iteration sorts by it, so printing, `keys` and `vals` are deterministic the way
Clojure's small array-maps are, without giving up hashed lookup.

`examples/persistent_bench.clj` (`just bench`), n = 8000, `-d:release`:

| operation | copy-on-write `seq` | trie / HAMT |
|---|---:|---:|
| 8000 × `conj` onto a vector | 489 ms | 29 ms |
| 8000 × `assoc` onto a map | 448 ms | 64 ms |
| 8000 × `conj` onto a set | 526 607 ms | 102 ms |
| 8000 × `get` from a map | 3031 ms | 50 ms |

The set column is the honest shape of the old representation: `conj` rebuilt the
whole set and re-scanned it for duplicates, so building one was O(n³).

**Seqs are lazy.** `map`, `filter`, `remove`, `range`, `take`, `drop`,
`take-while`, `drop-while`, `concat`, `map-indexed`, `iterate`, `repeat`,
`repeatedly` and `cycle` return a chain of thunks: each element is computed on
first demand and memoized, so infinite seqs are ordinary values and a consumer
that stops early never pays for the rest.

```clojure
(take 5 (filter even? (range)))            ;=> (0 2 4 6 8)
(first (filter odd? (map inc (range 2000000))))   ; 671 ms eager -> 0 ms lazy
```

Everything in `core` walks collections through one `Cursor`, which follows a
cons/lazy chain link by link and indexes concrete collections directly, so a
builtin never materializes more of a seq than it was asked for. `nth`, `first`,
`rest`, `seq`, `empty?` and `& rest` destructuring all stop at the element they
need; `count`, `reduce` and printing realize the whole seq, which is what those
mean.

The cost is the usual one: a fully realized lazy seq allocates a cons cell and
a thunk per element, where the eager version filled one flat `seq`. Realizing
all of `(map inc (range 1000000))` went from 290 ms to 570 ms. Clojure buys most
of that back by realizing in 32-element chunks; clonim does not chunk yet, which
is why its laziness is exact — `take 3` computes exactly three elements, not
thirty-two.

Long chains need one piece of care. ARC frees a linked structure by recursing
into it, so dropping a million-element seq means a million destructor frames and
a segfault. `Value` therefore has a hand-written `=destroy` that hands a cons or
lazy tail to a worklist and drains it in a loop. Nothing shared is mutated, so a
tail another seq still holds simply survives.

## What works

`def` `defn` (multi-arity, varargs, docstrings) `fn` (named, self-recursive)
`defmacro` (including variadic parameters, `&form`, and `&env`)
`let` `loop`/`recur` `if` `when` `when-not` `if-not` `cond` `when-let` `if-let`
`do` `and` `or` `->` `->>` `doseq` `dotimes` `try`/`catch`/`finally` `quote`

Destructuring: sequential `[a b & rest]` and associative `{:keys [x y]}` in `let`,
`loop`, `doseq`, `when-let`/`if-let` and parameter lists.

`for` takes `:when`, `:let` and `:while`; `doseq` takes several bindings and the
same modifiers; `while` loops.

Types: `reify`, `deftype` and `defprotocol`. Methods dispatch by name, so an
object that implements `valAt`, `seq`, `count`, `containsKey`, `deref`,
`invoke`, `toString`, `equals` or `hashCode` works with `get`, keyword lookup,
`seq`/`keys`, `count`, `contains?`, `@`, calls, `str`, `=` and `hash`.
`(.method obj args)`, `(. obj method args)` and `(Type. args)` call methods and
constructors.

Reading data: `read-string` (honouring `*data-readers*` and
`*default-data-reader-fn*`) and `clojure.edn/read-string` with `:readers`,
`:default` and `:eof`. `#inst` and `#uuid` read as instants and UUIDs, which
print, compare and hash as on the JVM (`inst-ms`, `java.util.Date.`,
`random-uuid`, `parse-uuid`).

Errors: `ex-info` values keep their data through `throw` and `catch`
(`ex-message`, `ex-data`).

Ordering: `compare` is Clojure's total order within a type (numbers, strings,
keywords, symbols, booleans, chars, vectors, instants, UUIDs). `sort` and
`sort-by` take a comparator or boolean predicate and are stable
O(n log n) merge sorts.

Data: nil, bool, int, float, string, keyword, symbol, list, vector, map, set —
persistent, with structural equality, hashing, and Clojure-shaped printing. Atoms, closures, `comp`,
`partial`, `juxt`, the usual seq library, `clojure.string/*`.

Agents: `agent`, `send`, `await`, `agent-error`, and `restart-agent`. Agents
serialize queued state transitions; this initial implementation is cooperative,
so queued actions run when an agent is dereferenced, awaited, or inspected for
an error rather than on a background thread.

Lazy seqs: `iterate` `repeat` `repeatedly` `cycle` `doall` `dorun`, and the seq
library above returns them where Clojure does.

## What doesn't (yet)

- **Syntax-quote.** User macros can construct forms with `quote` and ordinary
  core functions such as `list`, `vector`, and `apply`, but automatic
  namespace qualification through syntax-quote/unquote is not implemented yet.
- **Chunked seqs.** Lazy seqs are unchunked, so full realization allocates two
  cells per element and runs ~2× slower than the old eager path. 32-element
  chunking is the fix, at the cost of exact demand.
- Records and multimethods, dynamic namespace operations, refs,
  syntax-quote, transducers, Nim interop.

## Tests

```bash
./run-tests.sh   # builds the compiler, diffs every example against tests/*.expected
nim r --path:src tests/test_namespaces.nim  # namespace resolution and loader tests
```
