(defpackage #:multitool-server
  (:use #:cl)
  (:import-from #:alexandria #:plist-hash-table)
  (:import-from #:multitool-protocol
                #:encode-json
                #:decode-json
                #:read-line-json
                #:write-line-json)
  (:import-from #:multitool-image
                #:introspect
                #:do-apropos
                #:do-describe
                #:do-macroexpand
                #:do-load
                #:do-run-tests)
  (:export #:start))
(in-package #:multitool-server)

;;; Mailbox: thread-safe message passing

(defstruct mailbox
  (items '() :type list)
  (lock (sb-thread:make-mutex))
  (waitqueue (sb-thread:make-waitqueue)))

(defun mailbox-send (mb item)
  (sb-thread:with-mutex ((mailbox-lock mb))
    (setf (mailbox-items mb) (nconc (mailbox-items mb) (list item)))
    (sb-thread:condition-notify (mailbox-waitqueue mb))))

(defun mailbox-recv (mb &key (timeout nil))
  (sb-thread:with-mutex ((mailbox-lock mb))
    (loop until (mailbox-items mb) do
      (let ((result (sb-thread:condition-wait
                     (mailbox-waitqueue mb)
                     (mailbox-lock mb)
                     :timeout timeout)))
        (when (and timeout (not result))
          (return-from mailbox-recv :timeout))))
    (pop (mailbox-items mb))))

;;; Session: tracks a pending eval with condition round-trip

(defstruct session
  (id nil :read-only t)
  (worker->main (make-mailbox) :read-only t)
  (main->worker (make-mailbox) :read-only t))

(defvar *sessions* (make-hash-table :test 'equal))
(defvar *sessions-lock* (sb-thread:make-mutex :name "sessions"))
(defvar *session-counter* 0)

(defun allocate-session ()
  (let* ((id (format nil "w~A" (incf *session-counter*)))
         (session (make-session :id id)))
    (sb-thread:with-mutex (*sessions-lock*)
      (setf (gethash id *sessions*) session))
    session))

(defun find-session (id)
  (sb-thread:with-mutex (*sessions-lock*)
    (gethash id *sessions*)))

(defun remove-session (id)
  (sb-thread:with-mutex (*sessions-lock*)
    (remhash id *sessions*)))

;;; Response building

(defun make-success-response (id values stdout conditions)
  (let ((result (make-hash-table :test 'equal)))
    (setf (gethash "values" result) (coerce values 'vector))
    (setf (gethash "stdout" result) stdout)
    (setf (gethash "conditions" result) (coerce conditions 'vector))
    (plist-hash-table
     (list "id" id
           "ok" t
           "result" result)
     :test 'equal)))

(defun make-error-response (id message)
  (plist-hash-table
   (list "id" id
         "ok" nil
         "error" message)
   :test 'equal))

(defun safe-prin1 (object)
  (handler-case
      (let ((*print-length* 100)
            (*print-level* 10)
            (*print-circle* t)
            (*print-lines* 50)
            (*print-readably* nil))
        (with-output-to-string (s)
          (prin1 object s)))
    (error (e)
      (format nil "#<error printing ~A: ~A>" (type-of object) e))))

(defun report-restart (restart)
  (let ((obj (make-hash-table :test 'equal)))
    (setf (gethash "name" obj) (string (restart-name restart)))
    (setf (gethash "report" obj) (string (restart-name restart)))
    obj))

(defun make-condition-response (id condition restarts thread-id)
  (let ((cond-obj (make-hash-table :test 'equal))
        (restarts-arr (coerce (mapcar #'report-restart restarts) 'vector)))
    (setf (gethash "type" cond-obj) (string (type-of condition)))
    (setf (gethash "message" cond-obj)
          (handler-case (format nil "~A" condition)
            (error () "<unreadable>")))
    (plist-hash-table
     (list "id" id
           "ok" "condition"
           "condition" cond-obj
           "restarts" restarts-arr
           "thread" thread-id)
     :test 'equal)))

;;; Worker: eval with condition capture and restart round-trip

(defun eval-worker (session form)
  (let* ((stdout (make-string-output-stream))
         (*standard-output* stdout)
         (*error-output* stdout)
         (*trace-output* stdout)
         (sb-ext:*invoke-debugger-hook* nil)
         (*debugger-hook*
          (lambda (condition old-hook)
            (declare (ignore old-hook))
            (let ((restarts (compute-restarts condition)))
              (mailbox-send (session-worker->main session)
                            (list :condition condition restarts))
              (let ((msg (mailbox-recv (session-main->worker session)
                                       :timeout 60)))
                (cond
                  ((eq msg :timeout)
                   (let ((r (find 'abort restarts :key #'restart-name)))
                     (when r (invoke-restart r))))
                  ((and (consp msg) (eq (car msg) :restart))
                   (let* ((idx (cadr msg))
                          (restart (nth idx restarts))
                          (value-str (caddr msg)))
                     (cond
                       ((null restart)
                        (error "invalid restart index: ~A" idx))
                       ((member (restart-name restart)
                                '(use-value store-value))
                        (if value-str
                            (invoke-restart restart
                                            (read-from-string value-str))
                            (invoke-restart restart)))
                       (t
                        (invoke-restart restart)))))
                  (t
                   (error "unexpected message: ~A" msg))))))))
    (restart-case
        (let* ((values (multiple-value-list
                        (eval (read-from-string form))))
               (result (list :values (mapcar #'safe-prin1 values)
                             :stdout (get-output-stream-string stdout)
                             :conditions nil)))
          (mailbox-send (session-worker->main session)
                        (list :result result)))
      (abort ()
        :report "Abort evaluation"
        (mailbox-send (session-worker->main session)
                      (list :result (list :values (vector)
                                          :stdout (get-output-stream-string stdout)
                                          :conditions nil)))))))

;;; Method dispatch

(defun dispatch-eval (id params)
  (let ((form (gethash "form" params)))
    (cond
      ((null form)
       (write-line-json (make-error-response id "missing 'form' parameter")
                         *standard-output*))
      (t
       (let* ((session (allocate-session))
              (session-id (session-id session)))
         (sb-thread:make-thread
          (lambda () (eval-worker session form))
          :name session-id)
         (let ((msg (mailbox-recv (session-worker->main session) :timeout 60)))
           (cond
             ((eq msg :timeout)
              (write-line-json (make-error-response id "eval timeout")
                               *standard-output*)
              (remove-session session-id))
             ((and (consp msg) (eq (car msg) :condition))
              (let* ((condition (cadr msg))
                     (restarts (caddr msg)))
                (write-line-json
                 (make-condition-response id condition restarts session-id)
                 *standard-output*)))
             ((and (consp msg) (eq (car msg) :result))
              (let ((result (cadr msg)))
                (write-line-json
                 (make-success-response id
                                        (getf result :values)
                                        (getf result :stdout)
                                        (getf result :conditions))
                 *standard-output*)
                (remove-session session-id)))
             (t
              (write-line-json (make-error-response id "unexpected message")
                               *standard-output*)
              (remove-session session-id)))))))))

(defun dispatch-invoke-restart (id params)
  (let* ((thread-id (gethash "thread" params))
         (index (gethash "index" params))
         (value (gethash "value" params))
         (session (find-session thread-id)))
    (cond
      ((null session)
       (write-line-json (make-error-response id "no such session")
                        *standard-output*))
      (t
       (mailbox-send (session-main->worker session)
                     (list :restart index value))
       (let ((msg (mailbox-recv (session-worker->main session) :timeout 60)))
         (cond
           ((eq msg :timeout)
            (write-line-json (make-error-response id "restart timeout")
                             *standard-output*)
            (remove-session thread-id))
           ((and (consp msg) (eq (car msg) :result))
            (let ((result (cadr msg)))
              (write-line-json
               (make-success-response id
                                      (getf result :values)
                                      (getf result :stdout)
                                      (getf result :conditions))
               *standard-output*)
              (remove-session thread-id)))
           (t
            (write-line-json (make-error-response id "unexpected message")
                             *standard-output*)
            (remove-session thread-id))))))))

(defun dispatch-introspect (id params)
  (handler-case
      (let ((what (gethash "what" params))
            (name (gethash "name" params)))
        (let ((result (introspect what name)))
          (write-line-json
           (plist-hash-table (list "id" id "ok" t "result" result)
                             :test 'equal)
           *standard-output*)))
    (error (e)
      (write-line-json (make-error-response id (format nil "~A" e))
                       *standard-output*))))

(defun dispatch-apropos (id params)
  (handler-case
      (let ((pattern (gethash "pattern" params)))
        (let ((result (do-apropos pattern)))
          (write-line-json
           (plist-hash-table (list "id" id "ok" t "result" result)
                             :test 'equal)
           *standard-output*)))
    (error (e)
      (write-line-json (make-error-response id (format nil "~A" e))
                       *standard-output*))))

(defun dispatch-describe (id params)
  (handler-case
      (let ((name (gethash "name" params)))
        (let ((result (do-describe name)))
          (write-line-json
           (plist-hash-table (list "id" id "ok" t "result" result)
                             :test 'equal)
           *standard-output*)))
    (error (e)
      (write-line-json (make-error-response id (format nil "~A" e))
                       *standard-output*))))

(defun dispatch-macroexpand (id params)
  (handler-case
      (let ((form (gethash "form" params))
            (level (gethash "level" params)))
        (let ((result (do-macroexpand form level)))
          (write-line-json
           (plist-hash-table (list "id" id "ok" t "result" result)
                             :test 'equal)
           *standard-output*)))
    (error (e)
      (write-line-json (make-error-response id (format nil "~A" e))
                       *standard-output*))))

(defun dispatch-load (id params)
  (handler-case
      (let ((target (gethash "target" params)))
        (let ((result (do-load target)))
          (write-line-json
           (plist-hash-table (list "id" id "ok" t "result" result)
                             :test 'equal)
           *standard-output*)))
    (error (e)
      (write-line-json (make-error-response id (format nil "~A" e))
                       *standard-output*))))

(defun dispatch-run-tests (id params)
  (handler-case
      (let ((system (gethash "system" params)))
        (let ((result (do-run-tests system)))
          (write-line-json
           (plist-hash-table (list "id" id "ok" t "result" result)
                             :test 'equal)
           *standard-output*)))
    (error (e)
      (write-line-json (make-error-response id (format nil "~A" e))
                       *standard-output*))))

;;; Main read-loop

(defun handle-request (req)
  (let* ((id (gethash "id" req))
         (method (gethash "method" req))
         (params (or (gethash "params" req) (make-hash-table :test 'equal))))
    (cond
      ((string= method "eval")            (dispatch-eval id params))
      ((string= method "invoke_restart")  (dispatch-invoke-restart id params))
      ((string= method "introspect")      (dispatch-introspect id params))
      ((string= method "apropos")         (dispatch-apropos id params))
      ((string= method "describe")        (dispatch-describe id params))
      ((string= method "macroexpand")    (dispatch-macroexpand id params))
      ((string= method "load")           (dispatch-load id params))
      ((string= method "run_tests")       (dispatch-run-tests id params))
      (t
       (write-line-json
        (make-error-response id (format nil "unknown method: ~A" method))
        *standard-output*)))))

(defvar *swank-port* 4005
  "Port for the swank server (for SLIME/Sly developer access).")

(defun start-swank (&optional (port *swank-port*))
  "Start a swank server in a background thread for SLIME/Sly connections.
Developers can connect via M-x slime-connect RET localhost RET <port>."
  (handler-case
      (progn
        (swank:create-server :port port :dont-close t :style :spawn)
        (format *error-output* "~&; swank server listening on port ~A~%" port))
    (error (e)
      (format *error-output* "~&; failed to start swank: ~A~%" e))))

(defun start (&key (swank t) (swank-port *swank-port*))
  "Start the miniswank server: read JSON-line requests from stdin.
When SWANK is non-nil (default), also start a swank server for developer access."
  (when swank
    (start-swank swank-port))
  (handler-case
      (loop
        for req = (read-line-json *standard-input*)
        while req
        do (handler-case
             (handle-request req)
           (error (e)
             (write-line-json
              (make-error-response
               (or (ignore-errors (gethash "id" req)) "error")
               (format nil "~A" e))
              *standard-output*))))
    (end-of-file ()
      nil)))
