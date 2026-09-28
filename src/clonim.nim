## clonim — a Clojure compiler hosted on Nim.
##
##   clonim run   foo.clj          compile and run
##   clonim build foo.clj [-o bin] compile to a native binary
##   clonim emit  foo.clj          print the generated Nim
##   clonim repl                   interactive read-eval-print loop
##   clonim version                print the git SHA this binary was built from
import std/[hashes, os, osproc, sequtils, strutils, terminal, times]
import runtime, reader, compiler

proc gitSha(): string {.compileTime.} =
  let (sha, code) = gorgeEx("git -C " & quoteShell(currentSourcePath().parentDir) &
                            " rev-parse HEAD")
  if code == 0: sha.strip else: "unknown"

const
  ClonimSha {.strdefine.} = ""
    ## Override with -d:ClonimSha=<sha> when building outside a git checkout.
  BuildSha = (if ClonimSha.len > 0: ClonimSha else: gitSha())

when defined(releaseCompiler):
  const
    EmbeddedAppRuntime = staticRead("app_runtime.nim")
    EmbeddedRuntimeTypes = staticRead("runtime_types.nim")
    EmbeddedCoreStdlib = staticRead("../stdlib/clonim/core.clj")
    EmbeddedJavaIoStdlib = staticRead("../stdlib/clojure/java/io.clj")
    EmbeddedMvnHttpStdlib = staticRead("../stdlib/jolt/mvn_http.clj")

  proc embeddedRoot(): string =
    ## Materialize the compiler-only inputs under a content-keyed cache. The
    ## runtime implementation is the static archive shipped beside the
    ## compiler; programs only see its private interface.
    var h: Hash = hash(EmbeddedAppRuntime)
    h = h !& hash(EmbeddedRuntimeTypes)
    h = h !& hash(EmbeddedCoreStdlib)
    h = h !& hash(EmbeddedJavaIoStdlib)
    h = h !& hash(EmbeddedMvnHttpStdlib)
    result = getTempDir() / "clonim-runtime" / $(!$h)
    let files = [
      (result / "src" / "app_runtime.nim", EmbeddedAppRuntime),
      (result / "src" / "runtime_types.nim", EmbeddedRuntimeTypes),
      (result / "stdlib" / "clonim" / "core.clj", EmbeddedCoreStdlib),
      (result / "stdlib" / "clojure" / "java" / "io.clj", EmbeddedJavaIoStdlib),
      (result / "stdlib" / "jolt" / "mvn_http.clj", EmbeddedMvnHttpStdlib),
    ]
    for (path, contents) in files:
      createDir(path.parentDir)
      if not fileExists(path) or readFile(path) != contents:
        # Write then rename, so a concurrent clonim never reads a partial file.
        let tmp = path & "." & $getCurrentProcessId() & ".tmp"
        writeFile(tmp, contents)
        moveFile(tmp, path)

proc usage() =
  echo """clonim — a Clojure compiler hosted on Nim

usage:
  clonim run   <file.clj>              compile to Nim, build, and run
  clonim build <file.clj> [-o <bin>]   build a native binary
  clonim emit  <file.clj>              print the generated Nim source
  clonim repl                          start an interactive REPL
  clonim version                       print the git SHA of this build

options:
  -o <path>   output binary path (build)
  --source-path <path>  add a library source root (repeatable)
  -v          show the nim build command and timings
  -d          build with -d:release (default for build, off for run/repl)"""
  quit(1)

proc srcDir(): string =
  ## Where generated programs find the private runtime interface.
  when defined(releaseCompiler):
    return embeddedRoot() / "src"
  for cand in [getAppDir(), getAppDir().parentDir / "src",
               getAppDir().parentDir.parentDir / "src"]:
    if fileExists(cand / "app_runtime.nim"): return cand
  getAppDir()

