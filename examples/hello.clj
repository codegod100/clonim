(ns hello)

;; a first taste
(defn greet [name]
  (str "Hello, " name "!"))

(println (greet "world"))
(println (+ 1 2 3) (* 2 21) (/ 10 4) (/ 10.0 4))
(println (map inc [1 2 3]) (filter even? (range 10)))
(println {:a 1 :b [2 3]} #{1 2} '(quoted list))
