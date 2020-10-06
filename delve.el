;;; delve.el --- Delve into the depths of your org roam zettelkasten       -*- lexical-binding: t; -*-

;; Copyright (C) 2020

;; Author:  <joerg@joergvolbers.de>
;; Keywords: hypermedia, org-roam

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

;; Delve into the depths of your zettelkasten.

;;; Code:


;; -----------------------------------------------------------
;; * Dependencies

(require 'cl-lib)
(require 'org-roam)
(require 'lister)
(require 'lister-highlight)
(require 'delve-data-types)
(require 'delve-edit)

;; * Silence Byte Compiler

(declare-function all-the-icons-faicon "all-the-icons" (string) t)

;; * Global variables

(defvar delve-auto-delete-roam-buffer t
  "Delete visible *org roam* buffer when switchung to DELVE.")

(defvar delve-buffer-name "*DELVE*"
  "Name of delve buffers.")

(defvar delve-version-string "0.2"
  "Current version of delve.")

(defvar delve-searches
  (list (delve-make-page-search :name "Orphaned Pages"
    			   :constraint [:where tags:tags :is :null])
	(delve-make-page-search :name "10 Last Modified"
			   :postprocess #'delve-db-query-last-10-modified)
	(delve-make-page-search :name "10 Most Linked To"
			   :constraint [:order-by (desc backlinks)
					:limit 10])
	(delve-make-page-search :name "10 Most Linked From"
			   :constraint [:order-by (desc tolinks)
					:limit 10])
	(delve-make-page-search :name "10 Most Linked"
			   :constraint [:order-by (desc (+ backlinks tolinks))
					:limit 10]))
  "A list of default searches offered when starting delve.")

;; -----------------------------------------------------------
;; * Item Mapper for the List Display (lister)

;; -- presenting a zettel object:

(defun delve-represent-tags (zettel)
  "Return all tags from GENERIC-ZETTEL as a propertized string."
  (when (delve-zettel-tags zettel)
    (concat "("
	    (propertize
	     (string-join (delve-zettel-tags zettel) ", ")
	     'face 'org-level-1)
	    ") ")))

(defun delve-represent-title (zettel)
  "Return the title of ZETTEL as a propertized string."
  (propertize (or
	       (delve-zettel-title zettel)
	       (delve-zettel-file zettel)
	       "NO FILE, NO TITLE.")
	      'face 'org-document-title))

(defun delve-format-time (time)
  "Return TIME in a more human readable form."
  (let* ((days         (time-to-days time))
	 (current-days (time-to-days (current-time))))
    (if (/= days current-days)
	(format-time-string "%b %d " time)
      (format-time-string " %R " time))))

(defvar delve-subtype-icons-alist
  '((delve-page     :default "    PAGE" :faicon "list-alt")
    (delve-tolink   :default "  TOLINK" :faicon "caret-left")
    (delve-backlink :default "BACKLINK" :faicon "caret-right"))
  "Alist associating a delve zettel subtype with a name and symbol.
The name and the symbol are determined by the properties
`:default' (for the name) and `:faicon' (for the symbol).

If `all-the-icons' is installed, use the symbol. Else, display
the name (a simple string).")

(defun delve-format-subtype (zettel)
  "Return the subtype of ZETTEL prettified."
  (let* ((subtype     (type-of zettel))
	 (type-plist  (alist-get subtype delve-subtype-icons-alist nil)))
    (concat 
     (if (and type-plist (featurep 'all-the-icons))
	 (all-the-icons-faicon (plist-get type-plist :faicon))
       (propertize (if type-plist
		       (plist-get type-plist :default)
		     "subtype?")
		   'face 'font-lock-constant-face))
     " ")))

(defun delve-represent-zettel (zettel)
  "Return ZETTEL as a pretty propertized string.
ZETTEL can be either a page, a backlink or a tolink."
  (list  (concat
	  ;; creation time:
	  (propertize
	   (delve-format-time (delve-zettel-mtime zettel))
	   'face 'org-document-info-keyword)
	  ;; subtype (tolink, backlink, zettel)
	  (delve-format-subtype zettel)
	  ;; associated tags:
	  (delve-represent-tags zettel)
	  ;; # of backlinks:
	  (propertize
	   (format "%d → " (or (delve-zettel-backlinks zettel) 0))
	   'face '(:weight bold))
	  ;; title:
	  (delve-represent-title zettel)
	  ;; # of tolinks:
	  (propertize
	   (format " →  %d" (or (delve-zettel-tolinks zettel) 0))
	   'face '(:weight bold)))))

;; -- presenting a search item:

(defun delve-represent-search (search)
  "Return propertized strings representing a SEARCH object."
  (list (concat (if (featurep 'all-the-icons)
		    (all-the-icons-faicon "search")
		  "Search:")
		" "
		(propertize
		 (delve-generic-search-name search)
		 'face 'org-level-2))))

;; -- presenting a tag object:

(defun delve-represent-tag (tag)
  "Return propertized strings representing a TAG object."
  (list (concat (if (featurep 'all-the-icons)
		    (all-the-icons-faicon "tag")
		  "Tag:")
		" "
		(propertize (delve-tag-tag tag) 'face 'org-level-1)
		(when (delve-tag-count tag)
		  (format " (%d)" (delve-tag-count tag))))))


;; the actual mapper:

(defun delve-mapper (data)
  "Transform DATA into a printable list."
  (pcase data
    ((pred delve-zettel-p)         (delve-represent-zettel data))
    ((pred delve-tag-p)            (delve-represent-tag data))
    ((pred delve-generic-search-p) (delve-represent-search data))
    (_        (list (format "UNKNOWN TYPE: %s"  (type-of data))))))

;; -----------------------------------------------------------
;; * Buffer basics

(defun delve-new-buffer ()
  "Return a new DELVE buffer."
   (generate-new-buffer delve-buffer-name))

;; * Insert sublists according to the item type

(defun delve-execute-search (search)
  "Return the results of executing SEARCH."
  (if-let* ((res (delve-db-query-all-zettel
		  ;; subtype:
		  (delve-generic-search-result-makefn search)
		  ;; constraint
		  (delve-generic-search-constraint search)
		  ;; args
		  (delve-generic-search-args search)
		  ;; with-clause 
		  (delve-generic-search-with-clause search))))
      (if (and res (delve-generic-search-postprocess search))
	  (funcall (delve-generic-search-postprocess search) res)
	res)
    (message "Query returned no results")
    nil))

(defun delve-insert-sublist-pages-matching-tag (buf pos tag)
  "In BUF, insert all pages tagged TAG below the item at POS."
  (let* ((pages (delve-db-query-pages-with-tag tag)))
    (if pages
	(lister-insert-sublist-below buf pos pages)
      (user-error "No pages found matching tag %s" tag))))

(defun delve-insert-sublist-all-links (buf pos zettel)
  "In BUF, insert all links to and from ZETTEL below the item at POS."
  (let* ((backlinks (delve-db-query-backlinks zettel))
	 (tolinks   (delve-db-query-tolinks zettel))
	 (all       (append backlinks tolinks)))
    (if all
	(lister-insert-sublist-below buf pos all)
      (user-error "Item has no backlinks and no links to other zettel"))))

(defun delve-insert-sublist (buf)
  "In BUF, eval item at point and insert result as a sublist."
  (unless (lister-sublist-below-p buf (point))
    (let ((data (lister-get-data buf :point)))
      (pcase data
	((pred delve-tag-p)
	 (delve-insert-sublist-pages-matching-tag buf
						  (point)
						  (delve-tag-tag data)))
	((pred delve-zettel-p)
	 (delve-insert-sublist-all-links buf
					 (point)
					 data))
	((pred delve-generic-search-p)
	 (lister-insert-sublist-below  buf
				       (point)
				       (delve-execute-search data)))))))

;;; * Delve Mode: Interactive Functions, Mode Definition 

(defun delve-insert-sublist-to-links (buf pos zettel)
  "In BUF, insert all links to ZETTEL below the item at POS."
  (interactive (list (current-buffer) (point) (lister-get-data (current-buffer) :point)))
  (if-let* ((tolinks (delve-db-query-tolinks zettel)))
      (lister-insert-sublist-below buf pos tolinks)
    (user-error "Item has no links")))

(defun delve-insert-sublist-backlinks (buf pos zettel)
  "In BUF, insert all links from ZETTEL below the item at POS."
  (interactive (list (current-buffer) (point) (lister-get-data (current-buffer) :point)))
  (if-let* ((fromlinks (delve-db-query-backlinks zettel)))
      (lister-insert-sublist-below buf pos fromlinks)
    (user-error "Item has no backlinks")))

(defun delve-toggle-sublist (buf pos)
  "In BUF, close or open the item's sublist at POS."
  (interactive (list (current-buffer) (point)))
  (if (lister-sublist-below-p buf pos)
      (lister-remove-sublist-below buf pos)
    (delve-insert-sublist buf)))

(defun delve-initial-list (&optional empty-list)
  "Populate the current delve buffer with predefined items.
If EMPTY-LIST is t, offer a completely empty list instead."
  (interactive "P")
  (if empty-list
      (lister-set-list (current-buffer) nil)
    ;; 
    (lister-set-list (current-buffer) (delve-db-query-roam-tags))
    (cl-dolist (search delve-searches)
      (lister-insert (current-buffer) :first search))
    (when (equal (window-buffer) (current-buffer))
      (recenter))))

(defun delve-sublist-to-top (buf pos)
  "Replace all items with the current sublist at point."
  (interactive (list (current-buffer) (point)))
  (unless lister-local-marker-list
    (user-error "There are not items in this buffer"))
  (pcase-let* ((lister-display-transaction-p t)
	       (`(,beg ,end _ ) (lister-sublist-boundaries buf pos)))
    (lister-sensor-leave buf)
    (lister-set-list buf (lister-get-all-data-tree buf beg end)))
  (lister-goto buf :first))

;; TODO Currently unused
(defun delve-insert-zettel  ()
  "Choose a zettel and insert it in the current delve buffer."
  (interactive)
  (let* ((zettel (delve-db-query-all-zettel 'delve-make-page
					    [:order-by (asc titles:title)]))
	 (completion (seq-map (lambda (z) (cons (concat (delve-represent-tags z)
							(delve-represent-title z))
						z))
			      zettel))
	 (candidate  (completing-read " Insert zettel: " completion nil t))
	 (pos        (point)))
    (when lister-highlight-mode
      (lister-unhighlight-item))
    (lister-insert (current-buffer) :next (alist-get candidate completion nil nil #'string=))
    (lister-goto (current-buffer) pos)))

(defun delve-visit-zettel ()
  "Visit the zettel item on point, leaving delve."
  (interactive)
  (let* ((data (lister-get-data (current-buffer) :point)))
    (unless (delve-zettel-p data)
      (user-error "Item at point is no zettel"))
    (find-file (delve-zettel-file data))
    (org-roam-buffer-toggle-display)))

(defun delve-action (data)
  "Act on the delve object DATA."
  (ignore data)
  (delve-visit-zettel))

(defvar delve-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map lister-mode-map)
    ;; <RETURN> is mapped to #'delve-action (via lister-local-action)
    (define-key map "\t"               #'delve-toggle-sublist)
    (define-key map (kbd "C-l")        #'delve-sublist-to-top)
    (define-key map "."                #'delve-initial-list)
    (define-key map (kbd "<left>")     #'delve-insert-sublist-backlinks)
    (define-key map (kbd "<right>")    #'delve-insert-sublist-to-links)
    map)
  "Key map for `delve-mode'.")


(define-derived-mode delve-mode
  lister-mode "Delve"
  "Major mode for browsing your org roam zettelkasten."
  ;; Setup lister first since it deletes all local vars:
  (lister-setup	(current-buffer) #'delve-mapper
		nil                             ;; initial data
		(concat "DELVE Version " delve-version-string) ;; header
		nil ;; footer
		nil ;; filter
		t   ;; no major-mode
		)
  ;; Now add delve specific stuff:
  (setq-local lister-local-action #'delve-action))

;; * Interactive entry points

(defvar delve-toggle-buffer nil
  "The last created lister buffer.
Calling `delve-toggle' switches to this buffer.")

;;;###autoload
(defun delve ()
  "Delve into the org roam zettelkasten."
  (interactive)
  (unless org-roam-mode
    (with-temp-message "Turning on org roam mode..."
      (org-roam-mode)))
  (with-current-buffer (setq delve-toggle-buffer (delve-new-buffer))
    (delve-mode)
    (lister-highlight-mode)
    (delve-initial-list))
  (switch-to-buffer delve-toggle-buffer))

;;;###autoload
(defun delve-toggle (&optional force-reinit)
  "Toggle the display of the delve buffer.
With interactive prefix or optional argument FORCE-REINIT, switch
to a reinitialized delve buffer."
  (interactive "P")
  (if (and
       (not force-reinit)
       delve-toggle-buffer
       (buffer-live-p delve-toggle-buffer))
      ;; toggle an existing buffer:
      (if (equal (current-buffer) delve-toggle-buffer)
	  (bury-buffer)
	(switch-to-buffer delve-toggle-buffer))
    ;; or create a new one:
    (when delve-toggle-buffer
      (kill-buffer delve-toggle-buffer)
      (setq delve-toggle-buffer nil))
    (delve))
  (when delve-auto-delete-roam-buffer
    (when-let* ((win (get-buffer-window org-roam-buffer)))
      (delete-window win))))

;; (bind-key "<f2>" 'delve-toggle)

(provide 'delve)
;;; delve.el ends here