proc runtimeLib(release: bool): string =
  ## Release archives place the private runtime beside bin/. A source checkout
  ## builds the same archive into lib/ on first use. Nimble installs the
  ## executable beside its sources rather than under bin/, so keep its archive
  ## inside the installed package; putting it in pkgs2/lib makes Nim interpret
  ## that directory as a malformed package on later invocations.
  when defined(releaseCompiler):
    # The AppImage ships one release-mode archive, built with its bundled Zig.
    let shipped = getAppDir() / "libclonim_runtime.a"
    if fileExists(shipped): return shipped
    raise newException(IOError,
      "missing runtime library beside compiler: " & shipped)
  let libName = (if release: "libclonim_runtime.a" else: "libclonim_runtime_debug.a")
  let appDir = getAppDir()
  let installedRoot =
    if fileExists(appDir / "app_runtime.nim"): appDir
    else: appDir.parentDir
  let installed = installedRoot / "lib" / libName
  let source = srcDir() / "runtime_lib.nim"
  if fileExists(installed):
    if not fileExists(source): return installed
    var stale = false
    for f in walkFiles(srcDir() / "*.nim"):
      if getLastModificationTime(f) > getLastModificationTime(installed):
        stale = true
        break
    if not stale: return installed
  if not fileExists(source):
    raise newException(IOError, "missing private runtime library: " & installed)
  createDir(installed.parentDir)
  var args = @["nim", "c", "--app:staticlib", "--nimMainPrefix:ClonimRuntime",
               "--hints:off", "--warnings:off", "--path:" & srcDir(),
               "--nimcache:" & installed.parentDir /
                 (if release: "nimcache-release" else: "nimcache-debug"),
               "-o:" & installed]
  args.add "--passC:-ffunction-sections"
  # The HTTP primitive speaks TLS; without this it can only reach http://.
  args.add "-d:ssl"
  if release: args.add "-d:release"
  args.add source
  let (output, code) = execCmdEx(args.mapIt(quoteShell(it)).join(" "))
  if code != 0:
    raise newException(IOError, "failed to build private runtime library\n" & output)
  installed


proc buildKey(nimSrc: string, release, optimize: bool, rtLib: string): string =
  ## Identifies everything the produced binary depends on. Any change here
  ## invalidates the cached binary for a source file.
  var h: Hash = hash(nimSrc) !& hash(release) !& hash(optimize)

  for f in walkFiles(srcDir() / "*.nim"):
    h = h !& hash(readFile(f))
  let nimExe = findExe("nim")
  if nimExe.len > 0:
    h = h !& hash($getLastModificationTime(nimExe))
  if rtLib.len > 0:
    h = h !& hash($getLastModificationTime(rtLib))
  $(!$h)

type BuildError = object of CatchableError
  output: string  ## what the Nim backend printed

proc buildProgram(nimSrc, stem, keyPath: string,
                  isRun, release, optimize, verbose: bool,
                  outBin: string, tCompile: float): string =
  ## Compiles generated Nim to a native binary and returns its path. `keyPath`
  ## names the program's persistent work directory; `isRun` lets an unchanged
  ## program reuse its last binary. Raises BuildError if the backend fails.
  # Nim module names must be identifiers, but .clj filenames are usually
  # hyphenated; the binary keeps the original stem, the module doesn't.
  var modName = ""
  for ch in stem:
    modName.add (if ch in {'a'..'z', 'A'..'Z', '0'..'9'}: ch else: '_')
  if modName.len == 0 or modName[0] in {'0'..'9'}: modName = "m" & modName
  let pathKey = toHex(hash(keyPath).uint32, 8)
  # The nimcache is persistent and keyed by the source file's absolute path, so
  # repeated `clonim run` on the same file reuses the compiled runtime/core and
  # the Nim stdlib instead of rebuilding them from scratch every time. The .nim
  # file lives in the same directory so its path stays stable across runs too —
  # Nim keys its cache entries on module paths.
  let work = getTempDir() / "clonim" /
             (modName & "-" & pathKey & (if release: "-r" else: ""))
  createDir(work)
  let nimcache = work / "cache"
  let nimFile = work / (modName & ".nim")
  if release and not optimize:
    # The release compiler builds `run` programs in release mode for ABI
    # reasons only. The program's own module is one large C file that takes
    # minutes to compile at -O3 for little gain, so only it drops to -O0. Nim's
    # stdlib stays optimized: its allocator and refcounting are the copies the
    # runtime archive uses too.
    writeFile(nimFile, "{.localPassC: \"-O0\".}\n" & nimSrc)
  else:
    writeFile(nimFile, nimSrc)

  var outBin = outBin
  if outBin.len == 0:
    outBin = (if isRun: work / modName else: stem)
  outBin = outBin.absolutePath

  # Even a warm nimcache costs a second or so of semantic checking and linking.
  # `run` skips the backend entirely when nothing that feeds the binary has
  # changed: the generated Nim, private runtime archive/interface, build flags,
  # and the Nim compiler itself.
  let stamp = work / "stamp"
  let rtLib = runtimeLib(release)
  let cached = isRun and fileExists(outBin) and fileExists(stamp) and
               readFile(stamp) == buildKey(nimSrc, release, optimize, rtLib)

  var nimCmd = @["nim", "c", "--hints:off", "--warnings:off",
                 "--path:" & srcDir(), "--nimcache:" & nimcache,
                 "--passL:" & rtLib, "--passL:-lm", "-o:" & outBin]
  when not defined(releaseCompiler):
    # The release archive's symbols are weak instead (packaging/build-runtime.sh):
    # Zig's linker does not accept this flag.
    nimCmd.add "--passL:-Wl,--allow-multiple-definition"
  # Per-function sections let --gc-sections drop the runtime code a program
  # never reaches.
  nimCmd.add "--passC:-ffunction-sections"
  nimCmd.add "--passC:-fdata-sections"
  nimCmd.add "--passL:-Wl,--gc-sections"
  nimCmd.add "-d:ssl"
  if release:
    # `-d:release` disables Nim runtime checks but keeps DWARF and symbol
    # tables by default. Native deliverables should not carry that metadata.
    nimCmd.add "-d:release"
    # Nim 2.x has no `--strip` switch; pass the portable linker option through
    # instead. Zig cc (the bundled linker) and GNU-compatible linkers accept it.
    nimCmd.add "--passL:-s"
  nimCmd.add nimFile
  if verbose and not cached: echo "clonim: " & nimCmd.join(" ")

  let t1 = epochTime()
  var output = ""
  var code = 0
  if not cached:
    (output, code) = execCmdEx(nimCmd.join(" "))
    if code == 0: writeFile(stamp, buildKey(nimSrc, release, optimize, rtLib))
  let tBuild = epochTime() - t1
  if code != 0:
    var e = newException(BuildError, "Nim backend failed")
    e.output = output
    raise e
  if verbose:
    echo "clonim: analyze ", (tCompile * 1000).formatFloat(ffDecimal, 1), "ms  ",
         "nim ", (tBuild * 1000).formatFloat(ffDecimal, 1), "ms",
         (if cached: " (cached)" else: "")
  outBin

