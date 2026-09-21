(defn work [n]
  (reduce + (map (fn [x] (* x x)) (filter even? (range n)))))
(println (work 1000000))
