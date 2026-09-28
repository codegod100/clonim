## SQLite, loaded on first use.
##
## The library is opened with dlopen the first time a program opens a
## database, the way Nim's -d:ssl loads OpenSSL. Programs that never touch
## SQLite neither link against it nor need it installed, and the runtime
## archive builds the same with gcc or the AppImage's Zig.
##
## A database handle is a clonim fn driven by keyword messages, like
## *output-stream*: (db :execute sql params), (db :query sql params),
## (db :transaction f) and (db :close). stdlib/clonim/sqlite.clj wraps them.
import std/[dynlib, os, strutils]
import runtime

type
  SqliteError* = object of CatchableError
    code*: int      ## SQLite's primary result code, e.g. 1 for SQLITE_ERROR
    sql*: string    ## the statement that failed, "" for open/close

  Sqlite3 = pointer
  Stmt = pointer

const
  SQLITE_OK = 0
  SQLITE_ROW = 100
  SQLITE_DONE = 101
  SQLITE_INTEGER = 1
  SQLITE_FLOAT = 2
  SQLITE_TEXT = 3
  SQLITE_BLOB = 4
  SQLITE_OPEN_READWRITE = 0x02
  SQLITE_OPEN_CREATE = 0x04
  DefaultBusyTimeoutMs = 5000

let SQLITE_TRANSIENT = cast[pointer](-1)

type
  Api = object
    open_v2: proc (path: cstring, db: ptr Sqlite3, flags: cint,
                   vfs: cstring): cint {.cdecl, gcsafe.}
    close_v2: proc (db: Sqlite3): cint {.cdecl, gcsafe.}
    errmsg: proc (db: Sqlite3): cstring {.cdecl, gcsafe.}
    errstr: proc (code: cint): cstring {.cdecl, gcsafe.}
    busy_timeout: proc (db: Sqlite3, ms: cint): cint {.cdecl, gcsafe.}
    prepare_v2: proc (db: Sqlite3, sql: cstring, nByte: cint, stmt: ptr Stmt,
                      tail: ptr cstring): cint {.cdecl, gcsafe.}
    finalize: proc (s: Stmt): cint {.cdecl, gcsafe.}
    step: proc (s: Stmt): cint {.cdecl, gcsafe.}
    bind_parameter_count: proc (s: Stmt): cint {.cdecl, gcsafe.}
    bind_null: proc (s: Stmt, i: cint): cint {.cdecl, gcsafe.}
    bind_int64: proc (s: Stmt, i: cint, v: int64): cint {.cdecl, gcsafe.}
    bind_double: proc (s: Stmt, i: cint, v: float64): cint {.cdecl, gcsafe.}
    bind_text: proc (s: Stmt, i: cint, v: cstring, n: cint,
                     destructor: pointer): cint {.cdecl, gcsafe.}
    bind_blob: proc (s: Stmt, i: cint, v: pointer, n: cint,
                     destructor: pointer): cint {.cdecl, gcsafe.}
    column_count: proc (s: Stmt): cint {.cdecl, gcsafe.}
    column_name: proc (s: Stmt, i: cint): cstring {.cdecl, gcsafe.}
    column_type: proc (s: Stmt, i: cint): cint {.cdecl, gcsafe.}
    column_int64: proc (s: Stmt, i: cint): int64 {.cdecl, gcsafe.}
    column_double: proc (s: Stmt, i: cint): float64 {.cdecl, gcsafe.}
    column_text: proc (s: Stmt, i: cint): pointer {.cdecl, gcsafe.}
    column_blob: proc (s: Stmt, i: cint): pointer {.cdecl, gcsafe.}
    column_bytes: proc (s: Stmt, i: cint): cint {.cdecl, gcsafe.}
    changes: proc (db: Sqlite3): cint {.cdecl, gcsafe.}
    last_insert_rowid: proc (db: Sqlite3): int64 {.cdecl, gcsafe.}

var api: Api
var loaded = false

