## PostgreSQL through libpq, loaded on first use.
##
## Like SQLite (src/sqlite.nim), libpq is opened with dlopen the first time
## a program connects, so programs that don't use Postgres neither link
## against it nor need it installed.
##
## A connection handle is a clonim fn driven by keyword messages:
## (pg :execute sql params), (pg :query sql params), (pg :transaction f),
## (pg :listen channel), (pg :notifications timeout-ms) and (pg :close).
## stdlib/clonim/postgres.clj wraps them. Parameters travel in text format
## and results come back typed by their column's type.
import std/[dynlib, os, strutils]
import runtime
when defined(posix): import std/posix

type
  PostgresError* = object of CatchableError
    sqlstate*: string   ## e.g. "23505" for a unique violation; "" if none
    sql*: string

  PGconn = pointer
  PGresult = pointer
  PGnotify {.pure, final.} = object
    relname: cstring
    be_pid: cint
    extra: cstring

const
  CONNECTION_OK = 0
  PGRES_EMPTY_QUERY = 0
  PGRES_COMMAND_OK = 1
  PGRES_TUPLES_OK = 2
  PG_DIAG_SQLSTATE = cint(ord('C'))
  # type oids from pg_type.h
  BOOLOID = 16
  BYTEAOID = 17
  INT8OID = 20
  INT2OID = 21
  INT4OID = 23
  OIDOID = 26
  FLOAT4OID = 700
  FLOAT8OID = 701
  NUMERICOID = 1700

type
  NoticeProcessor = proc (arg: pointer, message: cstring) {.cdecl.}
  Api = object
    connectdb: proc (conninfo: cstring): PGconn {.cdecl, gcsafe.}
    status: proc (c: PGconn): cint {.cdecl, gcsafe.}
    errorMessage: proc (c: PGconn): cstring {.cdecl, gcsafe.}
    finish: proc (c: PGconn) {.cdecl, gcsafe.}
    reset: proc (c: PGconn) {.cdecl, gcsafe.}
    setNoticeProcessor: proc (c: PGconn, p: NoticeProcessor,
                              arg: pointer): NoticeProcessor {.cdecl, gcsafe.}
    exec: proc (c: PGconn, q: cstring): PGresult {.cdecl, gcsafe.}
    execParams: proc (c: PGconn, q: cstring, n: cint, types: pointer,
                      values: ptr cstring, lengths: pointer, formats: pointer,
                      resultFormat: cint): PGresult {.cdecl, gcsafe.}
    resultStatus: proc (r: PGresult): cint {.cdecl, gcsafe.}
    resultErrorMessage: proc (r: PGresult): cstring {.cdecl, gcsafe.}
    resultErrorField: proc (r: PGresult, field: cint): cstring {.cdecl, gcsafe.}
    clear: proc (r: PGresult) {.cdecl, gcsafe.}
    ntuples: proc (r: PGresult): cint {.cdecl, gcsafe.}
    nfields: proc (r: PGresult): cint {.cdecl, gcsafe.}
    fname: proc (r: PGresult, i: cint): cstring {.cdecl, gcsafe.}
    ftype: proc (r: PGresult, i: cint): cuint {.cdecl, gcsafe.}
    getvalue: proc (r: PGresult, row, col: cint): cstring {.cdecl, gcsafe.}
    getlength: proc (r: PGresult, row, col: cint): cint {.cdecl, gcsafe.}
    getisnull: proc (r: PGresult, row, col: cint): cint {.cdecl, gcsafe.}
    cmdTuples: proc (r: PGresult): cstring {.cdecl, gcsafe.}
    socket: proc (c: PGconn): cint {.cdecl, gcsafe.}
    consumeInput: proc (c: PGconn): cint {.cdecl, gcsafe.}
    notifies: proc (c: PGconn): ptr PGnotify {.cdecl, gcsafe.}
    freemem: proc (p: pointer) {.cdecl, gcsafe.}
    escapeIdentifier: proc (c: PGconn, s: cstring, n: csize_t): cstring {.cdecl, gcsafe.}

var api: Api
var loaded = false

