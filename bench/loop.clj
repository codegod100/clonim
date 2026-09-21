(defn sum-to [n]
  (loop [i 0 acc 0]
    (if (< i n) (recur (+ i 1) (+ acc i)) acc)))
(println (sum-to 10000000))