proc loadApi() =
  ## Opens the SQLite shared library once. CLONIM_SQLITE_LIB names a specific
  ## file; otherwise the platform's usual names are tried.
  if loaded: return
  let override = getEnv("CLONIM_SQLITE_LIB")
  let lib =
    if override.len > 0: loadLib(override)
    else:
      when defined(windows): loadLibPattern("sqlite3.dll")
      elif defined(macosx): loadLibPattern("libsqlite3(|.0).dylib")
      else: loadLibPattern("libsqlite3.so(|.0)")
  if lib.isNil:
    err("SQLite is not available: could not load " &
        (if override.len > 0: override else: "libsqlite3") &
        " (install SQLite or set CLONIM_SQLITE_LIB)")
  template sym(field: untyped, name: string) =
    let p = lib.symAddr(name)
    if p.isNil: err("SQLite library is missing " & name)
    api.field = cast[typeof(api.field)](p)
  sym(open_v2, "sqlite3_open_v2")
  sym(close_v2, "sqlite3_close_v2")
  sym(errmsg, "sqlite3_errmsg")
  sym(errstr, "sqlite3_errstr")
  sym(busy_timeout, "sqlite3_busy_timeout")
  sym(prepare_v2, "sqlite3_prepare_v2")
  sym(finalize, "sqlite3_finalize")
  sym(step, "sqlite3_step")
  sym(bind_parameter_count, "sqlite3_bind_parameter_count")
  sym(bind_null, "sqlite3_bind_null")
  sym(bind_int64, "sqlite3_bind_int64")
  sym(bind_double, "sqlite3_bind_double")
  sym(bind_text, "sqlite3_bind_text")
  sym(bind_blob, "sqlite3_bind_blob")
  sym(column_count, "sqlite3_column_count")
  sym(column_name, "sqlite3_column_name")
  sym(column_type, "sqlite3_column_type")
  sym(column_int64, "sqlite3_column_int64")
  sym(column_double, "sqlite3_column_double")
  sym(column_text, "sqlite3_column_text")
  sym(column_blob, "sqlite3_column_blob")
  sym(column_bytes, "sqlite3_column_bytes")
  sym(changes, "sqlite3_changes")
  sym(last_insert_rowid, "sqlite3_last_insert_rowid")
  loaded = true

type Db* = ref object
  h: Sqlite3
  path*: string

proc sqliteError(msg: string, rc: cint, sql: string): ref SqliteError =
  result = newException(SqliteError, msg)
  result.code = int(rc and 0xff)
  result.sql = sql

proc fail(db: Db, rc: cint, sql: string) {.noreturn.} =
  raise sqliteError($api.errmsg(db.h), rc, sql)

proc check(db: Db, rc: cint, sql: string) =
  if rc != SQLITE_OK: fail(db, rc, sql)

proc openDb*(path: string): Db =
  loadApi()
  result = Db(path: path)
  let rc = api.open_v2(path.cstring, addr result.h,
                       SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil)
  if rc != SQLITE_OK:
    # SQLite may hand back a handle even on failure; it carries the message
    # and must still be closed.
    let msg = (if result.h.isNil: $api.errstr(rc) else: $api.errmsg(result.h))
    if not result.h.isNil: discard api.close_v2(result.h)
    raise sqliteError(msg & ": " & path, rc, "")
  # A second process writing the same file waits for its lock instead of
  # failing at once with SQLITE_BUSY.
  discard api.busy_timeout(result.h, DefaultBusyTimeoutMs)

proc closeDb*(db: Db) =
  if db.h.isNil: return
  let rc = api.close_v2(db.h)
  if rc != SQLITE_OK: fail(db, rc, "")
  db.h = nil

proc live(db: Db) =
  if db.h.isNil: err("SQLite database is closed: " & db.path)

proc bindParam(db: Db, s: Stmt, i: cint, v: Value, sql: string) =
  let rc =
    case v.kind
    of kNil: api.bind_null(s, i)
    of kBool: api.bind_int64(s, i, (if v.b: 1 else: 0))
    of kInt: api.bind_int64(s, i, v.i)
    of kFloat: api.bind_double(s, i, v.f)
    of kStr:
      api.bind_text(s, i, v.s.cstring, cint(v.s.len), SQLITE_TRANSIENT)
    of kList, kVector:
      # A byte-array (or any sequence of integers) is a blob; each element is
      # taken modulo 256, so signed and unsigned bytes both work.
      var bytes = newString(0)
      for x in elems(v):
        if x.kind != kInt: err("SQLite blob parameter must hold integers, got " & prStr(x))
        bytes.add char(uint8(x.i and 0xff))
      api.bind_blob(s, i, (if bytes.len == 0: nil else: bytes[0].addr),
                    cint(bytes.len), SQLITE_TRANSIENT)
    else:
      err("Unsupported SQLite parameter: " & prStr(v))
  check(db, rc, sql)

