(defprotocol Shape
  (area [this])
  (scale [this k]))

(deftype Rect [w h]
  Shape
  (area [this] (* w h))
  (scale [this k] (Rect. (* w k) (* h k)))
  Object
  (toString [this] (str "Rect " w "x" h)))

(def r (->Rect 2 3))
(println (area r) (area (scale r 2)) (str r) (instance? Rect r) (.toString (scale r 10)))

;; A lazy lookup object: behaves like a read-only map for get/keyword/keys.
(defn lazy-map [f ks]
  (let [calls (atom 0)]
    (reify
      clojure.lang.ILookup
      (valAt [this k] (.valAt this k nil))
      (valAt [this k nf] (if (some #{k} ks) (do (swap! calls inc) (f k)) nf))
      clojure.lang.Seqable
      (seq [this] (map (fn [k] [k (f k)]) ks))
      clojure.lang.Counted
      (count [this] (count ks))
      clojure.lang.Associative
      (containsKey [this k] (boolean (some #{k} ks)))
      clojure.lang.IDeref
      (deref [this] @calls))))

(def m (lazy-map name [:a :b]))
(prn (:a m) (get m :b) (get m :z :none) (:z m 0) (map first m) (map second m) (count m)
     (contains? m :a) (contains? m :q) @m)
(prn (into {} m) (map first m))

(def box (reify clojure.lang.IDeref (deref [_] 42)))
(prn @box (deref box))
(println (. r (area)) (str (. r scale 3)))
