;; range: arities, steps, empty and negative
(println (range 5) (range 2 5) (range 0 10 3) (range 5 0 -2))
(println (range 0) (range 5 5) (range 5 0) (range 0 5 -1))
;; count / empty? across kinds
(println (count [1 2 3]) (count '(1 2)) (count "abcd") (count {:a 1 :b 2}) (count nil))
(println (empty? []) (empty? [1]) (empty? "") (empty? nil))
;; non-fn callables must still work as the function argument
(println (map :a [{:a 1} {:a 2}]))                       ; (1 2)
(println (map {1 :one 2 :two} [1 2]))                    ; (:one :two)
;; reduce: empty, single, with an explicit init
(println (reduce + []) (reduce + [7]) (reduce + 100 [1 2 3]) (reduce + [1 2 3]))
;; map/filter over other collection kinds
(println (map inc #{1 2}) (count (filter even? (range 10))) (map inc "") )
;; laziness is not claimed: these are eager, so side effects happen once
(def n (atom 0))
(def r (map (fn [x] (reset! n (+ (deref n) 1)) x) [1 2 3]))
(println (count r) (deref n) (count r) (deref n))        ; 3 3 3 3
