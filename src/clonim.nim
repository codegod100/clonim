## clonim — a Clojure compiler hosted on Nim.
##
##   clonim run   foo.clj          compile and run
##   clonim build foo.clj [-o bin] compile to a native binary
##   clonim emit  foo.clj          print the generated Nim
##   clonim version                print the git SHA this binary was built from
import std/[hashes, os, osproc, sequtils, strutils, times]
import runtime, compiler

proc gitSha(): string {.compileTime.} =
  let (sha, code) = gorgeEx("git -C " & quoteShell(currentSourcePath().parentDir) &
                            " rev-parse HEAD")
  if code == 0: sha.strip else: "unknown"

const
  ClonimSha {.strdefine.} = ""
    ## Override with -d:ClonimSha=<sha> when building outside a git checkout.
  BuildSha = (if ClonimSha.len > 0: ClonimSha else: gitSha())

when defined(releaseCompiler):
  # The release workflow's runtime cache key lists these files; keep it in step.
  const
    EmbeddedAppRuntime = staticRead("app_runtime_source.nim")
    EmbeddedRuntimeTypes = staticRead("runtime_types.nim")
    EmbeddedRuntime = staticRead("runtime.nim")
    EmbeddedCore = staticRead("core.nim")
    EmbeddedNamespaces = staticRead("namespaces.nim")
    EmbeddedReader = staticRead("reader.nim")
    EmbeddedRuntimeLib = staticRead("runtime_lib.nim")
    EmbeddedCoreStdlib = staticRead("../stdlib/clonim/core.clj")
    EmbeddedJavaIoStdlib = staticRead("../stdlib/clojure/java/io.clj")
    EmbeddedMvnHttpStdlib = staticRead("../stdlib/jolt/mvn_http.clj")

  proc embeddedRoot(): string =
    ## Materialize the compiler-only inputs under a content-keyed cache. The
    ## runtime implementation remains the separately shipped static archive.
    var h: Hash = hash(EmbeddedAppRuntime)
    h = h !& hash(EmbeddedRuntimeTypes)
    h = h !& hash(EmbeddedRuntime)
    h = h !& hash(EmbeddedCore)
    h = h !& hash(EmbeddedNamespaces)
    h = h !& hash(EmbeddedReader)
    h = h !& hash(EmbeddedRuntimeLib)
    h = h !& hash(EmbeddedCoreStdlib)
    h = h !& hash(EmbeddedJavaIoStdlib)
    h = h !& hash(EmbeddedMvnHttpStdlib)
    result = getTempDir() / "clonim-runtime" / $(!$h)
    let files = [
      (result / "src" / "app_runtime.nim", EmbeddedAppRuntime),
      (result / "src" / "runtime_types.nim", EmbeddedRuntimeTypes),
      (result / "src" / "runtime.nim", EmbeddedRuntime),
      (result / "src" / "core.nim", EmbeddedCore),
      (result / "src" / "namespaces.nim", EmbeddedNamespaces),
      (result / "src" / "reader.nim", EmbeddedReader),
      (result / "src" / "runtime_lib.nim", EmbeddedRuntimeLib),
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

  proc flock(fd: cint, op: cint): cint {.importc, header: "<sys/file.h>".}
  var LOCK_EX {.importc, header: "<sys/file.h>".}: cint
  var EINTR {.importc, header: "<errno.h>".}: cint

  proc withRuntimeCache(nimcache: string, build: proc (): int): int =
    ## Runs `build` against the shared runtime nimcache. The first build
    ## compiles the runtime's objects into it, and concurrent first builds would
    ## overwrite each other's files, so it holds an exclusive lock until a build
    ## succeeds. Later builds only read those objects and skip the lock.
    let warm = nimcache / "warm"
    if fileExists(warm): return build()
    createDir(nimcache)
    var lock: File
    if not open(lock, nimcache & ".lock", fmReadWrite):
      raise newException(IOError, "cannot open " & nimcache & ".lock")
    while flock(getOsFileHandle(lock), LOCK_EX) != 0:
      if osLastError() != OSErrorCode(EINTR):
        close(lock)
        raiseOSError(osLastError())
    if fileExists(warm):
      # Another build warmed the cache while this one waited; build alongside
      # the others rather than one at a time.
      close(lock)
      return build()
    try:
      result = build()
      if result == 0: writeFile(warm, "")
    finally:
      close(lock)  # closing the descriptor releases the lock

proc usage() =
  echo """clonim — a Clojure compiler hosted on Nim

usage:
  clonim run   <file.clj>              compile to Nim, build, and run
  clonim build <file.clj> [-o <bin>]   build a native binary
  clonim emit  <file.clj>              print the generated Nim source
  clonim version                       print the git SHA of this build

options:
  -o <path>   output binary path (build)
  --source-path <path>  add a library source root (repeatable)
  -v          show the nim build command and timings
  -d          build with -d:release (default for build, off for run)"""
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


proc buildKey(nimSrc: string, release: bool, rtLib: string): string =
  ## Identifies everything the produced binary depends on. Any change here
  ## invalidates the cached binary for a source file.
  var h: Hash = hash(nimSrc) !& hash(release)

  for f in walkFiles(srcDir() / "*.nim"):
    h = h !& hash(readFile(f))
  let nimExe = findExe("nim")
  if nimExe.len > 0:
    h = h !& hash($getLastModificationTime(nimExe))
  if rtLib.len > 0:
    h = h !& hash($getLastModificationTime(rtLib))
  $(!$h)

proc main() =
  let argv = commandLineParams()
  if argv.len >= 1 and argv[0] in ["version", "--version"]:
    echo BuildSha
    quit(0)
  if argv.len < 2: usage()
  let cmd = argv[0]
  let file = argv[1]
  if not fileExists(file):
    stderr.writeLine("clonim: no such file: " & file)
    quit(1)

  var outBin = ""
  var verbose = false
  var release = cmd == "build"
  when defined(releaseCompiler):
    # The distributed compiler ships one release-mode runtime archive. Nim's
    # debug and release modes are not ABI-compatible, so `run` uses it too.
    release = true
  var sourceRoots: seq[string] = @[]
  var i = 2
  while i < argv.len:
    case argv[i]
    of "-o":
      inc i
      if i >= argv.len: usage()
      outBin = argv[i]
    of "--source-path":
      inc i
      if i >= argv.len: usage()
      sourceRoots.add argv[i].absolutePath
    of "-v": verbose = true
    of "-d": release = true
    else: usage()
    inc i

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

  let stem = file.splitFile.name
  # Nim module names must be identifiers, but .clj filenames are usually
  # hyphenated; the binary keeps the original stem, the module doesn't.
  var modName = ""
  for ch in stem:
    modName.add (if ch in {'a'..'z', 'A'..'Z', '0'..'9'}: ch else: '_')
  if modName.len == 0 or modName[0] in {'0'..'9'}: modName = "m" & modName
  let pathKey = toHex(hash(file.absolutePath).uint32, 8)
  # The nimcache is persistent and keyed by the source file's absolute path, so
  # repeated `clonim run` on the same file reuses the compiled runtime/core and
  # the Nim stdlib instead of rebuilding them from scratch every time. The .nim
  # file lives in the same directory so its path stays stable across runs too —
  # Nim keys its cache entries on module paths.
  let work = getTempDir() / "clonim" /
             (modName & "-" & pathKey & (if release: "-r" else: ""))
  createDir(work)
  # The release compiler shares one nimcache between all programs, so the
  # runtime's objects are compiled once rather than per program (see
  # app_runtime_source.nim). The program's own module lands there too, so its
  # name carries the path key to keep same-named files apart. Nim records its
  # C compiler command, including -I<program dir>, in every C file it writes,
  # so all programs also share one directory or no C file would ever match.
  var nimcache = work / "cache"
  var nimFile = work / (modName & ".nim")
  when defined(releaseCompiler):
    nimcache = srcDir().parentDir / "nimcache"
    createDir(srcDir().parentDir / "programs")
    nimFile = srcDir().parentDir / "programs" / (modName & "_" & pathKey & ".nim")
  writeFile(nimFile, nimSrc)

  if outBin.len == 0:
    outBin = (if cmd == "build": stem else: work / modName)
  outBin = outBin.absolutePath

  # Even a warm nimcache costs a second or so of semantic checking and linking.
  # `run` skips the backend entirely when nothing that feeds the binary has
  # changed: the generated Nim, private runtime archive/interface, build flags,
  # and the Nim compiler itself.
  let stamp = work / "stamp"
  var rtLib = ""
  when not defined(releaseCompiler):
    try:
      rtLib = runtimeLib(release)
    except IOError, OSError:
      stderr.writeLine("clonim: " & getCurrentExceptionMsg())
      quit(1)
  let cached = cmd == "run" and fileExists(outBin) and fileExists(stamp) and
               readFile(stamp) == buildKey(nimSrc, release, rtLib)

  var nimCmd = @["nim", "c", "--hints:off", "--warnings:off",
                 "--path:" & srcDir(), "--nimcache:" & nimcache,
                 "-o:" & outBin]
  when not defined(releaseCompiler):
    nimCmd.add "--passL:-Wl,--allow-multiple-definition"
    nimCmd.add "--passL:" & rtLib
  nimCmd.add "--passL:-lm"
  # Per-function sections let --gc-sections drop the runtime code a program
  # never reaches; the shared runtime objects carry all of it.
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
    when defined(releaseCompiler):
      try:
        code = withRuntimeCache(nimcache, proc (): int =
          (output, result) = execCmdEx(nimCmd.join(" ")))
      except IOError, OSError:
        stderr.writeLine("clonim: " & getCurrentExceptionMsg())
        quit(1)
    else:
      (output, code) = execCmdEx(nimCmd.join(" "))
    if code == 0: writeFile(stamp, buildKey(nimSrc, release, rtLib))
  let tBuild = epochTime() - t1
  if code != 0:
    stderr.writeLine("clonim: Nim backend failed\n" & output)
    stderr.writeLine("--- generated source ---\n" & nimSrc)
    quit(1)
  if verbose:
    echo "clonim: analyze ", (tCompile * 1000).formatFloat(ffDecimal, 1), "ms  ",
         "nim ", (tBuild * 1000).formatFloat(ffDecimal, 1), "ms",
         (if cached: " (cached)" else: "")

  case cmd
  of "build":
    echo "clonim: wrote " & outBin
  of "run":
    quit(execShellCmd(quoteShell(outBin)))
  else: usage()

main()
