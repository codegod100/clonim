;; chunking realizes in batches of 32: demand is rounded up, never exceeded
;; beyond a batch, and nothing is recomputed
(def calls (atom 0))
(def xs (map (fn [x] (reset! calls (inc (deref calls))) x) (range 1000)))
(println "built:" (deref calls))                        ; 0
(println (doall (take 3 xs)) "calls:" (deref calls))    ; (0 1 2) 32
(println (doall (take 3 xs)) "calls:" (deref calls))    ; memoized, still 32
(println (doall (take 40 xs)) "calls:" (deref calls))   ; 64

;; infinite sources stay usable
(println (take 5 (filter even? (range))))
(println (first (filter (fn [x] (> x 100)) (range))))
(println (take 3 (map inc (iterate inc 0))))
(println (nth (range) 1000) (take 4 (drop 10 (range))))
(println (count (take 100 (cycle [1 2 3]))))

;; rare matches over a long source must not pull a whole chunk of matches
(println (first (filter (fn [x] (= x 5000)) (range))))

;; chunked and unchunked seqs interoperate
(println (take 4 (concat [1 2] (range))))
(println (count (cons 0 (range 10))))
(println (reduce + (cons 100 (map inc (range 5)))))
(println (take 3 (map (fn [a b] (+ a b)) (range) (cycle [10 20]))))
