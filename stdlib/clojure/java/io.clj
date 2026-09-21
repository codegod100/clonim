(ns clojure.java.io)

;; Native file operations supplied by Clonim's runtime.
(defn delete-file
  ([path] (*delete-file* path false))
  ([path silently] (*delete-file* path silently)))

;; A write handle for `with-open`: (.write o bytes) then (.close o).
(defn output-stream [path]
  (*output-stream* path))
