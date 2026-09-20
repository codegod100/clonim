(def n 2000000)
(let [t0 (now-ms)
      a  (first (filter odd? (map inc (range n))))
      t1 (now-ms)
      b  (reduce + 0 (take 10 (map (fn [x] (* x x)) (range n))))
      t2 (now-ms)]
  (println "first of filter/map over" n ":" (- t1 t0) "ms  =" a)
  (println "sum of take 10 over    " n ":" (- t2 t1) "ms  =" b))
