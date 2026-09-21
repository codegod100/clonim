(ns persistent)

;; build a big vector by conj, then read it back
(def n 5000)
(def v (reduce conj [] (range n)))
(println "count" (count v))
(println "nth" (nth v 0) (nth v 33) (nth v 1024) (nth v (dec n)))
(println "sum" (reduce + 0 v))
(def v2 (assoc v 1234 :x))
(println "assoc" (nth v2 1234) (nth v 1234) (count v2))
(println "last" (last v) (first v))
(println "eq" (= v (reduce conj [] (range n))))

;; big map
(def m (reduce (fn [acc i] (assoc acc i (* i i))) {} (range n)))
(println "mcount" (count m) (get m 0) (get m 4999) (get m 5000))
(def m2 (dissoc m 100))
(println "dissoc" (count m2) (get m2 100) (get m 100))
(println "keys-sum" (reduce + 0 (keys m)))
(println "vals-sum" (reduce + 0 (vals m)))
(println "meq" (= m (reduce (fn [acc i] (assoc acc i (* i i))) {} (range n))))

;; sets
(def s (set (range n)))
(println "scount" (count s) (contains? s 4999) (contains? s 5000))
(println "sconj" (count (conj s 5000)) (count (conj s 0)))

;; ordering + mixed keys
(def om {:b 1 :a 2 "c" 3 4 5 [1 2] 6})
(println om)
(println (keys om))
(println (assoc om :a 99))
(println (get om [1 2]) (get om 4) (get om "c"))
(println (= {:a 1 :b 2} {:b 2 :a 1}))
(println (= #{1 2 3} #{3 2 1}))
(println (get {1 :int} 1.0) (get {1.0 :flt} 1))
(println (frequencies [1 1 2 3 3 3]))
(println (group-by even? (range 10)))
(println (update {:a 1} :a inc))
