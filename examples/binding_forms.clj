(ns binding-forms)

;; destructuring in fn parameters, including multiple arities
(println ((fn [[a b] c] [a b c]) [1 2] 3))              ; [1 2 3]
(println (map (fn [[k v]] (str k v)) [[:a 1] [:b 2]]))  ; (:a1 :b2)
(defn g ([[a b]] (+ a b)) ([x y] (* x y)))
(println (g [3 4]) (g 3 4))                             ; 7 12
(println ((fn [{:keys [x y]}] [x y]) {:x 1 :y 2}))      ; [1 2]

;; :as, :or, nesting, and a rest that is nil once exhausted
(let [[a b & more :as all] [1 2 3 4]] (println a b more all))
(let [[a & r] [1]] (println r (nil? r)))                ; nil true
(let [{:keys [x y] :or {y 9} :as m} {:x 1}] (println x y m))
(let [[[a b] [c]] [[1 2] [3]]] (println a b c))         ; 1 2 3
(println ((fn [& xs] xs)) ((fn [& xs] xs) 1))           ; nil (1)

;; loop variables destructure too, and recur assigns the whole form
(println (loop [[t & more] [1 2 3] acc []]
           (if (nil? t) acc (recur more (conj acc t)))))  ; [1 2 3]

;; #() is one call, and takes numbered arguments
(println (map #(format "%02x" %) [227 176]))            ; (e3 b0)
(println (map #(* 2 %) [1 2 3]))                        ; (2 4 6)
(println (map #(+ %1 %2) [1 2] [10 20]))                ; (11 22)
(println (#(vector % %) 7))                             ; [7 7]

;; a rebound loop variable is still a Value, not a raw int
(println (loop [i 0 acc 0]
           (if (= i 3) acc
             (let [[acc] [(+ acc i)]] (recur (inc i) acc)))))  ; 3
