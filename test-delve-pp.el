;;; test-delve-pp.el --- Tests for delve-pp.el       -*- lexical-binding: t; -*-

;; Copyright (C) 2021  

;; Author:  <joerg@joergvolbers.de>
;; Keywords: 

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Tests for delve-pp.el

;;; Code:

(require 'buttercup)
(require 'delve-pp)

(defface delve-pp-testface
  '((t (:weight bold)))
  "Face for testing pretty printing."
  :group 'testgroup)

(describe "delve-pp-apply-mods"
  (it "returns string unmodified if no mod is passed"
    (let ((s "the string"))
      (expect (delve-pp-apply-mods s nil nil)
	      :to-equal s)))
  (it "returns propertized string when using mod (:face facename)"
    (let ((s "the string")
	  (face 'delve-pp-testface))
      (expect (delve-pp-apply-mods s :face face)
	      :to-equal
	      (propertize s 'face face))))
  (it "does not add face when delve-pp-inhibit-faces is set"
    (let ((s "the string")
	  (face 'delve-pp-testface)
	  (delve-pp-inhibit-faces t))
      (expect (delve-pp-apply-mods s :face face)
	      :to-equal
	      s)))
  (it "pads string with extra whitespaces using mod (:width n)"
    (let ((s "the string"))
      (expect (length (delve-pp-apply-mods s :width 30))
	      :to-be
	      30)))
  (it "shortens long string using mod (:width n)"
    (let ((s "the very very very long string which is insanely long oh my god oh my gosh"))
      (expect (length (delve-pp-apply-mods s :width 30))
	      :to-be
		30)))
  (it "returns string unmodified using unknown keyword (:nomod n)"
    (let ((s "the string"))
      (expect (delve-pp-apply-mods s :nomod :nomod)
		:to-equal
		s))))

(describe "delve-pp-item"
  
  (describe "basic calling variants"
    (it "returns a string if it is passed as a pprinter argument"
      (let ((s "the string"))
	(expect (delve-pp-item nil s nil)
		:to-equal
		s)))
    (it "calls the pprinter function with the object"
      (let ((s "this is my result"))
	(expect (delve-pp-item s #'identity nil)
		:to-equal
		s))))

  (describe "using modifiers"
    (it "passes the mod keyword and its args to the mod application function"
      (spy-on 'delve-pp-apply-mods)
      (let ((s "the string"))
	(delve-pp-item nil "the string" '(:face delve-pp-testface))
	(expect 'delve-pp-apply-mods
		:to-have-been-called-with
		s
		:face
		'delve-pp-testface)))
    (it "iterates over pairs of mod keywords and arguments"
      (spy-on 'delve-pp-apply-mods :and-call-fake
	      (lambda (s &rest _)
		(concat "." s)))
      (let* ((orig-s "the-string")
	     (new-s (delve-pp-item nil orig-s
				   '(:face delve-pp-testface
					   :width 30
					   :format "%s"))))
	(expect 'delve-pp-apply-mods
		:to-have-been-called-times 3)
	(expect new-s :to-equal (concat "..." orig-s))))))

(describe "delve-pp-line"
  (it "can be used to just concenate stringss"
    (let* ((s1 "the")
	   (s2 "string")
	   (pp-scheme (list s1 s2)))
      (expect (delve-pp-line nil pp-scheme)
	      :to-equal
	      (concat s1 s2))))
  (it "joins the results from unmodified pretty printer"
    (let* ((obj "the string")
	   (pp-scheme '(identity identity)))
      (expect (delve-pp-line obj pp-scheme)
	      :to-equal
	      (concat obj obj))))
  (it "accepts mod-arg-pairs in two different formats"
    (let* ((obj "the object")
	   (pp-scheme '((identity :width 30)
			(identity :face some-face))))
      (spy-on 'delve-pp-item)
      (delve-pp-line obj pp-scheme)
      (expect 'delve-pp-item :to-have-been-called-times 2)))
  (it "returns error string when scheme is invalid"
    (let* ((obj "the object")
	   (pp-scheme '((identity :something)
			(:aaargh))))
      (expect (delve-pp-line obj pp-scheme)
	      :to-equal
	      (apply #'concat
		     (mapcar (apply-partially
			      #'format delve-pp-invalid-scheme-error-string)
			     pp-scheme)))))
  (it "returns nil when scheme is invalid and  error string is set to nil"
    (let* ((obj "the object")
	   (pp-scheme '((identity :something)))
	   (delve-pp-invalid-scheme-error-string nil))
      (expect (delve-pp-line obj pp-scheme)
	      :to-equal ""))))

(provide 'test-delve-pp)
;;; test-delve-pp.el ends here
