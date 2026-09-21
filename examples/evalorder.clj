(def log (atom []))
(defn note [x] (do (reset! log (conj (deref log) x)) x))

;; 1. argument evaluation order, left to right
(reset! log [])
(defn three [a b c] (str a b c))
(println (three (note 1) (note 2) (note 3)) (deref log))

;; 2. side effects in non-tail positions of a body must still run
(reset! log [])
(defn body [] (do (note :a) (note :b) :done))
(println (body) (deref log))

;; 3. mixed pure and statement-shaped arguments keep their order
(reset! log [])
(println (three (note 1) (if true (note 2) nil) (note 3)) (deref log))

;; 4. recur arguments see the OLD bindings
(println (loop [i 0 acc 0] (if (< i 5) (recur (+ i 1) (+ acc i)) acc)))   ; 10
(println (loop [a 1 b 2 n 0] (if (< n 3) (recur b a (+ n 1)) [a b])))    ; swapped 3x -> [2 1]
;; 5. when-let / if-let evaluate the test exactly once
(reset! log [])
(println (when-let [v (note 7)] v) (deref log))
(reset! log [])
(println (if-let [v (note 8)] v :no) (deref log))

;; 6. and / or short-circuit
(reset! log [])
(println (and false (note :never)) (or :first (note :never2)) (deref log))

;; 7. collection literal element order
(reset! log [])
(println [(note 1) (note 2)] (deref log))
(reset! log [])
(println (count {(note :k1) (note :v1)}) (deref log))

;; 8. a let binding shadowing mid-body
(println (let [x 1 y (+ x 1) x (+ y 10)] [x y]))                          ; [12 2]
