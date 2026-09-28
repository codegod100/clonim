## The process behind `clonim repl`. It holds the runtime and every var that
## REPL inputs define. Each input arrives as a shared library built from
## compileReplForms, which the host loads and runs exactly once, so earlier
## inputs never run again.
##
##   clonim-repl-host <command-fd> <reply-fd>
##
## Commands are lines on command-fd: `eval <path>` runs a library, `quiet
## <path>` runs it with stdout and stderr discarded (the driver uses this to
## rebuild state in a new host after the old one died). Each command gets one
## reply line on reply-fd: 0 when the input ran, 1 when it raised (the error
## is already printed), 2 when the library could not be loaded. The host exits
## when command-fd closes.
##
## Built with src/repl/nimbase.h first on the include path and linked with
## -rdynamic; see that header for why.
import std/[cmdline, dynlib, posix, strutils]
import runtime_lib, runtime, core, namespaces

type EvalProc = proc (): cint {.cdecl, gcsafe.}

proc run(path: string): int =
  let lib = loadLib(path)
  if lib == nil:
    stderr.writeLine("clonim: cannot load " & path & ": " & $dlerror())
    return 2
  let eval = cast[EvalProc](lib.symAddr("clonim_repl_eval"))
  if eval == nil:
    stderr.writeLine("clonim: " & path & " has no clonim_repl_eval")
    return 2
  # The library stays loaded: the fns it defined live in its code.
  eval().int

proc runQuiet(path: string): int =
  stdout.flushFile
  stderr.flushFile
  let null = posix.open("/dev/null", O_WRONLY)
  let savedOut = dup(1)
  let savedErr = dup(2)
  discard dup2(null, 1)
  discard dup2(null, 2)
  try:
    result = run(path)
  finally:
    stdout.flushFile
    stderr.flushFile
    discard dup2(savedOut, 1)
    discard dup2(savedErr, 2)
    discard close(savedOut)
    discard close(savedErr)
    discard close(null)

proc main() =
  # Inputs see an empty stdin, as a `clonim run` program started without
  # input would, rather than competing with the driver for the terminal.
  let null = posix.open("/dev/null", O_RDONLY)
  discard dup2(null, 0)
  discard close(null)

  var commands, replies: File
  if paramCount() != 2 or
     not open(commands, FileHandle(paramStr(1).parseInt), fmRead) or
     not open(replies, FileHandle(paramStr(2).parseInt), fmWrite):
    quit("usage: clonim-repl-host <command-fd> <reply-fd>")

  registerCore()
  registerNamespaceCore()
  setVar("clojure.core/*command-line-args*", NilV)

  var line: string
  while commands.readLine(line):
    let space = line.find(' ')
    let (verb, path) = (line[0 ..< max(space, 0)], line[space + 1 .. ^1])
    let status =
      case verb
      of "eval": run(path)
      of "quiet": runQuiet(path)
      else: 2
    stdout.flushFile
    stderr.flushFile
    replies.writeLine($status)
    replies.flushFile

main()
