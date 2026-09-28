(ns clonim.postgres)

;; PostgreSQL through the runtime's *pg-connect* handle. libpq is loaded on
;; first use (set CLONIM_LIBPQ to pick a file), so programs that don't use
;; it don't need it.
;;
;; Parameters are $1, $2, ... as in PostgreSQL. nil, integers, floats,
;; strings and booleans bind as themselves; a byte-array or other sequence
;; of integers binds as bytea. Rows come back as maps keyed by column-name
;; keywords, typed by column: integers, floats, booleans, bytea as unsigned
;; bytes, and everything else (text, json, timestamps, ...) as strings.
;; Server errors are ex-info with {:pg/sqlstate "..." :sql "..."}.

(defn connect
  "Connect with a libpq connection string or URI, such as
  \"postgresql://user:pass@host:5432/db?sslmode=require\"."
  [conninfo]
  (*pg-connect* conninfo))

(defn close [pg] (pg :close))

(defn execute!
  "Run a statement with optional parameters, or a script of statements
  without them. Returns {:changes n}."
  ([pg sql] (pg :execute sql nil))
  ([pg sql params] (pg :execute sql params)))

(defn query
  "The rows of a statement, as a vector of maps."
  ([pg sql] (pg :query sql nil))
  ([pg sql params] (pg :query sql params)))

(defn transaction
  "Call (f) between BEGIN and COMMIT and return its result. If f throws,
  the transaction is rolled back and the exception rethrown."
  [pg f]
  (pg :transaction f))

(defn listen
  "Receive NOTIFYs on a channel from now on."
  [pg channel]
  (pg :listen channel))

(defn notifications
  "Notifications received so far on listened channels, as maps of
  :channel :payload :pid. If none has arrived, waits up to timeout-ms for
  one (nil or negative: as long as it takes; 0: not at all). [] if none."
  ([pg] (pg :notifications -1))
  ([pg timeout-ms] (pg :notifications (or timeout-ms -1))))

(defn reconnect!
  "Reconnect with the same settings, after the server dropped the
  connection."
  [pg]
  (pg :reset))
