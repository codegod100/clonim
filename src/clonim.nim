## clonim — a Clojure compiler hosted on Nim.
##
##   clonim run   foo.clj          compile and run
##   clonim build foo.clj [-o bin] compile to a native binary
##   clonim emit  foo.clj          print the generated Nim
import std/[os, osproc, strutils, times]
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
  let work = getTempDir() / ("clonim-" & stem & "-" & $getCurrentProcessId())
  createDir(work)
  defer: removeDir(work)
  let nimFile = work / (stem & ".nim")
  writeFile(nimFile, nimSrc)

  if outBin.len == 0:
    outBin = (if cmd == "build": stem else: work / stem)
  outBin = outBin.absolutePath

  var nimCmd = @["nim", "c", "--hints:off", "--warnings:off",
                 "--path:" & srcDir(), "--nimcache:" & (work / "cache"),
                 "-o:" & outBin]
  if release: nimCmd.add "-d:release"
  nimCmd.add nimFile
  if verbose: echo "clonim: " & nimCmd.join(" ")

  let t1 = epochTime()
  let (output, code) = execCmdEx(nimCmd.join(" "))
  let tBuild = epochTime() - t1
  if code != 0:
    stderr.writeLine("clonim: Nim backend failed\n" & output)
    stderr.writeLine("--- generated source ---\n" & nimSrc)
    quit(1)
  if verbose:
    echo "clonim: analyze ", (tCompile * 1000).formatFloat(ffDecimal, 1), "ms  ",
         "nim ", (tBuild * 1000).formatFloat(ffDecimal, 1), "ms"

  case cmd
  of "build":
    echo "clonim: wrote " & outBin
  of "run":
    quit(execShellCmd(quoteShell(outBin)))
  else: usage()

main()
