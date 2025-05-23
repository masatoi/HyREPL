(import
  sys
  threading
  time
  logging
  socketserver [ThreadingMixIn TCPServer BaseRequestHandler]
  HyREPL.session [sessions Session]
  HyREPL.bencode [decode]
  toolz [last])

;; TODO: move these includes somewhere else
;; (import HyREPL.ops [eval complete info])
(import HyREPL.ops)

(import hyrule [inc])
(require hyrule [defmain])

(defclass ReplServer [TCPServer ThreadingMixIn]
  (setv allow-reuse-address True))

(defclass ReplRequestHandler [BaseRequestHandler]
  (setv session None)
  (defn handle [self]
    (print "New client" :file sys.stderr)
    (let [buf (bytearray)
          tmp None
          msg #()]
      (while True
        (try
          (setv tmp (.recv self.request 1024))
          (except [e OSError]
            (break)))
        (when (= (len tmp) 0)
          (break))
        (.extend buf tmp)
        (try
          (do
            (setv m (decode buf))
            (.clear buf)
            (.extend buf (get m 1)))
          (except [e Exception]
            (print e :file sys.stderr)
            (continue)))

        (logging.debug "message=%s" m)
        (setv req (get m 0))
        (setv sid (.get req "session"))

        ;; Create session if not exist
        (when (is self.session None)
          (setv self.session (.get sessions sid))
          (when (is self.session None)
            (logging.debug "session not found and created: finding session id=%s" sid)
            (setv self.session (Session))))

        ;; Switch requested session
        (when (and sid (not (= self.session.uuid sid)))
          (setv self.session (.get sessions sid)))

        (self.session.handle req self.request))
      (print "Client gone" :file sys.stderr))))

(defn start-server [[ip "127.0.0.1"] [port 7888]]
  (let [s (ReplServer #(ip port) ReplRequestHandler)
        t (threading.Thread :target s.serve-forever)]
    (setv t.daemon True)
    (.start t)
    #(t s)))

(defmain [#* args]

  ;; Show usage
  (when (or (in "-h" args)
            (in "--help" args))
    (print "Usage:
  hyrepl [-d | --debug] [-h | --help] [<port>]

Options:
  -h, --help      Show this usage
  -d, --debug     Debug mode (true/false) [default: false]
  <port>          Port number [default: 7888]")
    (return 0))

  ;; Settings for logging
  (logging.basicConfig
    :level (if (or (in "-d" args)
                   (in "--debug" args))
               logging.DEBUG
               logging.WARNING)
    :format "%(levelname)s:%(module)s: %(message)s (at %(filename)s:%(lineno)d in %(funcName)s)")

  (logging.debug "Starting hyrepl: args=%s" args)

  (setv port
        (if (> (len args) 0)
            (try
              (int (last args))
              (except [_ ValueError]
                7888))
            7888))
  (while True
    (try
       (start-server "127.0.0.1" port)
       (except [e OSError]
         (setv port (inc port)))
       (else
         (print (.format "Listening on {}" port) :file sys.stderr)
         (while True
           (time.sleep 1))))))