proc loadApi() =
  ## Opens libpq once. CLONIM_LIBPQ names a specific file; otherwise the
  ## platform's usual names are tried.
  if loaded: return
  let override = getEnv("CLONIM_LIBPQ")
  let lib =
    if override.len > 0: loadLib(override)
    else:
      when defined(windows): loadLibPattern("libpq.dll")
      elif defined(macosx): loadLibPattern("libpq(|.5).dylib")
      else: loadLibPattern("libpq.so(.5|)")
  if lib.isNil:
    err("PostgreSQL is not available: could not load " &
        (if override.len > 0: override else: "libpq") &
        " (install libpq or set CLONIM_LIBPQ)")
  template sym(field: untyped, name: string) =
    let p = lib.symAddr(name)
    if p.isNil: err("libpq is missing " & name)
    api.field = cast[typeof(api.field)](p)
  sym(connectdb, "PQconnectdb")
  sym(status, "PQstatus")
  sym(errorMessage, "PQerrorMessage")
  sym(finish, "PQfinish")
  sym(reset, "PQreset")
  sym(setNoticeProcessor, "PQsetNoticeProcessor")
  sym(exec, "PQexec")
  sym(execParams, "PQexecParams")
  sym(resultStatus, "PQresultStatus")
  sym(resultErrorMessage, "PQresultErrorMessage")
  sym(resultErrorField, "PQresultErrorField")
  sym(clear, "PQclear")
  sym(ntuples, "PQntuples")
  sym(nfields, "PQnfields")
  sym(fname, "PQfname")
  sym(ftype, "PQftype")
  sym(getvalue, "PQgetvalue")
  sym(getlength, "PQgetlength")
  sym(getisnull, "PQgetisnull")
  sym(cmdTuples, "PQcmdTuples")
  sym(socket, "PQsocket")
  sym(consumeInput, "PQconsumeInput")
  sym(notifies, "PQnotifies")
  sym(freemem, "PQfreemem")
  sym(escapeIdentifier, "PQescapeIdentifier")
  loaded = true

proc quietNotices(arg: pointer, message: cstring) {.cdecl.} =
  ## Server NOTICEs ("relation already exists, skipping") are not errors
  ## and have no business on a program's stderr.
  discard

type Pg* = ref object
  c: PGconn
  inTx: bool

proc pgError(msg, sqlstate, sql: string): ref PostgresError =
  result = newException(PostgresError, msg.strip)
  result.sqlstate = sqlstate
  result.sql = sql

proc connectPg*(conninfo: string): Pg =
  ## conninfo is a libpq connection string or URI, such as
  ## postgresql://user:pass@host:5432/db?sslmode=require.
  loadApi()
  let c = api.connectdb(conninfo.cstring)
  if c.isNil: raise pgError("Out of memory connecting to PostgreSQL", "", "")
  if api.status(c) != CONNECTION_OK:
    let msg = $api.errorMessage(c)
    api.finish(c)
    raise pgError("Cannot connect to PostgreSQL: " & msg, "08001", "")
  discard api.setNoticeProcessor(c, quietNotices, nil)
  Pg(c: c)

proc closePg*(pg: Pg) =
  if not pg.c.isNil:
    api.finish(pg.c)
    pg.c = nil

proc live(pg: Pg) =
  if pg.c.isNil: err("PostgreSQL connection is closed")

proc paramText(v: Value): (bool, string) =
  ## (null?, text) of a parameter in PostgreSQL's text format.
  case v.kind
  of kNil: (true, "")
  of kBool: (false, (if v.b: "true" else: "false"))
  of kInt: (false, $v.i)
  of kFloat: (false, $v.f)
  of kStr: (false, v.s)
  of kList, kVector:
    # A byte-array (or any sequence of integers) is bytea, in hex.
    var s = "\\x"
    for x in elems(v):
      if x.kind != kInt: err("PostgreSQL bytea parameter must hold integers, got " & prStr(x))
      s.add toHex(int(x.i and 0xff), 2).toLowerAscii
    (false, s)
  else: err("Unsupported PostgreSQL parameter: " & prStr(v))

proc run(pg: Pg, sql: string, params: seq[Value]): PGresult =
  ## Runs sql and returns its result, raising on failure. Without
  ## parameters sql may hold several statements.
  pg.live()
  var res: PGresult
  if params.len == 0:
    res = api.exec(pg.c, sql.cstring)
  else:
    var texts = newSeq[string](params.len)
    var ptrs = newSeq[cstring](params.len)
    for i, p in params:
      let (isNull, t) = paramText(p)
      texts[i] = t
      ptrs[i] = (if isNull: nil else: texts[i].cstring)
    res = api.execParams(pg.c, sql.cstring, cint(params.len), nil,
                         ptrs[0].addr, nil, nil, 0)
  if res.isNil:
    raise pgError($api.errorMessage(pg.c), "08006", sql)
  let st = api.resultStatus(res)
  if st notin [PGRES_COMMAND_OK, PGRES_TUPLES_OK, PGRES_EMPTY_QUERY]:
    let msg = $api.resultErrorMessage(res)
    let state = api.resultErrorField(res, PG_DIAG_SQLSTATE)
    let sqlstate = (if state.isNil: "" else: $state)
    api.clear(res)
    raise pgError(msg, sqlstate, sql)
  res

proc unhex(s: string): Value =
  ## A bytea value in hex output format (\x0a1b...) as unsigned bytes.
  var xs: seq[Value] = @[]
  var i = 2
  while i + 1 < s.len:
    xs.add mkInt(int64(parseHexInt(s[i .. i + 1])))
    i += 2
  mkList(xs)

