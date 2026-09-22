(defmacro unless [test then else]
  (list 'if test else then))

(defmacro call-list [& xs]
  (apply list xs))

(defmacro form-and-env [& _]
  (list 'quote (vector &form &env)))

(defmacro nothing [] nil)

(println (unless false :yes :no))
(call-list println "variadic" 3)
(println (form-and-env))
(println (nil? (nothing)))
