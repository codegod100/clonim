## clonim reader — text -> data (forms are ordinary runtime Values, as in Clojure).
import std/[strutils, sequtils]
import runtime

type
  Reader = object
    src: string
    pos: int
    line: int
    anonId: int

proc peek(r: Reader): char =
  (if r.pos < r.src.len: r.src[r.pos] else: '\0')

proc peek2(r: Reader): char =
  (if r.pos + 1 < r.src.len: r.src[r.pos + 1] else: '\0')

proc advance(r: var Reader): char =
  result = r.src[r.pos]
  if result == '\n': inc r.line
  inc r.pos

proc readerErr(r: Reader, msg: string) {.noreturn.} =
  err("Reader error (line " & $r.line & "): " & msg)

const macroChars = {'(', ')', '[', ']', '{', '}', '"', ';', '\'', '`', '~', '@', '^'}

proc skipWs(r: var Reader) =
  while r.pos < r.src.len:
    let c = r.peek
    if c in {' ', '\t', '\n', '\r', ','}:
      discard r.advance
    elif c == ';':
      while r.pos < r.src.len and r.peek != '\n': discard r.advance
    else:
      break

proc readForm(r: var Reader): Value

proc replaceAnonArg(v: Value, arg: string): Value =
  if v.kind == kSymbol and v.s == "%": return mkSymbol(arg)
  case v.kind
  of kList: mkList(v.items.mapIt(replaceAnonArg(it, arg)))
  of kVector: mkVector(v.items.mapIt(replaceAnonArg(it, arg)))
  of kSet: mkSet(v.items.mapIt(replaceAnonArg(it, arg)))
  of kMap:
    var pairs: seq[(Value, Value)]
    for (k, val) in v.pairs: pairs.add (replaceAnonArg(k, arg), replaceAnonArg(val, arg))
    mkMap(pairs)
  else: v

proc readDelimited(r: var Reader, closing: char): seq[Value] =
  result = @[]
  while true:
    r.skipWs
    if r.pos >= r.src.len: r.readerErr("EOF while reading, expected '" & closing & "'")
    if r.peek == closing:
      discard r.advance
      return
    result.add r.readForm

proc readString(r: var Reader): Value =
  discard r.advance # opening quote
  var s = ""
  while true:
    if r.pos >= r.src.len: r.readerErr("EOF while reading string")
    let c = r.advance
    if c == '"': break
    if c == '\\':
      let e = r.advance
      case e
      of 'n': s.add '\n'
      of 't': s.add '\t'
      of 'r': s.add '\r'
      of '\\': s.add '\\'
      of '"': s.add '"'
      of '0': s.add '\0'
      else: r.readerErr("Unsupported escape: \\" & e)
    else:
      s.add c
  mkStr(s)

proc readToken(r: var Reader): string =
  result = ""
  while r.pos < r.src.len:
    let c = r.peek
    if c in {' ', '\t', '\n', '\r', ','} or (c in macroChars and c != '\''):
      break
    result.add r.advance

proc parseAtom(r: Reader, tok: string): Value =
  if tok == "nil": return NilV
  if tok == "true": return TrueV
  if tok == "false": return FalseV
  if tok.len > 1 and tok[0] == ':': return mkKeyword(tok[1 .. ^1])
  # Clojure accepts hexadecimal integer literals, commonly used for bit masks
  # and crypto constants.
  let sign = (if tok.len > 0 and tok[0] == '-': -1'i64 else: 1'i64)
  let digits = (if tok.len > 0 and tok[0] in {'-', '+'}: tok[1 .. ^1] else: tok)
  if digits.len > 2 and digits[0 .. 1].toLowerAscii == "0x":
    try: return mkInt(sign * int64(parseHexInt(digits[2 .. ^1])))
    except ValueError: discard
  # number?
  let body = (if tok[0] in {'-', '+'} and tok.len > 1: tok[1 .. ^1] else: tok)
  if body.len > 0 and body[0] in Digits:
    if '.' in tok or 'e' in tok or 'E' in tok:
      try: return mkFloat(parseFloat(tok))
      except ValueError: discard
    else:
      try: return mkInt(parseBiggestInt(tok))
      except ValueError: discard
  mkSymbol(tok)

proc readForm(r: var Reader): Value =
  r.skipWs
  if r.pos >= r.src.len: r.readerErr("EOF while reading")
  let c = r.peek
  case c
  of '(':
    discard r.advance
    return mkList(r.readDelimited(')'))
  of '[':
    discard r.advance
    return mkVector(r.readDelimited(']'))
  of '{':
    discard r.advance
    let xs = r.readDelimited('}')
    if xs.len mod 2 != 0: r.readerErr("Map literal must contain an even number of forms")
    var ps: seq[(Value, Value)] = @[]
    var i = 0
    while i < xs.len:
      ps.add (xs[i], xs[i + 1]); i += 2
    return mkMap(ps)
  of ')', ']', '}':
    r.readerErr("Unmatched delimiter: " & c)
  of '"':
    return r.readString
  of '\'':
    discard r.advance
    return mkList(@[mkSymbol("quote"), r.readForm])
  of '@':
    discard r.advance
    return mkList(@[mkSymbol("deref"), r.readForm])
  of '^':
    # metadata: read it and discard
    discard r.advance
    discard r.readForm
    return r.readForm
  of '#':
    if r.peek2 == '{':
      discard r.advance; discard r.advance
      return mkSet(r.readDelimited('}'))
    if r.peek2 == '"':
      # A Clojure regex literal carries its pattern source at read time.  The
      # runtime's regular-expression operations accept that source string, so
      # preserve the usual string escaping while avoiding a JVM-only Pattern
      # object in the portable value representation.
      discard r.advance
      return r.readString
    if r.peek2 == '_':
      discard r.advance; discard r.advance
      discard r.readForm
      r.skipWs
      return r.readForm
    if r.peek2 == '(':
      discard r.advance; discard r.advance
      inc r.anonId
      let arg = "anon_arg_" & $r.anonId
      let body = r.readDelimited(')')
      return mkList(@[mkSymbol("fn"), mkVector(@[mkSymbol(arg)])] &
                    body.mapIt(replaceAnonArg(it, arg)))
    r.readerErr("Unsupported dispatch: #" & r.peek2
      )
  else:
    let tok = r.readToken
    if tok.len == 0: r.readerErr("Unexpected character: " & c)
    return r.parseAtom(tok)

proc readAll*(src: string): seq[Value] =
  var r = Reader(src: src, pos: 0, line: 1)
  result = @[]
  while true:
    r.skipWs
    if r.pos >= r.src.len: break
    result.add r.readForm
