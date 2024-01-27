(import HyREPL.session [Session])
(import HyREPL.ops.eval [InterruptibleEval])
(import uuid [uuid4])
(import io [StringIO])
(import toolz [first])

(defn testing [code expected-result]
  (setv msg {"code" code
             "id" (str (uuid4))})
  (setv session (Session))
  (setv result [])
  (setv writer (fn [x]
                 (nonlocal result)
                 (.append result x))) ; mock writer
  (setv eval-instance  (InterruptibleEval msg session writer))
  (eval-instance.run)
  (print (.format "result: {}" result))
  (assert (= result expected-result)))

(defn test-eval []
  (testing "(print \"Hello, world!\")"
           [{"out" "Hello, world!\n"}
            {"value" "None"
             "ns" "Hy"}
            {"status" ["done"]}])

  (testing "(+ 2 2)"
           [{"value" "4"
             "ns" "Hy"}
            {"status" ["done"]}]))

(defn test-eval-with-exception []
  (setv msg {"code" "(/ 1 0)"
             "id" (str (uuid4))})
  (setv session (Session))
  (setv result [])
  (setv writer (fn [x]
                 (nonlocal result)
                 (.append result x))) ; mock writer
  (setv eval-instance  (InterruptibleEval msg session writer))
  (eval-instance.run)
  (print (.format "result: {}" result))
  (setv eval-error (first (filter (fn [dict] (= (.get dict "status" None) ["eval-error"])) result)))
  (assert (= (get eval-error "status") ["eval-error"]))
  (assert (= (get eval-error "ex") "ZeroDivisionError"))
  (assert (= (get eval-error "root-ex") "ZeroDivisionError")))
