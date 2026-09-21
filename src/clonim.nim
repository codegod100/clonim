## clonim — a Clojure compiler hosted on Nim.
##
##   clonim run   foo.clj          compile and run
##   clonim build foo.clj [-o bin] compile to a native binary
##   clonim emit  foo.clj          print the generated Nim
import std/[hashes, os, osproc, strutils, times]
import runtime, compiler

proc usage() =
  echo """clonim — a Clojure compiler hosted on Nim

usage:
  clonim run   <file.clj>              compile to Nim, build, and run
  clonim build <file.clj> [-o <bin>]   build a native binary
  clonim emit  <file.clj>              print the generated Nim source

options:
  -o <path>   output binary path (build)
  -v          show the nim build command and timings
  -d          build with -d:release (default for build, off for run)"""
  quit(1)

proc srcDir(): string =
  ## where runtime.nim / core.nim live, so generated code can import them
  for cand in [getAppDir(), getAppDir().parentDir / "src",
               getAppDir().parentDir.parentDir / "src"]:
    if fileExists(cand / "runtime.nim"): return cand
  getAppDir()

proc buildKey(nimSrc: string, release: bool): string =
  ## Identifies everything the produced binary depends on. Any change here
  ## invalidates the cached binary for a source file.
  var h: Hash = hash(nimSrc) !& hash(release)
  for f in walkFiles(srcDir() / "*.nim"):
    h = h !& hash(readFile(f))
  let nimExe = findExe("nim")
  if nimExe.len > 0:
    h = h !& hash($getLastModificationTime(nimExe))
  $(!$h)

proc main() =
  let argv = commandLineParams()
  if argv.len < 2: usage()
  let cmd = argv[0]
  let file = argv[1]
  if not fileExists(file):
    stderr.writeLine("clonim: no such file: " & file)
    quit(1)

  var outBin = ""
  var verbose = false
  var release = cmd == "build"
  var i = 2
  while i < argv.len:
    case argv[i]
    of "-o":
      inc i
      if i >= argv.len: usage()
      outBin = argv[i]
    of "-v": verbose = true
    of "-d": release = true
    else: usage()
    inc i

  let t0 = epochTime()
  var nimSrc = ""
  try:
    nimSrc = compileSource(readFile(file))
  except CljError as e:
    stderr.writeLine("clonim: " & e.msg)
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
  # The nimcache is persistent and keyed by the source file's absolute path, so
  # repeated `clonim run` on the same file reuses the compiled runtime/core and
  # the Nim stdlib instead of rebuilding them from scratch every time. The .nim
  # file lives in the same directory so its path stays stable across runs too —
  # Nim keys its cache entries on module paths.
  let work = getTempDir() / "clonim" /
             (modName & "-" & toHex(hash(file.absolutePath).uint32, 8) &
              (if release: "-r" else: ""))
  createDir(work)
  let nimFile = work / (modName & ".nim")
  writeFile(nimFile, nimSrc)

  if outBin.len == 0:
    outBin = (if cmd == "build": stem else: work / modName)
  outBin = outBin.absolutePath

  # Even a warm nimcache costs a second or so of semantic checking and linking.
  # `run` skips the backend entirely when nothing that feeds the binary has
  # changed: the generated Nim, the runtime/core sources it imports, the build
  # flags, and the Nim compiler itself.
  let stamp = work / "stamp"
  let cached = cmd == "run" and fileExists(outBin) and fileExists(stamp) and
               readFile(stamp) == buildKey(nimSrc, release)

  var nimCmd = @["nim", "c", "--hints:off", "--warnings:off",
                 "--path:" & srcDir(), "--nimcache:" & (work / "cache"),
                 "-o:" & outBin]
  if release: nimCmd.add "-d:release"
  nimCmd.add nimFile
  if verbose and not cached: echo "clonim: " & nimCmd.join(" ")

  let t1 = epochTime()
  var output = ""
  var code = 0
  if not cached:
    (output, code) = execCmdEx(nimCmd.join(" "))
    if code == 0: writeFile(stamp, buildKey(nimSrc, release))
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
