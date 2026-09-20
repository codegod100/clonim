;; Lazy seqs: map/filter/range and friends compute only what is asked for.

;; infinite sources are ordinary values
(println (take 5 (range)))
(println (take 5 (map inc (range))))
(println (take 5 (filter even? (range))))
(println (take 5 (iterate (fn [x] (* 2 x)) 1)))
(println (take 4 (repeat :x)) (repeat 3 :y))
(println (take 7 (cycle [1 2 3])))
(println (take 3 (drop 100 (range))))
(println (take-while (fn [x] (< x 5)) (range)))
(println (take 3 (drop-while (fn [x] (< x 10)) (range))))
(println (take 5 (concat [1 2] (range))))
(println (first (map inc (range))) (second (range)) (nth (range) 1000))

;; nothing beyond the demand is computed, and each cell is computed once
(def calls (atom 0))
(def xs (map (fn [x] (reset! calls (inc (deref calls))) x) (range 1000)))
(println "built, calls so far:" (deref calls))
(def three (doall (take 3 xs)))
(println "took" three "- calls:" (deref calls))
(println "took" (doall (take 3 xs)) "- calls:" (deref calls) "(memoized)")

;; composing lazily builds no intermediate collections
(println (reduce + 0 (take 10 (filter odd? (map (fn [x] (* x x)) (range))))))

;; destructuring walks only as far as the pattern needs
(let [[a b & more] (range)]
  (println a b (take 3 more)))

;; finite collections behave exactly as before
(println (map inc [1 2 3]) (filter even? [1 2 3 4]))
(println (range 5) (range 2 8 2) (range 5 0 -1))
(println (count (range 100)) (empty? (range 0)) (seq (range 0)) (seq (range 2)))
(println (= (range 3) [0 1 2]) (= (map inc [0 1]) (list 1 2)))
(println (vec (take 3 (range))) (sort (take 4 (map (fn [x] (- 9 x)) (range)))))
(println (cons 0 (range 3)) (rest (range 3)) (next (range 1)) (last (take 4 (range))))
(doseq [x (take 3 (map inc (range)))] (print x ""))
(println)

;; realizing a long seq is iterative: no stack growth, no deep teardown
(println (count (take 200000 (range))) (nth (iterate inc 0) 200000))
