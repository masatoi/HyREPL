;; Import necessary modules and functions
(import toolz [first second]
        pytest
        socket
        subprocess
        time
        uuid [uuid4]
        hyrule [assoc]
        threading)
(import HyREPL.bencode [encode decode])
(require hyrule [unless])

;;; --- nREPL Client ---

(defclass NreplClient []
  (defn __init__ [self host port sock [timeout 5]]
    (setv self.host host
          self.port port
          self.timeout timeout
          self.socket sock
          self.buffer (bytearray))
    (print f"NreplClient connected to {host}:{port}"))

  (defn close [self]
    (when self.socket
      (print "Closing NreplClient connection.")
      (self.socket.close)
      (setv self.socket None)))

  (defn send [self op [params None] [msg-id (str (uuid4))]]
    (unless self.socket (raise (RuntimeError "Socket is not connected")))
    (let [base-request {"op" op "id" msg-id}
          request (if params {#** base-request #** params} base-request)
          encoded-request (encode request)]
      (print f"Sending: {request}")
      (try
        (.sendall self.socket encoded-request)
        (except [e OSError]
          (print f"Error sending request: {e}")
          (self.close)))))

  (defn receive [self [timeout None]]
    "Receives and decodes a single nREPL response, maintaining buffer state."
    (unless self.socket (raise (RuntimeError "Socket is not connected")))
    (setv timeout (or timeout self.timeout))
    (.settimeout self.socket timeout)
    (setv start-time (time.time))

    (while True ; Loop until one message can be decoded
      ;; 1. first try to decode from existing instance buffer
      (when (> (len self.buffer) 0)
        (try
          (let [[decoded-msg remaining-buffer] (decode (bytes self.buffer))]
            (print f"Received (from buffer): {decoded-msg}")
            (setv self.buffer (bytearray remaining-buffer))
            (return decoded-msg)) ; Decode succeeded, message returned
          (except [e ValueError]
            (print f"Incomplete data in buffer (len={(len self.buffer)}), need more data...")
            ;; Proceed to recv without breaking because of insufficient data
            None)
          (except [e Exception]
            (print f"Error decoding response from buffer: {e}")
            (.clear self.buffer)
            (return None))))

      ;; 2. timeout check
      (when (>= (- (time.time) start-time) timeout)
        (print f"No complete response received within timeout.")
        (return None))

      ;; 3. could not decode from buffer or received if buffer is empty
      (try
        (let [chunk (.recv self.socket 4096)]
          (unless chunk
            (print "Connection closed by server (received empty bytes).")
            (self.close)
            (return None))
          (print f"Received {(len chunk)} bytes from socket.")
          (.extend self.buffer chunk))
        (except [e socket.timeout]
          (print "Socket timeout during recv.")
          None)
        (except [e OSError]
          (print f"Socket error: {e}")
          (self.close)
          (return None))))
    (print "Exited receive loop unexpectedly.")
    (return None))

  (defn __enter__ [self] self)
  (defn __exit__ [self exc-type exc-val exc-tb] (self.close)))

(defn find-free-port []
  (with [s (socket.socket socket.AF_INET socket.SOCK_STREAM)]
    (s.bind #("" 0))
    (get (s.getsockname) 1)))

;;; --- Fixtures ---

(setv SERVER-STARTUP-TIMEOUT 5)

(defn [(pytest.fixture :scope "function")]
  hyrepl-server []
  "Fixture that starts the HyREPL server and provides client connection information"

  (let [host "127.0.0.1"
        port (find-free-port)
        command ["hy" "-m" "HyREPL.server" "--debug" (str port)]
        server-process (do (print f"Starting server:" (.join " " command))
                           (subprocess.Popen command
                                             :stdout subprocess.PIPE
                                             :stderr subprocess.PIPE))
        client-socket None]
    (time.sleep 1) ; Wait starting server
    (try
      (setv client-socket (socket.create-connection #(host port)
                                                    :timeout SERVER-STARTUP-TIMEOUT))
      (except [e Exception]
        (let [[stdout stderr] (server-process.communicate)]
          (print "Server stdout:\n" (stdout.decode :errors "ignore"))
          (print "Server stderr:\n" (stderr.decode :errors "ignore"))
          (server-process.terminate)
          (server-process.wait)
          (pytest.fail f"Failed to connect to server at {host}:{port}: {e}")
          (return))))

    (print f"Server started on port {port}, client connected.")

    (yield {"host" host
            "port" port
            "socket" client-socket
            "process" server-process})

    (print "Tearing down server ...")
    (client-socket.close)
    (server-process.terminate)

    (try
      (let [[stdout stderr] (server-process.communicate :timeout 5)]
        (print "Server stdout when cleanup:\n" (stdout.decode :errors "ignore"))
        (print "Server stderr when cleanup:\n" (stderr.decode :errors "ignore")))
      (except [e subprocess.TimeoutExpired]
        (server-process.kill)
        (let [[stdout stderr] (server-process.communicate)]
          (print "Server stdout after kill:\n" (stdout.decode :errors "ignore"))
          (print "Server stderr after kill:\n" (stderr.decode :errors "ignore")))))))

(defn [(pytest.fixture :scope "function")]
  nrepl-client [hyrepl-server]
  "Provides an NreplClient instance connected to the running server."
  (let [host (get hyrepl-server "host")
        port (get hyrepl-server "port")
        sock (get hyrepl-server "socket")]
    (with [client (NreplClient host port sock)]
      (yield client))))

;;; --- Tests ---

(defn test-describe [nrepl-client]
  (let [msg-id (str (uuid4))]
    (nrepl-client.send "describe" :params {} :msg-id msg-id)
    (let [response (nrepl-client.receive)]
      (assert (= (get response "id") msg-id))
      (print f"Describe response: {response}")
      (assert response)
      (assert (in "ops" response))
      (assert (in "done" (get response "status")))
      (assert (= (set (.keys (get response "ops")))
                 #{"clone" "close" "completions" "describe" "eval" "interrupt"
                   "load-file" "lookup" "ls-sessions" "stdin"})))))

(defn test-clone [nrepl-client]
  (nrepl-client.send "clone" :params {})
  (let [response (nrepl-client.receive)
        statuses (get response "status")]
    (assert (get response "new-session"))
    (assert (= (get statuses 0) "done"))))

(defn test-multiple-sessions [nrepl-client]
  (let [response1 (do (nrepl-client.send "clone" :params {})
                      (nrepl-client.receive))
        session1 (get response1 "new-session")
        response2 (do (nrepl-client.send "clone" :params {})
                      (nrepl-client.receive))
        session2 (get response2 "new-session")]

    (print f"session1: {session1}")
    (print f"session2: {session2}")

    (let [msg-id (str (uuid4))]
      (nrepl-client.send "eval" :params {"code" "(+ 1 1)" "session" session1}
                         :msg-id msg-id)
      (let [response3 (nrepl-client.receive)
            response4 (nrepl-client.receive)]
        (print "response3:" response3)
        (print "response4:" response4)
        ;; Confirm match of msg-id
        (assert (= (get response3 "id")
                   (get response4 "id")
                   msg-id))
        ;; Confirm session id
        (assert (= (get response3 "session")
                   (get response4 "session")
                   session1))
        (assert (= (get response3 "value") "2"))
        (assert (= (len (get response4 "status")) 1))
        (assert (= (get (get response4 "status") 0) "done"))))

    (let [msg-id (str (uuid4))]
      (nrepl-client.send "eval" :params {"code" "(* 2 3)" "session" session2}
                         :msg-id msg-id)
      (let [response5 (nrepl-client.receive)
            response6 (nrepl-client.receive)]
        (print "response5:" response5)
        (print "response6:" response6)
        ;; Confirm match of msg-id
        (assert (= (get response5 "id")
                   (get response6 "id")
                   msg-id))
        ;; Confirm session id
        (assert (= (get response5 "session")
                   (get response6 "session")
                   session2))
        (assert (= (get response5 "value") "6"))
        (assert (= (len (get response6 "status")) 1))
        (assert (= (get (get response6 "status") 0) "done"))))

    ;; List Sessions
    (nrepl-client.send "ls-sessions" :params {})
    (let [response7 (nrepl-client.receive)]
      (print "ls-sessions response:" response7)
      (print "left:" (set (get response7 "sessions")))
      (print "session1:" session1)
      (print "session2:" session2)
      (print "ls-sessions-session:" (get response7 "session"))
      (assert (.issubset #{session1 session2}
                         (set (get response7 "sessions"))))
      (assert (= (len (get response7 "status")) 1))
      (assert (= (get (get response7 "status") 0) "done")))

    ;; Close session
    (nrepl-client.send "close" :params {"session" session1})
    (let [res (nrepl-client.receive)]
      (print "close response:" res)
      (nrepl-client.send "ls-sessions" :params {})
      (let [res (nrepl-client.receive)]
        (print "ls-sessions response:" res)
        (assert (not (in session1 (get res "sessions"))))))))

(defn test-session-isolation [nrepl-client]
  (let [resp1 (do (nrepl-client.send "clone" :params {})
                  (nrepl-client.receive))
        session1 (get resp1 "new-session")
        resp2 (do (nrepl-client.send "clone" :params {})
                  (nrepl-client.receive))
        session2 (get resp2 "new-session")]

    ;; Define a function only in session1
    (nrepl-client.send "eval"
                       :params {"code" "(defn foo [] 42)" "session" session1})
    ;; Ignore the value and done responses
    (nrepl-client.receive)
    (nrepl-client.receive)

    ;; Ensure the function works in session1
    (let [msg-id (str (uuid4))]
      (nrepl-client.send "eval"
                         :params {"code" "(foo)" "session" session1}
                         :msg-id msg-id)
      (let [res1 (nrepl-client.receive)
            res2 (nrepl-client.receive)]
        (assert (= (get res1 "id") msg-id))
        (assert (= (get res1 "value") "42"))
        (assert (= (get (get res2 "status") 0) "done"))))

    ;; Try calling the function from session2 and expect an eval-error
    (let [msg-id (str (uuid4))]
      (nrepl-client.send "eval"
                         :params {"code" "(foo)" "session" session2}
                         :msg-id msg-id)
      (let [err1 (nrepl-client.receive)
            err2 (nrepl-client.receive)
            done (nrepl-client.receive)]
        (assert (= (get err1 "id") msg-id))
        (assert (in "eval-error" (get err1 "status")))
        (assert (= (get (get done "status") 0) "done"))))))

(defn test-interrupt-long-running-eval [nrepl-client]
  ;; Create a session first
  (nrepl-client.send "clone" :params {})
  (let [clone-res (nrepl-client.receive)
        session-id (get clone-res "new-session")
        eval-id (str (uuid4))
        code "(import time) (time.sleep 5) 42"]

    ;; Start long running eval
    (nrepl-client.send "eval" :params {"code" code "session" session-id}
                       :msg-id eval-id)
    (time.sleep 0.5)

    ;; Interrupt it
    (let [interrupt-id (str (uuid4))]
      (nrepl-client.send "interrupt"
                         :params {"interrupt-id" eval-id "session" session-id}
                         :msg-id interrupt-id)

      (let [resp1 (nrepl-client.receive)
            resp2 (nrepl-client.receive)
            msgs [resp1 resp2]
            interrupt-res (first (filter (fn [m] (= (get m "id") eval-id)) msgs))
            done-res (first (filter (fn [m] (= (get m "id") interrupt-id)) msgs))]
          (print "interrupt-res:" interrupt-res)
          (print "done-res:" done-res)
        (assert (in "interrupted" (get interrupt-res "status")))
        (assert (in "done" (get interrupt-res "status")))
        (assert (= (get done-res "status") ["done"]))))))

(defn test-eval-with-stdin-interaction [nrepl-client]
  ;; Create a session for the interaction
  (nrepl-client.send "clone" :params {})
  (let [clone-res (nrepl-client.receive)
        session-id (get clone-res "new-session")
        eval-id (str (uuid4))]

    ;; Send eval that waits for input
    (nrepl-client.send "eval"
                       :params {"code" "(input \"Name?: \")" "session" session-id}
                       :msg-id eval-id)

    ;; Expect prompt and need-input status
    (let [prompt (nrepl-client.receive)
          need-input (nrepl-client.receive)]
      (assert (in "Name?: " (.get prompt "out" "")))
      (assert (in "need-input" (.get need-input "status")))

      ;; Respond with stdin using same id
      (nrepl-client.send "stdin" :params {"stdin" "HyREPL\n"} :msg-id eval-id)

      (let [value-msg (nrepl-client.receive)
            done-msg (nrepl-client.receive)]
        (assert (= (get value-msg "value") "\"HyREPL\""))
        (assert (= (get done-msg "status") ["done"]))))))



(defn test-multiple-clients-concurrent-eval [hyrepl-server]
  (let [host (get hyrepl-server "host")
        port (get hyrepl-server "port")
        base-sock (get hyrepl-server "socket")
        results {}]

    (setv run-client
          (fn [code key sock]
            (with [client (NreplClient host port sock)]
              (client.send "clone" :params {} :msg-id (str (uuid4)))
              (let [clone-res (client.receive)
                    session-id (get clone-res "new-session")
                    msg-id (str (uuid4))]
                (client.send "eval"
                             :params {"code" code "session" session-id}
                             :msg-id msg-id)
                (let [resp1 (client.receive)
                      resp2 (client.receive)
                      value-msg (if (get resp1 "value") resp1 resp2)
                      done-msg (if (get resp1 "value") resp2 resp1)]
                  (assoc results key {"session" session-id
                                      "value" (get value-msg "value")})
                  (assert (= (get done-msg "status") ["done"])))))))

    (let [sock2 (socket.create-connection #(host port)
                                         :timeout SERVER-STARTUP-TIMEOUT)
          t1 (threading.Thread :target run-client
                               :args ["(+ 1 2)" "c1" base-sock])
          t2 (threading.Thread :target run-client
                               :args ["(* 3 4)" "c2" sock2])]
      (.start t1)
      (.start t2)
      (.join t1)
      (.join t2)
      (sock2.close))

    (let [res1 (get results "c1")
          res2 (get results "c2")]
      (assert res1)
      (assert res2)
      (assert (!= (get res1 "session") (get res2 "session")))
      (assert (= (get res1 "value") "3"))
      (assert (= (get res2 "value") "12"))
    )))
