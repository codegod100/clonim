(ns jolt.mvn-http)

;; Compatibility surface for Jolt's small HTTP helper.
(defn fetch* [url path]
  (*http-fetch* url path))
