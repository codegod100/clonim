;; A destructured value is computed once, however many names it binds.
(def calls (atom 0))
(defn pair [] (swap! calls inc) [@calls :x])
(let [[a b] (pair)] (prn a b @calls))
(let [{:keys [p q]} (do (swap! calls inc) {:p 1 :q 2})] (prn p q @calls))
(defn f [[x y] {:keys [z]}] [x y z])
(prn (f (do (swap! calls inc) [1 2]) {:z 3}) @calls)
(loop [[h & t] (do (swap! calls inc) [1 2 3]) acc 0]
  (if h (recur t (+ acc h)) (prn acc @calls)))
