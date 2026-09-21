;; loop vars that must NOT specialise
(println (loop [x 0.0 n 0] (if (< n 3) (recur (+ x 0.5) (+ n 1)) x)))      ; 1.5
(println (loop [s "" n 0] (if (< n 3) (recur (str s "a") (+ n 1)) s)))     ; "aaa"
(println (loop [v [] n 0] (if (< n 3) (recur (conj v n) (+ n 1)) v)))      ; [0 1 2]
;; a var that starts int but recurs with a float must demote
(println (loop [x 0 n 0] (if (< n 3) (recur (+ x 0.5) (+ n 1)) x)))        ; 1.5
;; mixed: one int slot, one not
(println (loop [i 0 acc []] (if (< i 3) (recur (+ i 1) (conj acc i)) acc))) ; [0 1 2]

;; int fns called with non-int arguments must use the generic path
(defn twice [x] (+ x x))
(println (twice 21) (twice 1.5))                                   ; 42 3.0
(defn joiner [a b] (str a b))
(println (joiner 1 2) (joiner "a" "b"))                                    ; 12 ab
;; a fn used as a value still works
(println (map twice [1 2 3]) (reduce + (map twice [1 2])))                 ; (2 4 6) 6

;; shadowing a primitive inside a fn body defeats specialisation
(defn shadowed [x] (let [+ (fn [a b] (* a b))] (+ x x)))
(println (shadowed 5))                                                     ; 25

;; quot / rem / inc / dec, including negatives
(println (quot 7 2) (quot -7 2) (rem 7 2) (rem -7 2) (inc 5) (dec 5))      ; 3 -3 1 -1 6 4
;; comparison chain of non-numbers must not become an int compare
(println (= "a" "a") (= :k :k) (= [1] [1]) (not= 1 2))                     ; true true true true
;; division by zero still reports, rather than trapping
(println (try (quot 1 0) (catch Exception e "caught")))
;; a fn whose recur makes a parameter non-integral must not specialise
(defn k [x n] (if (< n 3) (recur (str x "a") (+ n 1)) x))
(println (k "" 0))                                                         ; aaa
;; recur that keeps every parameter integral still specialises, and is correct
(defn countdown [n acc] (if (< n 1) acc (recur (- n 1) (+ acc n))))
(println (countdown 100 0))                                                ; 5050
;; deep tail recursion must stay in constant space
(println (countdown 3000000 0))                                            ; 4500001500000
