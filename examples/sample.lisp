;;;; examples/sample.lisp — loaded by the lisp_load example in SKILL.md
(defun greet (name)
  (format nil "Hello, ~A!" name))

(fiveam:test greet-test
  "greet returns a greeting"
  (fiveam:is (string= "Hello, world!" (greet "world"))))