proc headSymbol(form: Value): string =
  ## The unqualified name at the head of a list form, or "".
  if form.kind == kList and form.items.len > 0 and form.items[0].kind == kSymbol:
    result = form.items[0].s
    let slash = result.rfind('/')
    if slash > 0: result = result[slash + 1 .. ^1]

proc cljStr(s: string): string =
  ## `s` as a Clojure string literal.
  "\"" & s.multiReplace(("\\", "\\\\"), ("\"", "\\\"")) & "\""

proc isDefinition(head: string): bool =
  ## Forms that only make sense at top level, so the REPL cannot wrap them in
  ## a `prn` of their value.
  head.startsWith("def") or head in ["ns", "require", "declare", "extend-type",
                                     "extend-protocol", "extend", "import"]

proc repl(sourceRoots: seq[string], release, optimize, verbose: bool) =
  ## clonim has no interpreter, so each input is compiled and run as a whole
  ## program: every earlier successful input, a marker line, then the new
  ## forms with each expression's value printed. Only output after the marker
  ## is shown. Earlier inputs therefore run again on every evaluation, side
  ## effects included; their output is hidden, but not their other effects.
  let marker = "clonim-repl-" & $getCurrentProcessId() & "-" &
               toHex(hash(epochTime()).uint32, 8)
  let keyPath = getCurrentDir() / "<repl>"
  var history: seq[string] = @[]
  var ns = "user"
  let interactive = isatty(stdin)
  if interactive:
    echo "clonim REPL — each input is compiled to a native binary and run."
    echo "Earlier inputs are replayed with their output hidden. :quit or Ctrl-D exits."
  while true:
    # Read lines until they hold complete forms.
    var buf = ""
    var spans: seq[(Value, Slice[int])]
    var eof = false
    while true:
      if interactive:
        stdout.write(if buf.len == 0: ns & "=> " else: " ".repeat(ns.len) & "   ")
        stdout.flushFile
      var line: string
      if not stdin.readLine(line):
        eof = true
        break
      buf.add line & "\n"
      if buf.strip in [":quit", ":q", ":exit"]:
        eof = true
        break
      try:
        spans = readAllSpans(buf)
        break
      except CljError as e:
        if "EOF while reading" in e.msg: continue
        stderr.writeLine("clonim: " & e.msg)
        buf = ""
        break
    if eof:
      if interactive: echo ""
      break
    if spans.len == 0: continue

    var entry: seq[string] = @[]   # the input as it will be replayed
    var shown: seq[string] = @[]   # the input with each value printed
    var bad = ""
    var newNs = ns
    for (form, span) in spans:
      let text = buf[span]
      let head = headSymbol(form)
      entry.add text
      if head == "ns":
        if history.len > 0 or entry.len > 1:
          bad = "ns is only supported as the first REPL input"
        elif form.items.len > 1 and form.items[1].kind == kSymbol:
          newNs = form.items[1].s
        shown.add text
      elif isDefinition(head):
        shown.add text
        let name =
          if form.items.len > 1 and form.items[1].kind == kSymbol and
             head notin ["require", "declare", "extend-type", "extend-protocol",
                         "extend", "import"]:
            "#'" & newNs & "/" & form.items[1].s
          else: "nil"
        shown.add "(println " & cljStr(name) & ")"
      else:
        shown.add "(prn " & text & ")"
    if bad.len > 0:
      stderr.writeLine("clonim: " & bad)
      continue

    # An ns form has to open the program, so it goes before the marker.
    let prefix = history & (if spans[0][0].headSymbol == "ns": @[shown[0]] else: @[])
    let body = (if prefix.len > history.len: @["(println \"nil\")"] & shown[1 .. ^1]
                else: shown)
    let src = (prefix & @["(println " & cljStr(marker) & ")"] & body).join("\n")
    let t0 = epochTime()
    var bin = ""
    try:
      let nimSrc = compileSource(src, sourceRoots)
      bin = buildProgram(nimSrc, "repl", keyPath, true, release, optimize, verbose, "",
                         epochTime() - t0)
    except BuildError as e:
      stderr.writeLine("clonim: " & e.msg & "\n" & e.output)
      continue
    except CljError, IOError, OSError:
      stderr.writeLine("clonim: " & getCurrentExceptionMsg())
      continue
    let (output, code) = execCmdEx(quoteShell(bin))
    let at = output.find(marker & "\n")
    stdout.write(if at >= 0: output[at + marker.len + 1 .. ^1] else: output)
    stdout.flushFile
    if code == 0:
      history.add entry.join("\n")
      ns = newNs
    else:
      stderr.writeLine("clonim: evaluation failed (exit code " & $code & ")")

