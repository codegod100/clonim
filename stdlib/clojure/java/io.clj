(ns clojure.java.io)

;; Native file operations supplied by Clonim's runtime.
(defn delete-file [path silently]
  (*delete-file* path silently))
