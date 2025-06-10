(import sys
        logging
        uuid [uuid4]
        threading [Lock]
        asyncio)
(import HyREPL.bencode [encode])
(import HyREPL.ops.utils [find-op])
(import hyrule [assoc])
(require hyrule [unless])
(import hy.repl)

(setv sessions {})

(defclass Session [object]
  (setv status "")
  (setv eval-id "")
  (setv stdin-id None)
  (setv repl None)
  (setv last-traceback None)
  (setv module None)
  (setv locals None)

  (defn __init__ [self [module hy.repl]]
    (setv self.uuid (str (uuid4)))
    (assoc sessions self.uuid self)
    (setv self.lock (Lock))
    (setv self.module module)
    (setv self.locals module.__dict__)
    (setv self.loop None)
    None)

  (defn __str__ [self]
    self.uuid)

  (defn __repr__ [self]
    self.uuid)

  (defn write [self msg transport]
    (assert (in "id" msg))
    (unless (in "session" msg)
      (assoc msg "session" self.uuid))
    (logging.info "out: %s" msg)
    (setv data (encode msg))
    (try
      (if (hasattr transport "write")
          (do
            (setv loop (or self.loop (asyncio.get-event-loop)))
            (.call-soon-threadsafe loop (fn [] (.write transport data)))
            (.call-soon-threadsafe loop (fn [] (asyncio.create_task (.drain transport))))
            )
          (.sendall transport data))
      (except [e OSError]
        (print (.format "Client gone: {}" e) :file sys.stderr)
        (setv self.status "client_gone"))))

  (defn handle [self msg transport]
    (logging.info "in: %s" msg)
    ((find-op (.get msg "op")) self msg transport)))
