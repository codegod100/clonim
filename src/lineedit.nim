## A small line editor for the REPL, in the spirit of linenoise.
##
## The linenoise bundled with Nim switches the terminal in and out of raw mode
## with TCSAFLUSH, which throws away any input not read yet: paste several
## lines and everything after the first is lost. This editor never flushes,
## and it turns on bracketed paste, so a pasted block arrives whole. Its lines
## are handed out one at a time (see `pending`), echoed as if typed.
import std/[os, posix, strutils, terminal, termios]
import std/unicode except strip, split

type
  EditStatus* = enum esLine, esCtrlC, esCtrlD
  LineEditor* = object
    history*: seq[string]
    maxHistory*: int
    pending: seq[string]   # complete lines of a paste not handed out yet
    carry: string          # a paste's unterminated last line: starts the next edit

const
  PasteStart = "\e[200~"
  PasteEnd = "\e[201~"

proc initLineEditor*(maxHistory = 1000): LineEditor =
  LineEditor(maxHistory: maxHistory)

proc hasPending*(ed: LineEditor): bool =
  ## Whether lines of a paste are still waiting to be read.
  ed.pending.len > 0

proc discardPending*(ed: var LineEditor) =
  ## Drops the rest of a paste, e.g. after it failed to read.
  ed.pending.setLen 0
  ed.carry = ""

proc addHistory*(ed: var LineEditor, line: string) =
  if line.strip.len == 0: return
  if ed.history.len > 0 and ed.history[^1] == line: return
  ed.history.add line
  if ed.maxHistory > 0 and ed.history.len > ed.maxHistory:
    ed.history.delete(0)

proc loadHistory*(ed: var LineEditor, path: string) =
  ## One entry per line, the format linenoise uses.
  try:
    for line in lines(path): ed.addHistory(line)
  except IOError, OSError: discard

proc saveHistory*(ed: LineEditor, path: string) =
  try:
    writeFile(path, (if ed.history.len == 0: "" else: ed.history.join("\n") & "\n"))
  except IOError, OSError: discard

proc splitPaste*(text: string): seq[string] =
  ## A pasted block split into lines, whatever line endings it uses. There is
  ## always at least one part; the last is what follows the final newline.
  text.replace("\r\n", "\n").replace('\r', '\n').split('\n')

# --- terminal --------------------------------------------------------------

proc writeOut(s: string) =
  var off = 0
  while off < s.len:
    let n = posix.write(STDOUT_FILENO, unsafeAddr s[off], s.len - off)
    if n <= 0:
      if n < 0 and errno == EINTR: continue
      return
    off += n

proc readByte(c: var char): bool =
  while true:
    let n = posix.read(STDIN_FILENO, addr c, 1)
    if n == 1: return true
    if n < 0 and errno == EINTR: continue
    return false