proc main() =
  let argv = commandLineParams()
  if argv.len >= 1 and argv[0] in ["version", "--version"]:
    echo BuildSha
    quit(0)
  let isRepl = argv.len >= 1 and argv[0] == "repl"
  if argv.len < 2 and not isRepl: usage()
  let cmd = argv[0]
  let file = (if isRepl: "" else: argv[1])
  if not isRepl and not fileExists(file):
    stderr.writeLine("clonim: no such file: " & file)
    quit(1)

  var outBin = ""
  var verbose = false
  var release = cmd == "build"
  var optimize = release
  when defined(releaseCompiler):
    # The distributed compiler ships one release-mode runtime archive. Nim's
    # debug and release modes are not ABI-compatible, so `run` uses it too.
    release = true
  var sourceRoots: seq[string] = @[]
  var i = (if isRepl: 1 else: 2)
  while i < argv.len:
    case argv[i]
    of "-o":
      inc i
      if i >= argv.len or isRepl: usage()
      outBin = argv[i]
    of "--source-path":
      inc i
      if i >= argv.len: usage()
      sourceRoots.add argv[i].absolutePath
    of "-v": verbose = true
    of "-d":
      release = true
      optimize = true
    else: usage()
    inc i

  if isRepl:
    # Source-level libraries are loaded only by an explicit require form.
    sourceRoots.add @[getCurrentDir(), srcDir().parentDir / "stdlib"]
    repl(sourceRoots, release, optimize, verbose)
    return

  let t0 = epochTime()
  var nimSrc = ""
  try:
    # Source-level libraries are loaded only by an explicit require form.
    sourceRoots.add @[getCurrentDir(), file.absolutePath.parentDir,
                      srcDir().parentDir / "stdlib"]
    nimSrc = compileSource(readFile(file), sourceRoots)
  except CljError, IOError, OSError:
    stderr.writeLine("clonim: " & getCurrentExceptionMsg())
    quit(1)
  let tCompile = epochTime() - t0

  if cmd == "emit":
    stdout.write nimSrc
    return

  try:
    outBin = buildProgram(nimSrc, file.splitFile.name, file.absolutePath,
                          cmd == "run", release, optimize, verbose, outBin,
                          tCompile)
  except BuildError as e:
    stderr.writeLine("clonim: " & e.msg & "\n" & e.output)
    stderr.writeLine("--- generated source ---\n" & nimSrc)
    quit(1)
  except IOError, OSError:
    stderr.writeLine("clonim: " & getCurrentExceptionMsg())
    quit(1)

  case cmd
  of "build":
    echo "clonim: wrote " & outBin
  of "run":
    quit(execShellCmd(quoteShell(outBin)))
  else: usage()

main()
