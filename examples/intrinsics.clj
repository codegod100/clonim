(ns intrinsics)

(println (+ 1 2) (- 5 3) (* 4 5) (inc 7) (dec 7))        ; 3 2 20 8 6
(println (+ 1.5 2) (* 2 0.5) (- 1 0.25) (inc 1.5))       ; 3.5 1.0 0.75 2.5
(println (< 1 2) (> 1 2) (<= 2 2) (>= 1 2))              ; true false true false
(println (< 1.5 2) (>= 2.0 2))                           ; true true
(println (= 1 1) (= 1 2) (= "a" "a") (= [1 2] [1 2]))    ; true false true true
(println (= 1 1.0) (not= 1 2) (not= :a :a))              ; true true false
(println (+ 1 2 3) (< 1 2 3) (= 1 1 1))                  ; non-binary arities: 6 true true
(println (let [+ (fn [a b] (* a b))] (+ 3 4)))           ; local shadow: 12
(println (reduce + [1 2 3 4]))                           ; + as a value: 10
(def + (fn [_a _b] 999))
(println (+ 1 2))                                        ; rebound: 999
