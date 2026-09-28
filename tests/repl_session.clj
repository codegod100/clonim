; Fed line by line to `clonim repl` by run-tests.sh; see repl_session.expected.
; Each input runs once, so the atom counts calls rather than replays.
(def hits (atom 0))
(defn hit! [] (swap! hits inc))
(hit!)
(hit!)
(println "printed once")
@hits
; Callers compiled earlier see later redefinitions.
(def scale 2)
(defn scaled [n] (* n scale))
(scaled 5)
(def scale 10)
(scaled 5)
(declare od?)
(defn ev? [n] (if (= n 0) true (od? (- n 1))))
(defn od? [n] (if (= n 0) false (ev? (- n 1))))
[(ev? 10) (od? 7)]
; An error ends its input but keeps what ran before it.
(do (hit!) (nth [] 1) (hit!))
@hits
(undefined-thing)
(defmacro unless [t a b] (list 'if t b a))
(unless false :yes :no)
(def xs (map inc (range)))
(take 3 xs)
(ns other)
(def y 4)
(ns third (:require [other :as o]))
(+ o/y 1)
