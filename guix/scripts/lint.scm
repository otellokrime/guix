;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2014 Cyril Roelandt <tipecaml@gmail.com>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (guix scripts lint)
  #:use-module (guix base32)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (guix ui)
  #:use-module (guix utils)
  #:use-module (gnu packages)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-37)
  #:export (guix-lint
            check-description-style
            check-inputs-should-be-native
            check-patches
            check-synopsis-style))


;;;
;;; Command-line options.
;;;

(define %default-options
  ;; Alist of default option values.
  '())

(define (show-help)
  (display (_ "Usage: guix lint [OPTION]... [PACKAGE]...
Run a set of checkers on the specified package; if none is specified, run the checkers on all packages.\n"))
  (display (_ "
  -h, --help             display this help and exit"))
  (display (_ "
  -l, --list-checkers    display the list of available lint checkers"))
  (display (_ "
  -V, --version          display version information and exit"))
  (newline)
  (show-bug-report-information))

(define %options
  ;; Specification of the command-line options.
  ;; TODO: add some options:
  ;; * --checkers=checker1,checker2...: only run the specified checkers
  ;; * --certainty=[low,medium,high]: only run checkers that have at least this
  ;;                                  'certainty'.
  (list (option '(#\h "help") #f #f
                (lambda args
                  (show-help)
                  (exit 0)))
        (option '(#\l "list-checkers") #f #f
                (lambda args
                   (list-checkers-and-exit)))
        (option '(#\V "version") #f #f
                (lambda args
                  (show-version-and-exit "guix lint")))))


;;;
;;; Helpers
;;;
(define* (emit-warning package message #:optional field)
  ;; Emit a warning about PACKAGE, printing the location of FIELD if it is
  ;; given, the location of PACKAGE otherwise, the full name of PACKAGE and the
  ;; provided MESSAGE.
  (let ((loc (or (package-field-location package field)
                 (package-location package))))
    (format (guix-warning-port) (_ "~a: ~a: ~a~%")
            (location->string loc)
            (package-full-name package)
            message)))


;;;
;;; Checkers
;;;
(define-record-type* <lint-checker>
  lint-checker make-lint-checker
  lint-checker?
  ;; TODO: add a 'certainty' field that shows how confident we are in the
  ;; checker. Then allow users to only run checkers that have a certain
  ;; 'certainty' level.
  (name        lint-checker-name)
  (description lint-checker-description)
  (check       lint-checker-check))

(define (list-checkers-and-exit)
  ;; Print information about all available checkers and exit.
  (format #t (_ "Available checkers:~%"))
  (for-each (lambda (checker)
              (format #t "- ~a: ~a~%"
                      (lint-checker-name checker)
                      (lint-checker-description checker)))
            %checkers)
  (exit 0))

(define (start-with-capital-letter? s)
  (char-set-contains? char-set:upper-case (string-ref s 0)))

(define (check-description-style package)
  ;; Emit a warning if stylistic issues are found in the description of PACKAGE.
 (let ((description (package-description package)))
   (when (and (string? description)
              (not (string-null? description))
              (not (start-with-capital-letter? description)))
     (emit-warning package
                   "description should start with an upper-case letter"
                   'description))))

(define (check-inputs-should-be-native package)
  ;; Emit a warning if some inputs of PACKAGE are likely to belong to its
  ;; native inputs.
  (let ((inputs (package-inputs package)))
    (match inputs
      (((labels packages . _) ...)
       (when (member "pkg-config"
                     (map package-name (filter package? packages)))
        (emit-warning package
                      "pkg-config should probably be a native input"
                      'inputs))))))


(define (check-synopsis-style package)
  ;; Emit a warning if stylistic issues are found in the synopsis of PACKAGE.
  (define (check-final-period synopsis)
    ;; Synopsis should not end with a period, except for some special cases.
    (if (and (string=? (string-take-right synopsis 1) ".")
             (not (string=? (string-take-right synopsis 4) "etc.")))
        (emit-warning package
                      "no period allowed at the end of the synopsis"
                      'synopsis)))

  (define (check-start-article synopsis)
   (if (or (string-ci=? (string-take synopsis 2) "A ")
           (string-ci=? (string-take synopsis 3) "An "))
       (emit-warning package
                     "no article allowed at the beginning of the synopsis"
                     'synopsis)))

  (define (check-synopsis-length synopsis)
   (if (>= (string-length synopsis) 80)
       (emit-warning package
                     "synopsis should be less than 80 characters long"
                     'synopsis)))

  (define (check-synopsis-start-upper-case synopsis)
   (when (and (not (string-null? synopsis))
              (not (start-with-capital-letter? synopsis)))
     (emit-warning package
                   "synopsis should start with an upper-case letter"
                   'synopsis)))

  (define (check-start-with-package-name synopsis)
   (let ((idx (string-contains-ci synopsis (package-name package))))
     (when (and idx
                (= idx 0))
       (emit-warning package
                     "synopsis should not start with the package name")
                     'synopsis)))

 (let ((synopsis (package-synopsis package)))
   (if (string? synopsis)
       (begin
        (check-synopsis-start-upper-case synopsis)
        (check-final-period synopsis)
        (check-start-article synopsis)
        (check-start-with-package-name synopsis)
        (check-synopsis-length synopsis)))))

(define (check-patches package)
  ;; Emit a warning if the patches requires by PACKAGE are badly named.
  (let ((patches   (and=> (package-source package) origin-patches))
        (name      (package-name package))
        (full-name (package-full-name package)))
    (if (and patches
             (any (match-lambda
                   ((? string? patch)
                    (let ((filename (basename patch)))
                      (not (or (eq? (string-contains filename name) 0)
                               (eq? (string-contains filename full-name)
                                    0)))))
                   (_
                    ;; This must be an <origin> or something like that.
                    #f))
                  patches))
        (emit-warning package
          "file names of patches should start with the package name"
          'patches))))

(define %checkers
  (list
   (lint-checker
     (name        "description")
     (description "Validate package descriptions")
     (check       check-description-style))
   (lint-checker
     (name        "inputs-should-be-native")
     (description "Identify inputs that should be native inputs")
     (check       check-inputs-should-be-native))
   (lint-checker
     (name        "patch-filenames")
     (description "Validate filenames of patches")
     (check       check-patches))
   (lint-checker
     (name        "synopsis")
     (description "Validate package synopsis")
     (check       check-synopsis-style))))

(define (run-checkers package)
  ;; Run all the checkers on PACKAGE.
  (for-each (lambda (checker)
              ((lint-checker-check checker) package))
            %checkers))


;;;
;;; Entry Point
;;;

(define (guix-lint . args)
  (define (parse-options)
    ;; Return the alist of option values.
    (args-fold* args %options
                (lambda (opt name arg result)
                  (leave (_ "~A: unrecognized option~%") name))
                (lambda (arg result)
                  (alist-cons 'argument arg result))
                %default-options))

  (let* ((opts (parse-options))
         (args (filter-map (match-lambda
                            (('argument . value)
                             value)
                            (_ #f))
                           (reverse opts))))


   (if (null? args)
        (fold-packages (lambda (p r) (run-checkers p)) '())
        (for-each
          (lambda (spec)
            (run-checkers spec))
          (map specification->package args)))))
