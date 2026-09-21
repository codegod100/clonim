(ns cli-args)

;; A program with -main gets it called with the command line, which is also
;; *command-line-args*.
(defn -main [& argv]
  (println "args:" (count argv) (vec argv))
  (println "same:" (= (seq argv) (seq *command-line-args*))))
