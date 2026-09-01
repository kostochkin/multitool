FROM clfoundation/sbcl:latest

WORKDIR /app

COPY host-header-fix.lisp /app/

# The CloudFront distribution in front of beta.quicklisp.org silently
# stalls any request whose Host header carries the default-port suffix
# (":80"), which quicklisp's client always sends. host-header-fix.lisp
# redefines ql-http:make-request-buffer to emit a clean Host header.
#
# 1. Pre-create /root/quicklisp/dists/ so setup.lisp's auto-install of
#    the default dist is skipped (maybe-initial-setup checks it).
# 2. Install the quicklisp client only (bootstrap fetches work fine).
# 3. Load the Host-header fix.
# 4. Explicitly install the dist — now with the fixed header.
# 5. Quickload systems and save the core: fix + systems baked into the
#    runtime image (fixes both build-time and in-container fetches).
RUN mkdir -p /root/quicklisp/dists \
 && sbcl --non-interactive \
  --eval "(load \"/usr/local/share/common-lisp/source/quicklisp/quicklisp.lisp\")" \
  --eval "(quicklisp-quickstart:install :dist-url nil)" \
  --eval "(load \"/app/host-header-fix.lisp\")" \
  --eval "(ql-dist:install-dist \"http://beta.quicklisp.org/dist/quicklisp.txt\" :prompt nil)" \
  --eval "(mapcar #'ql:quickload '(\"alexandria\" \"fiveam\" \"cl-ppcre\" \"split-sequence\" \"bordeaux-threads\" \"yason\" \"closer-mop\" \"trivial-utf-8\" \"trivial-backtrace\" \"swank\"))" \
  --eval "(sb-ext:save-lisp-and-die \"/app/sbcl-with-systems.core\")"

COPY server.lisp protocol.lisp image.lisp /app/

ENTRYPOINT ["sbcl", "--core", "/app/sbcl-with-systems.core", "--noinform", "--non-interactive", "--eval", "(setf *compile-verbose* nil *compile-print* nil)", "--load", "/app/protocol.lisp", "--load", "/app/image.lisp", "--load", "/app/server.lisp", "--eval", "(multitool-server:start)"]
