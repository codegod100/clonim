(ns sqlite
  (:require [clonim.sqlite :as sql]
            [clojure.java.io :as io]))

;; in memory: schema script, parameters, typed columns
(def db (sql/open ":memory:"))
(sql/execute! db "create table person (id integer primary key, name text,
                                       age integer, score real, photo blob);
                  create index person_name on person (name)")
(println (sql/execute! db "insert into person (name, age, score) values (?, ?, ?)"
                       ["Ada" 36 9.5]))                 ; {:changes 1, :last-insert-rowid 1}
(sql/execute! db "insert into person (name, age, score, photo) values (?, ?, ?, ?)"
              ["Grace" nil 8.25 (byte-array [0 127 -1 200])])
(prn (sql/query db "select id, name, age, score from person order by id"))
(prn (sql/query db "select photo from person where name = ?" ["Grace"]))  ; bytes unsigned
(prn (sql/query db "select count(*) as n, ? as flag from person" [true]))
(prn (sql/query db "select name from person where name = ?" ["nobody"])) ; []

;; transactions commit, or roll back and rethrow
(println (sql/transaction db
           (fn []
             (sql/execute! db "update person set age = age + 1 where name = 'Ada'")
             :committed)))
(println (try
           (sql/transaction db
             (fn []
               (sql/execute! db "delete from person")
               (throw (ex-info "abort" {:why :test}))))
           (catch Exception e [(ex-message e) (ex-data e)])))
(prn (sql/query db "select name, age from person order by id"))

;; SQLite's errors are ex-info with the result code and statement
(println (try (sql/query db "select * from nowhere")
              (catch Exception e [(ex-message e) (ex-data e)])))
(println (try (sql/execute! db "insert into person (id) values (?)" [1])
              (catch Exception e (:sqlite/code (ex-data e)))))  ; 19: constraint
(println (try (sql/query db "select ?" [])
              (catch Exception e (ex-message e))))
(sql/close db)
(println (try (sql/query db "select 1") (catch Exception e (ex-message e))))

;; a file survives closing, and a second handle sees the first one's commits
(def path (str (System/getProperty "java.io.tmpdir") "/clonim-sqlite-example.db"))
(io/delete-file path true)
(let [w (sql/open path)]
  (sql/execute! w "create table log (t integer primary key, tx text)")
  (sql/execute! w "insert into log (tx) values (?)" ["[:db/add 1 :x 1]"])
  (sql/close w))
(with-open [r (sql/open path)]
  (prn (sql/query r "select * from log")))
(io/delete-file path)
