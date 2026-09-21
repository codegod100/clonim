(ns bitops)

(println (bit-and 12 10) (bit-or 12 10) (bit-xor 12 10))   ; 8 14 6
(println (bit-and-not 12 10) (bit-not 0) (bit-not 5))      ; 4 -1 -6
(println (bit-and 255 170 15) (bit-or 1 2 4) (bit-xor 1 2 4)) ; variadic: 10 7 7
(println (bit-shift-left 1 10) (bit-shift-right 1024 3))   ; 1024 128
(println (bit-shift-right -8 1) (unsigned-bit-shift-right -1 60)) ; -4 15
(println (bit-test 5 0) (bit-test 5 1))                    ; true false
(println (bit-set 0 4) (bit-clear 31 0) (bit-flip 5 1))    ; 16 30 7
(println (reduce bit-xor [1 2 4 8]))                       ; as a value: 15
