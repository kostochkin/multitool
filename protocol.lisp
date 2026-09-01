(defpackage #:multitool-protocol
  (:use #:cl)
  (:import-from #:alexandria #:plist-hash-table)
  (:export #:encode-json
           #:decode-json
           #:read-line-json
           #:write-line-json))
(in-package #:multitool-protocol)

(defun encode-json (object)
  "Encode OBJECT as a compact JSON string."
  (with-output-to-string (s)
    (yason:encode object s)))

(defun decode-json (string)
  "Decode a JSON string. Returns hash-table with string keys for objects."
  (yason:parse string :object-as :hash-table))

(defun read-line-json (stream)
  "Read a line from STREAM and parse as JSON. Returns nil on EOF."
  (let ((line (read-line stream nil nil)))
    (when line
      (decode-json line))))

(defun write-line-json (object stream)
  "Encode OBJECT as JSON and write as a single line to STREAM."
  (write-line (encode-json object) stream)
  (force-output stream))