proc enableRaw(orig: var Termios): bool =
  if tcGetAttr(STDIN_FILENO, addr orig) != 0: return false
  var raw = orig
  raw.c_iflag = raw.c_iflag and not Cflag(BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  raw.c_oflag = raw.c_oflag and not Cflag(OPOST)
  raw.c_cflag = raw.c_cflag or Cflag(CS8)
  raw.c_lflag = raw.c_lflag and not Cflag(ECHO or ICANON or IEXTEN or ISIG)
  raw.c_cc[VMIN] = 1.char
  raw.c_cc[VTIME] = 0.char
  # TCSANOW, not TCSAFLUSH: input typed or pasted ahead must survive.
  if tcSetAttr(STDIN_FILENO, TCSANOW, addr raw) != 0: return false
  writeOut("\e[?2004h")
  true

proc disableRaw(orig: var Termios) =
  writeOut("\e[?2004l")
  discard tcSetAttr(STDIN_FILENO, TCSANOW, addr orig)

proc unsupportedTerm(): bool =
  getEnv("TERM").toLowerAscii in ["dumb", "cons25", "emacs"]

# --- editing ---------------------------------------------------------------

type Edit = object
  prompt: string
  buf: seq[Rune]
  pos: int

proc refresh(e: Edit) =
  let plen = e.prompt.runeLen
  let cols = max(terminalWidth(), plen + 2)
  var start = 0
  while plen + e.pos - start >= cols: inc start
  var stop = e.buf.len
  while plen + stop - start > cols - 1 and stop > e.pos: dec stop
  var s = "\r" & e.prompt & $e.buf[start ..< stop] & "\e[0K\r"
  let col = plen + e.pos - start
  if col > 0: s.add "\e[" & $col & "C"
  writeOut(s)

proc insert(e: var Edit, s: string) =
  let r = s.toRunes
  e.buf = e.buf[0 ..< e.pos] & r & e.buf[e.pos .. ^1]
  e.pos += r.len

proc browse(e: var Edit, hist: var seq[string], hi: var int, to: int) =
  if to < 0 or to > hist.high: return
  hist[hi] = $e.buf
  hi = to
  e.buf = hist[hi].toRunes
  e.pos = e.buf.len

proc readPaste(): string =
  ## Everything up to the end-of-paste marker (or end of input).
  var c: char
  while readByte(c):
    result.add c
    if result.endsWith(PasteEnd):
      result.setLen(result.len - PasteEnd.len)
      return

proc readUtf8(first: char): string =
  result = $first
  let extra =
    if (first.uint8 and 0xE0) == 0xC0: 1
    elif (first.uint8 and 0xF0) == 0xE0: 2
    elif (first.uint8 and 0xF8) == 0xF0: 3
    else: 0
  var c: char
  for _ in 1 .. extra:
    if not readByte(c): break
    result.add c

proc edit(ed: var LineEditor, prompt: string, line: var string): EditStatus =
  var e = Edit(prompt: prompt, buf: ed.carry.toRunes)
  e.pos = e.buf.len
  ed.carry = ""
  # History browsing works on a copy whose last slot is the line being edited.
  var hist = ed.history & @[""]
  var hi = hist.high
  e.refresh
  var c: char
  while true:
    if not readByte(c):
      line = $e.buf
      return (if e.buf.len == 0: esCtrlD else: esLine)
    case c
    of '\r', '\n':
      line = $e.buf
      return esLine
    of '\x03':
      writeOut("^C")
      return esCtrlC
    of '\x04':
      if e.buf.len == 0: return esCtrlD
      if e.pos < e.buf.len: e.buf.delete(e.pos)
    of '\x7f', '\x08':
      if e.pos > 0:
        dec e.pos
        e.buf.delete(e.pos)
    of '\x01': e.pos = 0
    of '\x05': e.pos = e.buf.len
    of '\x02': e.pos = max(e.pos - 1, 0)
    of '\x06': e.pos = min(e.pos + 1, e.buf.len)
    of '\x0b': e.buf.setLen e.pos
    of '\x15':
      e.buf = e.buf[e.pos .. ^1]
      e.pos = 0
    of '\x17':
      var p = e.pos
      while p > 0 and e.buf[p - 1] == Rune(' '): dec p
      while p > 0 and e.buf[p - 1] != Rune(' '): dec p
      e.buf = e.buf[0 ..< p] & e.buf[e.pos .. ^1]
      e.pos = p
    of '\x0c': writeOut("\e[H\e[2J")
    of '\x10': browse(e, hist, hi, hi - 1)
    of '\x0e': browse(e, hist, hi, hi + 1)
    of '\t': e.insert("  ")
    of '\e':
      var csi = ""
      var d: char
      if not readByte(d): continue
      if d == '[':
        # CSI: parameter bytes, then one final byte.
        while readByte(d):
          csi.add d
          if d.uint8 in 0x40'u8 .. 0x7E'u8: break
        case csi
        of "A": browse(e, hist, hi, hi - 1)
        of "B": browse(e, hist, hi, hi + 1)
        of "C": e.pos = min(e.pos + 1, e.buf.len)
        of "D": e.pos = max(e.pos - 1, 0)
        of "H", "1~", "7~": e.pos = 0
        of "F", "4~", "8~": e.pos = e.buf.len
        of "3~":
          if e.pos < e.buf.len: e.buf.delete(e.pos)
        of "200~":
          let parts = splitPaste(readPaste())
          if parts.len == 1:
            e.insert(parts[0])
          else:
            # The first pasted line finishes this one; the rest wait their
            # turn, and whatever followed the cursor trails the paste.
            let tail = $e.buf[e.pos .. ^1]
            e.buf.setLen e.pos
            e.pos = e.buf.len
            e.insert(parts[0])
            ed.pending = parts[1 .. ^2]
            ed.carry = parts[^1] & tail
            e.refresh
            line = $e.buf
            return esLine
        else: discard
      elif d == 'O':
        if readByte(d):
          case d
          of 'H': e.pos = 0
          of 'F': e.pos = e.buf.len
          else: discard
    else:
      if c.uint8 >= 0x20:
        e.insert(readUtf8(c))
    e.refresh

proc readLine*(ed: var LineEditor, prompt: string, line: var string): EditStatus =
  ## One line of input, read from the terminal with editing and history.
  ## Lines left over from a paste come first, echoed after the prompt.
  if ed.pending.len > 0:
    line = ed.pending[0]
    ed.pending.delete(0)
    writeOut(prompt & line & "\n")
    return esLine
  if unsupportedTerm():
    writeOut(prompt)
    return (if stdin.readLine(line): esLine else: esCtrlD)
  var orig: Termios
  if not enableRaw(orig):
    writeOut(prompt)
    return (if stdin.readLine(line): esLine else: esCtrlD)
  try:
    result = ed.edit(prompt, line)
  finally:
    disableRaw(orig)
    writeOut("\n")
