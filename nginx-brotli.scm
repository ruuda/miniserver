;; Miniserver -- Nginx and Acme-client on CoreOS.
;; Copyright 2018 Ruud van Asseldonk

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License version 3. A copy
;; of the License is available in the root of the repository.

(define-module (nginx-brotli)
  #:use-module ((guix licenses) #:prefix l:)
  #:use-module (guix build-system trivial)
  #:use-module (guix git-download)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages pcre)
  #:use-module (gnu packages tls)
  #:use-module (gnu packages version-control)
  #:use-module (gnu packages web))

(define-public nginx-module-brotli
  (package
    (name "nginx-module-brotli")
    (version "1.0.2")
    (source
      (origin
        (method git-fetch)
        (uri (git-reference
          (url "https://github.com/google/ngx_brotli")
          (commit "bfd2885b2da4d763fed18f49216bb935223cd34b")
          (recursive? #t)))
        (sha256
          (base32 "04yx1n0wi3l2x37jd1ynl9951qxkn8xp42yv0mfp1qz9svips81n"))
        (file-name (string-append "nginx-module-brotli-" version "-checkout"))))
    (build-system trivial-build-system)
    (arguments
      `(#:modules ((guix build utils))
        ;; Do nothing -- this package exists solely
        ;; to obtain the ngx_brotli source.
        #:builder (begin (use-modules (guix build utils)))))
    (synopsis "NGINX module for Brotli compression")
    (description "NGINX module for Brotli compression")
    (license l:bsd-2)
    (home-page "https://github.com/google/ngx_brotli")))

;; The following package definition is inspired by the upstream Nginx package
;; in the Guix repository at https://git.savannah.gnu.org/cgit/guix.git. The
;; upstream package is defined in //gnu/packages/web.scm, and that file is
;; licensed under that GNU General Public License version 3, or at your option,
;; any later version.

;; It would be great if we could simplify this further, to only adapt the build
;; step that really needs to change (passing --add-module=ngx_brotli to
;; configure).
(define-public nginx-brotli
  (package
    (inherit nginx)
    (name "nginx-brotli")
    (version "1.0.0")
    (inputs `(("nginx-module-brotli", (package-source nginx-module-brotli))
              ("pcre", pcre)
              ("openssl", openssl)
              ("zlib", zlib)))
    (arguments
     `(#:tests? #f                      ; no test target
       #:phases
       (modify-phases %standard-phases
         (add-before 'configure 'patch-/bin/sh
           (lambda _
             (substitute* "auto/feature"
               (("/bin/sh") (which "sh")))
             #t))
         ;; Copy the ngx_brotli source into the working directory, because Nginx
         ;; embeds its configure command line in the binary, and if the path of
         ;; the Brotli module in the store is passed, Guix detects the dependency
         ;; as a runtime dependency, because the binary contains the path.
         (add-before 'configure 'copy-nginx-module-brotli
           (lambda _
             (copy-recursively (assoc-ref %build-inputs "nginx-module-brotli") "ngx_brotli")))
         (replace 'configure
           (lambda* (#:key outputs #:allow-other-keys)
             (let ((flags
                    (list (string-append "--prefix=" (assoc-ref outputs "out"))
                          "--with-http_ssl_module"
                          "--with-http_v2_module"
                          "--with-http_gzip_static_module"
                          "--add-module=ngx_brotli"
                          "--with-pcre-jit"
                          ;; Even when not cross-building, we pass the
                          ;; --crossbuild option to avoid customizing for the
                          ;; kernel version on the build machine.
                          ,(let ((system "Linux")    ; uname -s
                                 (release "2.6.32")  ; uname -r
                                 ;; uname -m
                                 (machine "x86_64" ))
                             (string-append "--crossbuild="
                               system ":" release ":" machine)))))
               (setenv "CC" "gcc")
               (format #t "environment variable `CC' set to `gcc'~%")
               (format #t "configure flags: ~s~%" flags)
               (apply invoke "./configure" flags)
               #t)))
         (add-after 'install 'install-man-page
           (lambda* (#:key outputs #:allow-other-keys)
             (let* ((out (assoc-ref outputs "out"))
                    (man (string-append out "/share/man")))
               (install-file "objs/nginx.8" (string-append man "/man8"))
               #t)))
         (add-after 'install 'fix-root-dirs
           (lambda* (#:key outputs #:allow-other-keys)
             ;; 'make install' puts things in strange places, so we need to
             ;; clean it up ourselves.
             (let* ((out (assoc-ref outputs "out"))
                    (share (string-append out "/share/nginx")))
               ;; This directory is empty, so get rid of it.
               (rmdir (string-append out "/logs"))
               ;; Example configuration and HTML files belong in
               ;; /share.
               (mkdir-p share)
               (rename-file (string-append out "/conf")
                            (string-append share "/conf"))
               (rename-file (string-append out "/html")
                            (string-append share "/html"))
               #t))))))))
