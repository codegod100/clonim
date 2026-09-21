(ns directcalls)

(defn f [x] (* x 2))
(println (f 5))
(def f (fn [x] (+ x 100)))
(println (f 5))                      ; rebinding must win: 105

(defn g ([x] (g x 1)) ([x y] (+ x y)) ([x y & more] (reduce + (cons (+ x y) more))))
(println (g 3) (g 3 4) (g 1 2 3 4))  ; 4 7 10

(defn h [x] (inc x))
(println (map h [1 2 3]))            ; h as a value: (2 3 4)

(defn shadow [x] x)
(println (let [shadow (fn [y] (* y 10))] (shadow 5)))  ; local shadows: 50

(defn fact [n] (if (< n 2) 1 (* n (fact (- n 1)))))
(println (fact 10))                  ; 3628800

(declare od?)
(defn ev? [n] (if (= n 0) true (od? (- n 1))))
(defn od? [n] (if (= n 0) false (ev? (- n 1))))
(println (ev? 10) (od? 7))           ; true true
