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

## Pipeline

| stage | file | what it does |
|---|---|---|
| reader | `src/reader.nim` | text → data. Forms *are* runtime values (homoiconic), as in Clojure |
| analyzer + codegen | `src/compiler.nim` | expands the macro set to core special forms, emits Nim statements |
| runtime | `src/runtime.nim` | the `Value` tagged union, equality, printing, var cells, `call` |
| core | `src/core.nim` | ~140 `clojure.core` builtins as Nim closures |
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

## What works

`def` `defn` (multi-arity, varargs, docstrings) `fn` (named, self-recursive)
`let` `loop`/`recur` `if` `when` `when-not` `if-not` `cond` `when-let` `if-let`
`do` `and` `or` `->` `->>` `doseq` `dotimes` `try`/`catch`/`finally` `quote`

Destructuring: sequential `[a b & rest]` and associative `{:keys [x y]}` in `let`.

Data: nil, bool, int, float, string, keyword, symbol, list, vector, map, set —
with structural equality and Clojure-shaped printing. Atoms, closures, `comp`,
`partial`, `juxt`, the usual seq library, `clojure.string/*`.

## What doesn't (yet)

- **`defmacro`.** The macro set is fixed and expanded by the compiler. User
  macros need the compiler to be able to *evaluate* code at compile time —
  the honest fix is to bootstrap clonim in itself, or embed an interpreter.
- **Laziness.** `map`/`filter`/`range` are eager. Infinite seqs will hang.
- **Persistent data structures.** Vectors and maps are copy-on-write `seq`s, so
  `assoc` is O(n), not O(log₃₂ n). This is the first thing to replace.
- Protocols/records, namespaces (`ns` is parsed and ignored), refs/agents,
  `#()` literals, syntax-quote, transducers, Nim interop.

## Tests

```bash
./run-tests.sh   # builds the compiler, diffs every example against tests/*.expected
```
