## clonim — a Clojure compiler hosted on Nim.
##
##   clonim run   foo.clj          compile and run
##   clonim build foo.clj [-o bin] compile to a native binary
##   clonim emit  foo.clj          print the generated Nim
##   clonim repl                   interactive read-eval-print loop
##   clonim version                print the git SHA this binary was built from
import std/[hashes, os, osproc, posix, sequtils, strutils, terminal, times]
import runtime, reader, compiler, namespaces
when not defined(windows):
  import std/linenoise

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
    EmbeddedReplNimbase = staticRead("repl/nimbase.h")

  proc embeddedRoot(): string =
    ## Materialize the compiler-only inputs under a content-keyed cache. The
    ## runtime implementation is the static archive shipped beside the
    ## compiler; programs only see its private interface.
    var h: Hash = hash(EmbeddedAppRuntime)
    h = h !& hash(EmbeddedRuntimeTypes)
    h = h !& hash(EmbeddedCoreStdlib)
    h = h !& hash(EmbeddedJavaIoStdlib)
    h = h !& hash(EmbeddedMvnHttpStdlib)
    h = h !& hash(EmbeddedReplNimbase)
    result = getTempDir() / "clonim-runtime" / $(!$h)
    let files = [
      (result / "src" / "app_runtime.nim", EmbeddedAppRuntime),
      (result / "src" / "runtime_types.nim", EmbeddedRuntimeTypes),
      (result / "stdlib" / "clonim" / "core.clj", EmbeddedCoreStdlib),
      (result / "stdlib" / "clojure" / "java" / "io.clj", EmbeddedJavaIoStdlib),
      (result / "stdlib" / "jolt" / "mvn_http.clj", EmbeddedMvnHttpStdlib),
      (result / "src" / "repl" / "nimbase.h", EmbeddedReplNimbase),
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
  --source-path <path>  add a library source root (repeatable; ./src is
                        always searched when it exists)
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

proc replHistoryFile(): string =
  getEnv("CLONIM_HISTORY", getHomeDir() / ".clonim_history")

type ReplRead = enum rrLine, rrCancel, rrEof

proc replReadLine(prompt: string, interactive: bool, line: var string): ReplRead =
  ## One line of REPL input. At a terminal this goes through linenoise, so the
  ## line can be edited and earlier lines recalled with the arrow keys; Ctrl-C
  ## cancels the input so far and Ctrl-D on an empty line exits.
  when not defined(windows):
    if interactive:
      var res: ReadLineResult
      readLineStatus(prompt, res)
      case res.status
      of lnCtrlC: return rrCancel
      of lnCtrlD: return rrEof
      else: discard
      line = res.line
      if line.strip.len > 0:
        discard historyAdd(line.cstring)
        discard historySave(replHistoryFile().cstring)
      return rrLine
  if interactive:
    stdout.write(prompt)
    stdout.flushFile
  if stdin.readLine(line): rrLine else: rrEof

proc replHostExe(release: bool): string =
  ## The REPL host (src/repl_host.nim): a runtime that stays up for the whole
  ## session. Release archives ship it beside the compiler; a source checkout
  ## builds it into lib/ on first use, like the runtime archive.
  when defined(releaseCompiler):
    result = getAppDir() / "clonim-repl-host"
    if not fileExists(result):
      raise newException(IOError, "missing REPL host beside compiler: " & result)
    return
  let appDir = getAppDir()
  let installedRoot =
    if fileExists(appDir / "app_runtime.nim"): appDir
    else: appDir.parentDir
  result = installedRoot / "lib" /
           (if release: "clonim-repl-host" else: "clonim-repl-host-debug")
  let source = srcDir() / "repl_host.nim"
  if fileExists(result):
    if not fileExists(source): return
    var stale = getLastModificationTime(srcDir() / "repl" / "nimbase.h") >
                getLastModificationTime(result)
    for f in walkFiles(srcDir() / "*.nim"):
      if getLastModificationTime(f) > getLastModificationTime(result):
        stale = true
    if not stale: return
  if not fileExists(source):
    raise newException(IOError, "missing REPL host: " & result)
  stderr.writeLine("clonim: building the REPL host (once per runtime change)")
  createDir(result.parentDir)
  var args = @["nim", "c", "--hints:off", "--warnings:off",
               "--path:" & srcDir(), "--passC:-I" & srcDir() / "repl",
               "--passL:-rdynamic", "-d:ssl",
               "--nimcache:" & result.parentDir /
                 (if release: "nimcache-host-release" else: "nimcache-host-debug"),
               "-o:" & result]
  if release: args.add "-d:release"
  args.add source
  let (output, code) = execCmdEx(args.mapIt(quoteShell(it)).join(" "))
  if code != 0:
    raise newException(IOError, "failed to build REPL host\n" & output)

proc buildReplInput(nimSrc, work, outLib: string,
                    release, optimize, verbose: bool) =
  ## Compiles one REPL input to a shared library for the host to load. The
  ## module path stays the same across inputs so the nimcache keeps the Nim
  ## system module compiled; only the input's own C file is rebuilt.
  let nimFile = work / "clonim_repl_input.nim"
  if release and not optimize:
    writeFile(nimFile, "{.localPassC: \"-O0\".}\n" & nimSrc)  # see buildProgram
  else:
    writeFile(nimFile, nimSrc)
  var nimCmd = @["nim", "c", "--app:lib", "--noMain", "--hints:off",
                 "--warnings:off", "--path:" & srcDir(),
                 "--passC:-I" & srcDir() / "repl", "--nimcache:" & work / "cache",
                 "-d:ssl", "-o:" & outLib]
  if release: nimCmd.add "-d:release"
  nimCmd.add nimFile
  let cmd = nimCmd.mapIt(quoteShell(it)).join(" ")
  if verbose: echo "clonim: " & cmd
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    var e = newException(BuildError, "Nim backend failed")
    e.output = output
    raise e

type ReplHost = object
  exe: string
  process: Process
  commands, replies: File
  loaded: seq[string]   ## libraries that ran, to rebuild state after a crash

proc start(h: var ReplHost) =
  ## The host gets a pipe each way on inherited descriptors; stdout and stderr
  ## are the driver's own, so program output reaches the terminal directly.
  var toHost, fromHost: array[0..1, cint]
  if pipe(toHost) != 0 or pipe(fromHost) != 0:
    raiseOSError(osLastError())
  # Only the host may inherit its ends; keep ours out of later `nim c` runs.
  discard fcntl(toHost[1], F_SETFD, FD_CLOEXEC)
  discard fcntl(fromHost[0], F_SETFD, FD_CLOEXEC)
  try:
    h.process = startProcess(h.exe, args = [$toHost[0], $fromHost[1]],
                             options = {poParentStreams})
  finally:
    discard close(toHost[0])
    discard close(fromHost[1])
  discard open(h.commands, FileHandle(toHost[1]), fmWrite)
  discard open(h.replies, FileHandle(fromHost[0]), fmRead)

proc stop(h: var ReplHost) =
  if h.process == nil: return
  h.commands.close
  h.replies.close
  discard h.process.waitForExit
  h.process.close
  h.process = nil

proc send(h: var ReplHost, verb, lib: string): int =
  ## The library's status, or -1 when the host died running it.
  stdout.flushFile
  try:
    h.commands.writeLine(verb & " " & lib)
    h.commands.flushFile
    var reply: string
    if h.replies.readLine(reply): return reply.parseInt
  except IOError, ValueError: discard
  -1

proc eval(h: var ReplHost, lib: string): int =
  ## Runs one input. If the host dies (a crash, or Ctrl-C during a long
  ## evaluation), a new one replays the inputs that had run, output hidden.
  # Ctrl-C reaches the whole foreground process group; only the host stops.
  signal(SIGINT, SIG_IGN)
  result = h.send("eval", lib)
  signal(SIGINT, SIG_DFL)
  if result == 0 or result == 1:
    h.loaded.add lib
  elif result < 0:
    let code = h.process.waitForExit
    h.stop
    stderr.writeLine("clonim: evaluation " &
      (if code == 128 + SIGINT.int or code == -SIGINT.int: "interrupted"
       else: "crashed (exit code " & $code & ")") &
      "; restarting and replaying " & $h.loaded.len & " earlier input(s)")
    h.start
    for earlier in h.loaded:
      if h.send("quiet", earlier) < 0:
        stderr.writeLine("clonim: replay failed; earlier definitions are lost")
        h.stop
        h.start
        h.loaded = @[]
        break

proc repl(sourceRoots: seq[string], release, optimize, verbose: bool) =
  ## clonim has no interpreter, so each input is compiled to a shared library
  ## and run by a long-lived host process that holds the runtime, and with it
  ## every var earlier inputs defined. The compiler side keeps a matching
  ## resolver, so inputs see earlier definitions, namespaces and macros.
  let work = getTempDir() / "clonim" /
             ("repl-" & toHex(hash(getCurrentDir()).uint32, 8) &
              (if release: "-r" else: ""))
  var host = ReplHost()
  try:
    host.exe = replHostExe(release)
  except IOError, OSError:
    stderr.writeLine("clonim: " & getCurrentExceptionMsg())
    quit(1)
  let libs = work / ("session-" & $getCurrentProcessId())
  createDir(libs)
  defer: removeDir(libs)
  signal(SIGPIPE, SIG_IGN)   # a dead host must not take the driver with it
  host.start
  defer: host.stop

  var resolver = newReplResolver(sourceRoots)
  var ns = "user"
  var inputs = 0
  let interactive = isatty(stdin)
  if interactive:
    echo "clonim REPL — each input is compiled to a native library and run once."
    echo ":quit or Ctrl-D exits."
    when not defined(windows):
      discard historySetMaxLen(1000)
      discard historyLoad(replHistoryFile().cstring)
  while true:
    # Read lines until they hold complete forms.
    var buf = ""
    var spans: seq[(Value, Slice[int])]
    var eof = false
    while true:
      let prompt = (if buf.len == 0: ns & "=> " else: " ".repeat(ns.len) & "   ")
      var line: string
      case replReadLine(prompt, interactive, line)
      of rrEof:
        eof = true
        break
      of rrCancel:
        buf = ""
        break
      of rrLine: discard
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

    var shown: seq[string] = @[]   # the input with each value printed
    var newNs = ns
    for (form, span) in spans:
      let text = buf[span]
      let head = headSymbol(form)
      if head == "ns":
        if form.items.len > 1 and form.items[1].kind == kSymbol:
          newNs = form.items[1].s
        shown.add text
        shown.add "(println \"nil\")"
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

    # A failed resolve or build leaves the session as it was before the input.
    let before = resolver.snapshot
    let t0 = epochTime()
    inc inputs
    let lib = libs / ("input" & $inputs & ".so")
    var tCompile = 0.0
    try:
      let nimSrc = compileReplForms(resolver.resolveRepl(shown.join("\n"), ns))
      tCompile = epochTime() - t0
      buildReplInput(nimSrc, work, lib, release, optimize, verbose)
    except BuildError as e:
      resolver = before
      stderr.writeLine("clonim: " & e.msg & "\n" & e.output)
      continue
    except CljError, IOError, OSError:
      resolver = before
      stderr.writeLine("clonim: " & getCurrentExceptionMsg())
      continue
    let tBuild = epochTime() - t0 - tCompile
    let t1 = epochTime()
    let status = host.eval(lib)
    if verbose:
      stderr.writeLine("clonim: analyze " & (tCompile * 1000).formatFloat(ffDecimal, 1) &
        "ms  nim " & (tBuild * 1000).formatFloat(ffDecimal, 1) &
        "ms  eval " & ((epochTime() - t1) * 1000).formatFloat(ffDecimal, 1) & "ms")
    # Forms that ran before an error keep their effects, as in Clojure, so the
    # resolver keeps the input's definitions unless the host lost them.
    if status in [0, 1]: ns = newNs
    else: resolver = before

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
  # Like the Clojure CLI's default `:paths ["src"]`, the working directory's
  # src/ is a source root without any flag, after the explicit ones.
  if dirExists(getCurrentDir() / "src"):
    sourceRoots.add getCurrentDir() / "src"

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
