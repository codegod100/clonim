(ns hostfns (:require [clojure.string :as str]))

;; characters
(println \a \space (int \A) (char 66) (str \x \y) (char? \a))       ; a   65 B xy true
(println (.charAt "abc" 1) (= \a \a) (= \a 97) (#{\- \+} \+))       ; b true false +
(prn \a \newline \tab)                                              ; \a \newline \tab
(println (Character/isDigit \7) (Character/isLetter \7))            ; true false

;; numbers
(println (long 3.7) (unchecked-int 4294967295) (unchecked-byte 200)) ; 3 -1 -56
(println (Integer/parseInt "ff" 16) (Long/parseLong "-12"))          ; 255 -12
(println (Double/parseDouble "2.5") (Math/floor 2.7) (Math/ceil 2.1)); 2.5 2.0 3.0

;; format
(println (format "%02x|%s|%5d|%-4s|%.2f|%X|%%" 10 :kw 42 "ab" 3.14159 255))

;; sequences
(println (into [] (mapcat (fn [a b] [a b]) [1 2] [:a :b])))          ; [1 :a 2 :b]
(println (partition-all 2 [1 2 3 4 5]))                              ; ((1 2) (3 4) (5))
(println (partition-by even? [1 3 2 4 5]))                           ; ((1 3) (2 4) (5))
(println (into #{} [1 1 2]) (into {} [[:a 1]]))                      ; #{1 2} {:a 1}

;; strings
(println (str/blank? "  ") (str/starts-with? "abc" "ab")
         (str/ends-with? "abc" "bc") (str/includes? "abc" "b")
         (str/index-of "abc" "c"))                                   ; true true true true 2

;; volatiles, classes, exceptions
(let [v (volatile! 1)] (vreset! v 9) (println @v (vswap! v + 1)))     ; 9 10
(println (boolean nil) (instance? (class (int-array 0)) (int-array 2)))
(println (try (throw (ex-info "boom" {})) (catch Exception e (ex-message e))))

;; a string is a sequence of characters
(println (map int "IHDR") (first "xy") (apply str (reverse "abc")))
