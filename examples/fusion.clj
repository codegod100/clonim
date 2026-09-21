(ns fusion)

;; results must match whether or not the pipeline fuses
(println (reduce + (map (fn [x] (* x x)) (filter even? (range 20)))))    ; 1140
(println (reduce + 1000 (map inc (filter odd? (range 10)))))             ; 1000+2+4+6+8+10=1030
(println (count (map inc (range 7))) (count (filter even? (range 7))))   ; 7 4
(println (reduce + (remove even? (range 10))))                           ; 25
(println (reduce + (map inc (map inc (map inc (range 5))))))             ; 0..4 +3 each = 25
(println (reduce + (map inc (filter even? []))))                         ; 0
(println (reduce + 99 (map inc (filter even? []))))                      ; 99
(println (reduce + (map inc (filter even? [2]))))                        ; 3

;; non-range bases of every kind
(println (reduce + (map inc [1 2 3])) (reduce + (map inc '(1 2 3))))
(println (reduce + (map inc #{1 2 3})))

;; a NAMED pipeline must still memoize: the fn runs once, not once per pass
(def n (atom 0))
(def ys (map (fn [x] (reset! n (+ (deref n) 1)) x) (range 10)))
(println (reduce + ys) (deref n) (reduce + ys) (deref n))   ; 45 10 45 10

;; an inline pipeline over a NAMED lazy source must not re-run the source
(def m (atom 0))
(def zs (map (fn [x] (reset! m (+ (deref m) 1)) x) (range 10)))
(println (reduce + (map inc zs)) (deref m) (reduce + (map inc zs)) (deref m)) ; 55 10 55 10

;; evaluation order: reducing fn, then each stage outermost-in, then the base
(def log (atom []))
(defn note [x v] (do (reset! log (conj (deref log) x)) v))
(println (reduce (note :f +) (map (note :g inc) (filter (note :p even?) (note :src [1 2 3 4])))))
(println (deref log))                                        ; (:f :g :p :src)

;; shadowing and rebinding must defeat fusion, not break it
(println (let [map (fn [_f _c] [99])] (reduce + (map inc [1 2 3]))))   ; 99

;; a def of one of the pipeline names defeats fusion for the whole program
(def map (fn [_f _c] [:replaced]))
(println (reduce conj [] (map inc [1 2 3])))                 ; [:replaced]
