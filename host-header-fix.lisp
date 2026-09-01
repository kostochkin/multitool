;;;; host-header-fix.lisp
;;;;
;;;; Workaround for a server-side quirk: quicklisp's HTTP client appends
;;;; the default-port suffix ":80" to the Host header, and the CloudFront
;;;; distribution in front of beta.quicklisp.org silently stalls (never
;;;; answers) any request whose Host header carries that suffix. Verified
;;;; independently with curl: "Host: beta.quicklisp.org" -> 200,
;;;; "Host: beta.quicklisp.org:80" -> timeout.
;;;;
;;;; This redefines the request builder to emit a spec-clean Host header
;;;; without the port. It is loaded during the image build right after
;;;; the client install and before the dist install, and is saved into
;;;; the runtime core, so both build-time and in-container fetches use it.

(in-package #:ql-http)

(defun make-request-buffer (host port path &key (method "GET"))
  "Return an octet vector suitable for sending as an HTTP 1.1 request.

Redefined from the quicklisp client: the Host header omits the port
suffix (CloudFront in front of beta.quicklisp.org stalls on
\"Host: host:80\"). The port argument is kept for the proxy path
rewriting, which still needs it."
  (setf method (string method))
  (when *proxy-url*
    (setf path (full-proxy-path host port path)))
  (let ((sink (make-instance 'octet-sink)))
    (flet ((add-line (&rest strings)
             (apply #'add-strings sink strings)
             (add-newline sink)))
      (add-line method " " path " HTTP/1.1")
      (add-line "Host: " host)
      (add-line "Connection: close")
      (add-line "User-Agent: " (user-agent-string))
      (add-newline sink)
      (sink-buffer sink))))
