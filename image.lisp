(defpackage #:multitool-image
  (:use #:cl)
  (:import-from #:alexandria #:plist-hash-table)
  (:export #:introspect
           #:do-apropos
           #:do-describe
           #:do-macroexpand
           #:do-load
           #:do-run-tests
           #:get-arglist
           #:safe-prin1))
(in-package #:multitool-image)

;;; Utilities

(defun safe-prin1 (object)
  (handler-case
      (let ((*print-length* 100)
            (*print-level* 10)
            (*print-circle* t)
            (*print-lines* 50)
            (*print-pretty* nil)
            (*print-readably* nil))
        (with-output-to-string (s)
          (prin1 object s)))
    (error (e)
      (format nil "#<error printing ~A: ~A>" (type-of object) e))))

(defun resolve-symbol (name)
  "Resolve a symbol name like 'CL:LIST' or 'ALEXANDRIA:PLIST-HASH-TABLE'.
Returns the symbol or nil."
  (when name
    (handler-case
        (let* ((colon-pos (position #\: name))
               (pkg (if colon-pos
                        (subseq name 0 colon-pos)
                        "KEYWORD"))
               (sym (if colon-pos
                        (subseq name (1+ colon-pos))
                        name))
               (package (find-package pkg)))
          (when package
            (multiple-value-bind (symbol status)
                (find-symbol sym package)
              (declare (ignore status))
              symbol)))
      (error () nil))))

(defun get-arglist (symbol)
  "Get the arglist of a function. Returns a string or nil."
  (when (fboundp symbol)
    (handler-case
        (let ((f (symbol-function symbol)))
          (cond
            ((typep f 'generic-function)
             (let ((ll (closer-mop:generic-function-lambda-list f)))
               (when ll (safe-prin1 ll))))
            (t nil)))
      (error () nil))))

;;; Introspection

(defun introspect (what name)
  "Introspect the Lisp image. Returns a hash-table suitable for JSON encoding."
  (cond
    ((string= what "packages")
     (let ((pkgs '()))
       (do-all-symbols (s)
         (pushnew (package-name (symbol-package s)) pkgs :test #'string=))
       (coerce (sort pkgs #'string<) 'vector)))

    ((string= what "symbols")
     (let ((pkg (find-package name)))
       (if pkg
           (let ((symbols '()))
             (do-external-symbols (s pkg)
               (push (safe-prin1 s) symbols))
             (coerce (sort symbols #'string<) 'vector))
           (error "package not found: ~A" name))))

    ((string= what "symbol")
     (let ((sym (resolve-symbol name)))
       (if sym
           (let ((result (make-hash-table :test 'equal)))
             (setf (gethash "name" result) (safe-prin1 sym))
             (setf (gethash "package" result) (package-name (symbol-package sym)))
             (setf (gethash "boundp" result) (and (boundp sym) t))
             (setf (gethash "fboundp" result) (and (fboundp sym) t))
             (setf (gethash "constantp" result) (and (constantp sym) t))
             (setf (gethash "specialp" result) nil)
             (when (fboundp sym)
               (setf (gethash "arglist" result) (get-arglist sym))
               (setf (gethash "type" result)
                     (let ((f (symbol-function sym)))
                       (cond
                         ((typep f 'generic-function) "generic-function")
                         ((typep f 'compiled-function) "compiled-function")
                         (t "function"))))
               (setf (gethash "macro" result) (and (macro-function sym) t))
               (setf (gethash "documentation" result)
                     (documentation sym 'function)))
             (when (and (boundp sym) (not (constantp sym)))
               (setf (gethash "value" result) (safe-prin1 (symbol-value sym)))
               (setf (gethash "variable-documentation" result)
                     (documentation sym 'variable)))
             result)
           (error "symbol not found: ~A" name))))

    ((string= what "class")
     (let ((sym (resolve-symbol name)))
       (if (and sym (find-class sym nil))
           (let ((class (find-class sym))
                 (result (make-hash-table :test 'equal)))
             (setf (gethash "name" result) (safe-prin1 (cl:class-name class)))
             (setf (gethash "superclasses" result)
                   (coerce (mapcar (lambda (c) (safe-prin1 (cl:class-name c)))
                                   (closer-mop:class-direct-superclasses class))
                           'vector))
             (setf (gethash "subclasses" result)
                   (coerce (mapcar (lambda (c) (safe-prin1 (cl:class-name c)))
                                   (closer-mop:class-direct-subclasses class))
                           'vector))
             (setf (gethash "slots" result)
                   (coerce (mapcar (lambda (slot)
                                     (let ((obj (make-hash-table :test 'equal)))
                                       (setf (gethash "name" obj)
                                             (safe-prin1 (closer-mop:slot-definition-name slot)))
                                       (setf (gethash "allocation" obj)
                                             (string (closer-mop:slot-definition-allocation slot)))
                                       obj))
                                   (closer-mop:class-direct-slots class))
                           'vector))
             (setf (gethash "documentation" result)
                   (documentation class t))
             result)
           (error "class not found: ~A" name))))

    (t
     (error "unknown introspect type: ~A" what))))

;;; Apropos

(defun do-apropos (pattern)
  "Search for symbols matching PATTERN (case-insensitive substring)."
  (let ((results '()))
    (do-all-symbols (s)
      (let ((name (symbol-name s)))
        (when (search pattern name :test #'char-equal)
          (pushnew
           (let ((obj (make-hash-table :test 'equal)))
             (setf (gethash "name" obj) (safe-prin1 s))
             (setf (gethash "package" obj) (package-name (symbol-package s)))
             (setf (gethash "boundp" obj) (and (boundp s) t))
             (setf (gethash "fboundp" obj) (and (fboundp s) t))
             obj)
           results :test (lambda (a b)
                           (string= (gethash "name" a) (gethash "name" b)))))))
    (coerce (nreverse results) 'vector)))

;;; Describe

(defun do-describe (name)
  "Describe a symbol. Returns a string."
  (let ((sym (resolve-symbol name)))
    (if sym
        (with-output-to-string (s)
          (describe sym s))
        (error "symbol not found: ~A" name))))

;;; Macroexpand

(defun do-macroexpand (form level)
  "Macroexpand FORM. LEVEL 1 = macroexpand-1, else full macroexpand.
Returns a hash-table with 'expanded' and 'changed'."
  (let ((form-obj (read-from-string form)))
    (multiple-value-bind (expanded changed)
        (if (and level (= level 1))
            (macroexpand-1 form-obj)
            (macroexpand form-obj))
      (let ((obj (make-hash-table :test 'equal)))
        (setf (gethash "expanded" obj) (safe-prin1 expanded))
        (setf (gethash "changed" obj) (and changed t))
        obj))))

;;; Load

(defun do-load (target)
  "Load a Lisp file or ASDF system. Returns a hash-table with 'success' and 'stdout'."
  (let ((stdout (make-string-output-stream)))
    (let ((*standard-output* stdout)
          (*error-output* stdout)
          (*load-verbose* nil)
          (*compile-verbose* nil)
          (*compile-print* nil))
      (handler-case
          (cond
            ((and (>= (length target) 5)
                  (string= (subseq target (- (length target) 5)) ".lisp"))
             (load target))
            ((and (>= (length target) 4)
                  (string= (subseq target (- (length target) 4)) ".asd"))
             (load target))
            (t
             (asdf:load-system (intern (string-upcase target) :keyword))))
        (error (e)
          (return-from do-load
            (let ((obj (make-hash-table :test 'equal)))
              (setf (gethash "success" obj) nil)
              (setf (gethash "error" obj) (format nil "~A" e))
              (setf (gethash "stdout" obj) (get-output-stream-string stdout))
              obj)))))
    (let ((obj (make-hash-table :test 'equal)))
      (setf (gethash "success" obj) t)
      (setf (gethash "stdout" obj) (get-output-stream-string stdout))
      obj)))

;;; Run tests (FiveAM)

(defun do-run-tests (system)
  "Run FiveAM tests for a system. Returns a hash-table with results."
  (let ((stdout (make-string-output-stream)))
    (let ((*standard-output* stdout)
          (*error-output* stdout)
          (*trace-output* stdout))
      (handler-case
          (progn
            (when system
              (asdf:load-system (intern (string-upcase system) :keyword)))
            (fiveam:run-all-tests)
            (let ((obj (make-hash-table :test 'equal)))
              (setf (gethash "success" obj) t)
              (setf (gethash "stdout" obj) (get-output-stream-string stdout))
              obj))
        (error (e)
          (let ((obj (make-hash-table :test 'equal)))
            (setf (gethash "success" obj) nil)
            (setf (gethash "error" obj) (format nil "~A" e))
            (setf (gethash "stdout" obj) (get-output-stream-string stdout))
            obj))))))
