(def n (atom 0))
(dotimes [i (+ 2 3)] (reset! n (+ (deref n) i)))
(println "dotimes" (deref n))                                   ; 0+1+2+3+4 = 10
(doseq [x (map inc [1 2 3])] (reset! n (+ (deref n) x)))
(println "doseq" (deref n))                                     ; 10 + 2+3+4 = 19
(println (try (/ 1 0) (catch Exception e (str "caught: " e)) (finally (reset! n 99))))
(println "finally ran:" (deref n))
(println (-> 5 (+ 1) (* 2)) (->> [1 2 3] (map inc) (reduce +)))  ; 12 9
(println (cond (> 1 2) :a (< 1 2) :b :else :c))                  ; :b
(println (str "nested " (+ 1 (* 2 (- 10 (+ 3 4))))))             ; 1+2*3 = 7