proc columnValue(s: Stmt, i: cint): Value =
  case api.column_type(s, i)
  of SQLITE_INTEGER: mkInt(api.column_int64(s, i))
  of SQLITE_FLOAT: mkFloat(api.column_double(s, i))
  of SQLITE_TEXT:
    let p = api.column_text(s, i)
    let n = int(api.column_bytes(s, i))
    var str = newString(n)
    if n > 0: copyMem(str[0].addr, p, n)
    mkStr(str)
  of SQLITE_BLOB:
    let p = cast[ptr UncheckedArray[uint8]](api.column_blob(s, i))
    let n = int(api.column_bytes(s, i))
    var xs = newSeqOfCap[Value](n)
    for j in 0 ..< n: xs.add mkInt(int64(p[j]))
    mkList(xs)
  else: NilV

proc run(db: Db, sql: string, params: seq[Value],
         onRow: proc (s: Stmt) {.closure.}): int =
  ## Runs every statement in `sql`, calling onRow for each result row, and
  ## returns how many statements ran. Parameters bind to a single statement
  ## only: splitting them across a script would be guesswork.
  db.live()
  var rest = sql
  var ran = 0
  while true:
    var s: Stmt = nil
    var tail: cstring = nil
    let src = rest.cstring
    check(db, api.prepare_v2(db.h, src, cint(rest.len), addr s, addr tail), rest)
    let consumed = (if tail.isNil: rest.len
                    else: int(cast[uint](tail) - cast[uint](src)))
    let text = rest[0 ..< consumed].strip
    rest = rest[consumed .. ^1]
    if s.isNil:
      # Only whitespace or a comment was left.
      if rest.strip.len == 0: break
      continue
    try:
      let n = int(api.bind_parameter_count(s))
      if params.len > 0 and rest.strip.len > 0:
        err("SQLite parameters need a single statement, got more after: " & text)
      if n != params.len:
        err("SQLite statement takes " & $n & " parameter(s), got " &
            $params.len & ": " & text)
      for i, p in params: bindParam(db, s, cint(i + 1), p, text)
      while true:
        let rc = api.step(s)
        if rc == SQLITE_ROW:
          if not onRow.isNil: onRow(s)
        elif rc == SQLITE_DONE: break
        else: fail(db, rc, text)
    finally:
      discard api.finalize(s)
    inc ran
    if rest.strip.len == 0: break
  ran

proc execute*(db: Db, sql: string, params: seq[Value]): Value =
  ## Runs a statement (or, without parameters, a script of them) and reports
  ## what the last one changed: {:changes n :last-insert-rowid id}.
  discard db.run(sql, params, nil)
  mkMap(@[(mkKeyword("changes"), mkInt(int64(api.changes(db.h)))),
          (mkKeyword("last-insert-rowid"), mkInt(api.last_insert_rowid(db.h)))])

proc query*(db: Db, sql: string, params: seq[Value]): Value =
  ## The rows of a query as a vector of maps keyed by column-name keywords.
  var rows: seq[Value] = @[]
  var names: seq[Value] = @[]
  let n = db.run(sql, params, proc (s: Stmt) =
    let cols = int(api.column_count(s))
    if names.len != cols:
      names.setLen(0)
      for i in 0 ..< cols: names.add mkKeyword($api.column_name(s, cint(i)))
    var ps = newSeqOfCap[(Value, Value)](cols)
    for i in 0 ..< cols: ps.add (names[i], columnValue(s, cint(i)))
    rows.add mkMap(ps))
  if n != 1: err("SQLite query expects a single statement: " & sql)
  mkVector(rows)

proc transaction*(db: Db, f: Value): Value =
  ## Calls f with no arguments inside BEGIN IMMEDIATE ... COMMIT, taking the
  ## write lock up front. Anything f throws rolls the transaction back and is
  ## rethrown as it was.
  discard db.run("BEGIN IMMEDIATE", @[], nil)
  try:
    result = call(f, [])
    discard db.run("COMMIT", @[], nil)
  except CatchableError:
    # SQLite has already rolled back after some errors; a failing ROLLBACK
    # must not hide the error that got us here.
    try: discard db.run("ROLLBACK", @[], nil)
    except CatchableError: discard
    raise
