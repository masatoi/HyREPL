(import logging)
(import toolz [first second])
(import hyrule [inc assoc])

(defreader b
  (setv expr (.parse-one-form &reader))
  `(bytes ~expr "utf-8"))

(defn decode-multiple [thing]
  "Uses `decode` to decode all encoded values in `thing`."
  (let [r [] i #() t thing]
    (while (> (len t) 0)
      (setv i (decode t))
      (.append r (first i))
      (setv t (second i)))
    r))

(defn decode [thing]
  "Decodes `thing` and returns the first parsed bencode value encountered
as well as the unparsed rest"
  ;; (logging.debug "bencode.decode: thing= %s" thing)
  (cond (.startswith thing #b"d")
        (decode-dict (cut thing 1 None))

        (.startswith thing #b"l")
        (decode-list (cut thing 1 None))

        (.startswith thing #b"i")
        (decode-int (cut thing 1 None))

        True ; assume string
        (let [delim (.find thing #b":")
              size (int (.decode (cut thing 0 delim) "utf-8"))]
          #((.decode (cut thing (inc delim) (+ size (inc delim))) "utf-8") ; token
             (cut thing (+ size (inc delim)) None) ; rest
            ))))

(defn decode-int [thing]
  (let [end (.find thing #b"e")]
    #((int (cut thing 0 end) 10)
       (cut thing (inc end) None))))

(defn decode-list [thing]
  (let [rv []
        i #()
        t thing]
    (while (> (len t) 0)
      (setv i (decode t))
      (.append rv (first i))
      (setv t (second i))
      (when (.startswith t #b"e")
        (break)))
    (when (= (len t) 0)
      (raise (ValueError "List without end marker")))
    #(rv (cut t 1 None))))

(defn decode-dict [thing]
  (let [result {}
        key #()
        val #()]
    (while (> (len thing) 0)
      (when (.startswith thing #b"e")
        (break))
      (setv key (decode thing)) ; #(key rest)
      (setv val (decode (second key)))
      (setv thing (second val))
      (assoc result (first key) (first val)))
    (when (= (len thing) 0)
      (raise (ValueError "Dictionary without end marker")))
    #(result (cut thing 1 None))))

(defn encode [thing]
  "Returns a bencoded string that represents `thing`. Might throw all sorts
of exceptions if you try to encode weird things. Don't do that."
  (cond (isinstance thing int)
        (encode-int thing)

        (isinstance thing str)
        (encode-str thing)

        (isinstance thing bytes)
        (encode-bytes thing)

        (isinstance thing dict)
        (encode-dict thing)

        (is thing None)
        (encode-bytes #b"")

        True ; assume iterable
        (encode-list thing)))

(defn encode-int [thing]
  #b(.format "i{}e" thing))

(defn encode-str [thing]
  #b(.format "{}:{}" (len #b thing) thing))

(defn encode-bytes [thing]
  #b(.format "{}:{}" (len thing) (.decode thing "utf-8")))

(defn encode-dict [thing]
  (let [rv (bytearray #b"d")]
    (for [i (.items thing)]
      (.extend rv (encode (first i)))
      (.extend rv (encode (second i))))
    (.extend rv #b"e")
    (bytes rv)))

(defn encode-list [thing]
  (let [rv (bytearray #b"l")]
    (for [i thing]
      (.extend rv (encode i)))
    (.extend rv #b"e")
    (bytes rv)))
