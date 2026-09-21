;; a fn redefined later: every call site sees the definition in force
(defn f [x] (+ x 1))
(println (f 10))                                    ; 11
(def f (fn [x] (* x 100)))
(println (f 10))                                    ; 1000

;; redefining a primitive defeats specialisation for the whole program, so the
;; loop below must observe the new + even though it was compiled earlier
(defn sum [n] (loop [i 0 acc 0] (if (< i n) (recur (inc i) (+ acc i)) acc)))
(println (sum 5))                                   ; 0+1+2+3+4 = 10
(def + (fn [a b] (* a b)))
(println (sum 5))                                   ; + is now *, so acc stays 0
(println (+ 3 4))                                   ; 12
