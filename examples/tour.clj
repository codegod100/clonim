;; ---- tail recursion compiles to a Nim loop, no stack growth
(defn sum-to [n]
  (loop [i 0 acc 0]
    (if (> i n)
      acc
      (recur (inc i) (+ acc i)))))

(println "sum 1..1e6 =" (sum-to 1000000))

;; ---- closures
(defn adder [n] (fn [x] (+ x n)))
(def add5 (adder 5))
(println "add5 10 =" (add5 10))

;; ---- multi-arity + varargs
(defn hi
  ([] (hi "stranger"))
  ([who] (str "hi " who))
  ([who & more] (str "hi " who " and " (count more) " others")))
(println (hi) "|" (hi "ann") "|" (hi "ann" "bo" "cy"))

;; ---- self-recursive fn by name
(def fact (fn f [n] (if (<= n 1) 1 (* n (f (dec n))))))
(println "20! =" (fact 20))

;; ---- destructuring
(let [[a b & rest] [1 2 3 4 5]
      {:keys [x y]} {:x 10 :y 20}]
  (println a b rest x y))

;; ---- threading macros
(println (-> 5 inc (* 3) (- 2)))
(println (->> (range 20) (filter odd?) (map #_skipped (fn [n] (* n n))) (reduce +)))

;; ---- atoms
(def counter (atom 0))
(dotimes [_ 5] (swap! counter inc))
(println "counter =" @counter)

;; ---- maps, sorting, grouping
(def people [{:name "ada" :age 36} {:name "bo" :age 9} {:name "cy" :age 52}])
(println (map :name (sort-by :age people)))
(println (group-by (fn [p] (if (< (:age p) 18) :kid :adult)) people))

;; ---- cond / when / case-ish dispatch
(defn classify [n]
  (cond
    (zero? n) "zero"
    (neg? n)  "negative"
    (even? n) "even"
    :else     "odd"))
(println (map classify [0 -3 4 7]))

;; ---- exceptions
(println (try (/ 1 0) (catch Exception e (str "caught: " e))))

;; ---- higher order composition
(def inc-then-double (comp (partial * 2) inc))
(println (inc-then-double 20))
(println (apply + (range 101)))
