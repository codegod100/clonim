(ns macros (:require [clojure.java.io :as io]))

;; case: literal constants, grouped clauses, optional default
(defn kind [x] (case x 0 :zero 1 :one (2 3) :few :other))
(println (kind 0) (kind 1) (kind 3) (kind 9))        ; :zero :one :few :other
(println (case \n \n :nl \t :tab :none))             ; :nl
(println (case :east :east 1 :west 2 3))             ; 1
(println (try (case 5 0 :z) (catch Exception e (ex-message e)))) ; No matching clause: 5

;; for: one or more bindings, eager
(println (for [n (range 4)] (* n n)))                ; (0 1 4 9)
(println (for [a [1 2] b [:x :y]] [a b]))            ; ([1 :x] [1 :y] [2 :x] [2 :y])
(println (apply str (for [c "abc"] c)))              ; abc

;; assert
(println (try (assert (= 1 2) "nope") (catch Exception e (ex-message e))))
(println (try (assert (= 1 2)) (catch Exception e (ex-message e))))

;; binding: dynamic scope, unwound on every exit
(def ^:dynamic *depth* 0)
(defn show [] (println "depth" *depth*))
(show)
(binding [*depth* 3] (show))
(show)
(println (try (binding [*depth* 9] (throw (ex-info "x" {})))
              (catch Exception e *depth*)))         ; 0

;; StringBuilder, with-open and a write handle
(let [b (StringBuilder.)]
  (.append b \h) (.append b "ello")
  (println (str b) (.length b)))                     ; hello 5
(with-open [o (io/output-stream "macros.tmp")]
  (.write o (byte-array (map unchecked-byte [104 105]))))
(println (slurp "macros.tmp"))                       ; hi
(io/delete-file "macros.tmp")
