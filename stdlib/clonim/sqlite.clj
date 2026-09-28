(ns clonim.sqlite)

;; SQLite through the runtime's *sqlite-open* handle. The library is loaded
;; on first use (set CLONIM_SQLITE_LIB to pick a file), so programs that
;; don't use it don't need it.
;;
;; Values: nil, integers, floats, strings and booleans (as 1/0) bind as
;; parameters; a byte-array or other sequence of integers binds as a blob.
;; Rows come back as maps keyed by column-name keywords, with blobs as
;; sequences of unsigned bytes. SQLite errors are ex-info with
;; {:sqlite/code n :sql "..."}.

(defn open
  "Open (creating if needed) the database file at path; \":memory:\" is a
  private in-memory database. Waits up to 5s for another writer's lock."
  [path]
  (*sqlite-open* path))

(defn close [db] (db :close))

(defn execute!
  "Run a statement with optional positional parameters, or a script of
  statements without them. Returns {:changes n :last-insert-rowid id}."
  ([db sql] (db :execute sql nil))
  ([db sql params] (db :execute sql params)))

(defn query
  "The rows of a single statement, as a vector of maps."
  ([db sql] (db :query sql nil))
  ([db sql params] (db :query sql params)))

(defn transaction
  "Call (f) inside BEGIN IMMEDIATE ... COMMIT and return its result. If f
  throws, the transaction is rolled back and the exception rethrown."
  [db f]
  (db :transaction f))
