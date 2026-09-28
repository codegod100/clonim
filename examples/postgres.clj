(ns postgres
  (:require [clonim.postgres :as pg]))

;; Needs a server: CLONIM_TEST_POSTGRES=postgresql://user:pass@host/db
;; (run-tests.sh skips this example without it).
(def uri (System/getenv "CLONIM_TEST_POSTGRES"))
(def db (pg/connect uri))
(pg/execute! db "drop table if exists clonim_person;
                 create table clonim_person (id bigserial primary key, name text,
                                             age integer, score double precision,
                                             ok boolean, photo bytea, n numeric)")
(println (pg/execute! db "insert into clonim_person (name, age, score, ok, n) values ($1, $2, $3, $4, $5)"
                      ["Ada" 36 9.5 true 12]))                    ; {:changes 1}
(pg/execute! db "insert into clonim_person (name, age, score, ok, photo, n) values ($1, $2, $3, $4, $5, $6)"
             ["Grace" nil 8.25 false (byte-array [0 127 -1 200]) 2.5])
(prn (pg/query db "select id, name, age, score, ok, n from clonim_person order by id"))
(prn (pg/query db "select photo from clonim_person where name = $1" ["Grace"]))
(prn (pg/query db "select name from clonim_person where name = $1" ["nobody"]))
(prn (pg/query db "insert into clonim_person (name) values ($1) returning id" ["Barbara"]))

;; transactions commit, or roll back and rethrow
(println (pg/transaction db
           (fn [] (pg/execute! db "update clonim_person set age = age + 1 where name = 'Ada'")
                  :committed)))
(println (try (pg/transaction db (fn [] (pg/execute! db "delete from clonim_person")
                                        (throw (ex-info "abort" {:why :test}))))
              (catch Exception e [(ex-message e) (ex-data e)])))
(prn (pg/query db "select name, age from clonim_person order by id"))

;; server errors carry the SQLSTATE
(println (try (pg/query db "select * from nowhere")
              (catch Exception e (:pg/sqlstate (ex-data e)))))              ; 42P01
(println (try (pg/execute! db "insert into clonim_person (id) values ($1)" [1])
              (catch Exception e (:pg/sqlstate (ex-data e)))))              ; 23505

;; LISTEN/NOTIFY between two connections
(def other (pg/connect uri))
(pg/listen other "clonim_test")
(println (pg/notifications other 0))                               ; nothing yet
(pg/execute! db "select pg_notify('clonim_test', 'hello')")
(println (map (juxt :channel :payload) (pg/notifications other 5000)))
(let [t0 (System/currentTimeMillis)]
  (println (pg/notifications other 50) (>= (- (System/currentTimeMillis) t0) 50)))
;; a notify sent inside a transaction arrives when it commits
(pg/transaction db (fn [] (pg/execute! db "notify clonim_test, 'in-tx'")))
(println (map :payload (pg/notifications other 5000)))

(pg/execute! db "drop table clonim_person")
(pg/close other)
(pg/close db)
(println (try (pg/query db "select 1") (catch Exception e (ex-message e))))
(println (try (pg/connect "postgresql://nobody@127.0.0.1:1/x?connect_timeout=2")
              (catch Exception e (:pg/sqlstate (ex-data e)))))