proc cell(r: PGresult, row, col: cint): Value =
  if api.getisnull(r, row, col) != 0: return NilV
  let p = api.getvalue(r, row, col)
  let n = int(api.getlength(r, row, col))
  var s = newString(n)
  if n > 0: copyMem(s[0].addr, p, n)
  case int(api.ftype(r, col))
  of INT2OID, INT4OID, INT8OID, OIDOID: mkInt(parseBiggestInt(s))
  of FLOAT4OID, FLOAT8OID: mkFloat(parseFloat(s))
  of NUMERICOID:
    if '.' in s or 'e' in s or 'N' in s: mkFloat(parseFloat(s))
    else: mkInt(parseBiggestInt(s))
  of BOOLOID: mkBool(s == "t")
  of BYTEAOID: unhex(s)
  else: mkStr(s)

proc execute*(pg: Pg, sql: string, params: seq[Value]): Value =
  ## Runs a statement (or, without parameters, a script of them) and reports
  ## {:changes n}, the rows the last one affected.
  let r = pg.run(sql, params)
  let t = $api.cmdTuples(r)
  api.clear(r)
  mkMap(@[(mkKeyword("changes"), mkInt(if t.len == 0: 0 else: parseBiggestInt(t)))])

proc query*(pg: Pg, sql: string, params: seq[Value]): Value =
  ## The rows of a query as a vector of maps keyed by column-name keywords.
  let r = pg.run(sql, params)
  try:
    let cols = int(api.nfields(r))
    var names = newSeq[Value](cols)
    for i in 0 ..< cols: names[i] = mkKeyword($api.fname(r, cint(i)))
    var rows: seq[Value] = @[]
    for row in 0 ..< int(api.ntuples(r)):
      var ps = newSeqOfCap[(Value, Value)](cols)
      for i in 0 ..< cols: ps.add (names[i], cell(r, cint(row), cint(i)))
      rows.add mkMap(ps)
    mkVector(rows)
  finally:
    api.clear(r)

proc transaction*(pg: Pg, f: Value): Value =
  ## Calls f with no arguments between BEGIN and COMMIT. Anything f throws
  ## rolls the transaction back and is rethrown as it was.
  if pg.inTx: err("PostgreSQL transactions don't nest")
  api.clear(pg.run("BEGIN", @[]))
  pg.inTx = true
  try:
    result = call(f, [])
    api.clear(pg.run("COMMIT", @[]))
  except CatchableError:
    try: api.clear(pg.run("ROLLBACK", @[]))
    except CatchableError: discard
    raise
  finally:
    pg.inTx = false

proc listen*(pg: Pg, channel: string) =
  pg.live()
  let q = api.escapeIdentifier(pg.c, channel.cstring, csize_t(channel.len))
  if q.isNil: raise pgError($api.errorMessage(pg.c), "", "LISTEN")
  let sql = "LISTEN " & $q
  api.freemem(q)
  api.clear(pg.run(sql, @[]))

proc drain(pg: Pg, into: var seq[Value]) =
  while true:
    let n = api.notifies(pg.c)
    if n.isNil: break
    into.add mkMap(@[(mkKeyword("channel"), mkStr($n.relname)),
                     (mkKeyword("payload"), mkStr($n.extra)),
                     (mkKeyword("pid"), mkInt(int64(n.be_pid)))])
    api.freemem(n)

proc notifications*(pg: Pg, timeoutMs: int): Value =
  ## Notifications received on LISTENed channels, as maps of :channel
  ## :payload :pid. Waits up to timeoutMs (indefinitely if negative) for
  ## the first when none has arrived yet; [] on timeout.
  pg.live()
  var got: seq[Value] = @[]
  if api.consumeInput(pg.c) == 0:
    raise pgError($api.errorMessage(pg.c), "08006", "")
  pg.drain(got)
  if got.len == 0 and timeoutMs != 0:
    when defined(posix):
      var p = TPollfd(fd: api.socket(pg.c), events: POLLIN)
      while true:
        let n = posix.poll(addr p, 1, cint(timeoutMs))
        if n >= 0: break
        if errno != EINTR: err("poll: " & $strerror(errno))
      if api.consumeInput(pg.c) == 0:
        raise pgError($api.errorMessage(pg.c), "08006", "")
      pg.drain(got)
    else:
      sleep(max(timeoutMs, 0))
      discard api.consumeInput(pg.c)
      pg.drain(got)
  mkVector(got)

proc resetPg*(pg: Pg) =
  ## Reconnect with the same settings, as after the server dropped us.
  pg.live()
  api.reset(pg.c)
  if api.status(pg.c) != CONNECTION_OK:
    raise pgError("Cannot reconnect to PostgreSQL: " & $api.errorMessage(pg.c), "08001", "")
  pg.inTx = false
