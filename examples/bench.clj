(defn fib [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
(let [t (now-ms)]
  (println "fib 30 =" (fib 30) "in" (- (now-ms) t) "ms"))
