(ns clonim.core)

;; Host-dependent operations stay behind a small runtime primitive.
(defn now-ms [] (*epoch-time-ms*))
