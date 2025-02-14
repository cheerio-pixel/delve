;;; delve-query.el --- Delve queries for the Org Roam database  -*- lexical-binding: t; -*-

;; Copyright (C) 2021

;; Author:  <joerg@joergvolbers.de>

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

;; Provides functions to query the Org Roam DB.

;;; Code:

;;; * Dependencies

(require 'subr-x)
(require 'cl-lib)
(require 'seq)
(require 'dash)
(require 'benchmark)
(require 'org-roam-db)
(require 'org-roam-node)
(require 'emacsql-compiler)


;;; * Framework for 'save' and 'verbose' querying

(defconst delve-query-db-version 18
  "Org roam DB version on which delve query relies.
Must match `org-roam-db-version'.")

(defvar delve-query-catch-db-errors t
  "If set, catch and log database errors.")

(defvar delve-query-log-queries t
  "If set, log all SQL queries issued by Delve.")

(defvar delve-query-log-buffer "*Delve DB Interactions*"
  "Buffer name for logging Org Roam queries.")

(defun delve-query-log-buffer ()
  "Get or create a log buffer."
  (or (get-buffer delve-query-log-buffer)
      (with-current-buffer (get-buffer-create delve-query-log-buffer)
        (special-mode)
        (current-buffer))))

(defun delve-query-log (&rest strings)
  "Insert STRINGS in the log buffer.
NIL values are ignored.  Nested lists are flattened."
  (with-current-buffer (delve-query-log-buffer)
    (let* ((inhibit-read-only t)
           (date-string (format-time-string "%D %T")))
      (goto-char (point-max))
      ;; we use flatten-tree to remove nil values:
      (cl-dolist (s (flatten-tree strings))
        (insert (propertize date-string 'face 'compilation-line-number) " " s "\n")))))

(defun delve-query (sql &rest args)
  "Call Org Roam SQL query (optionally using ARGS) in a safe way.
If `delve-query-catch-db-errors' is set, catch all errors, log them
and return nil."
  ;; always check DB version
  (unless (eq org-roam-db-version delve-query-db-version)
    (let ((msg (if (> org-roam-db-version delve-query-db-version)
                   "ahead"
                 "outdated")))
      (error "Delve fatal error: Org Roam DB version %d is %s, expected %d"
             org-roam-db-version msg delve-query-db-version)))
  ;; now do the query:
  (condition-case err
      (let (res time)
        (when delve-query-log-queries
          (delve-query-log (format "%s" sql)
                           (when args (format " -- Args=%s" args))))
        (setq time
              (benchmark-run (setq res (apply #'org-roam-db-query sql (flatten-tree args)))))
        (when delve-query-log-queries
          (delve-query-log (format " -- query returns %d items in %.2f seconds."
                                 (length res)
                                 (car time))))
        res)
    (error (if (not delve-query-catch-db-errors)
               (signal (car err) (cdr err))
             (delve-query-log (error-message-string err))))))

(defun delve-query-quote-string (s)
  "Quote string S for use as an emacsSQL argument."
  (concat "\"" s "\""))

;;; * Some queries

(defvar delve-query--super-query
  "SELECT id, file, filetitle, \"level\", todo, pos, priority,
           scheduled, deadline , title, properties, olp, atime,
           mtime, '(' || group_concat(tags, ' ') || ')' as tags,
           aliases, refs FROM
           -- outer from clause
           (
           SELECT  id,  file, filetitle, \"level\", todo,  pos, priority,  scheduled, deadline ,
             title, properties, olp, atime,  mtime, tags,
             '(' || group_concat(aliases, ' ') || ')' as aliases,
             refs
           FROM
           -- inner from clause
             (
             SELECT  nodes.id as id,  nodes.file as file,  nodes.\"level\" as \"level\",
               nodes.todo as todo,   nodes.pos as pos,  nodes.priority as priority,
               nodes.scheduled as scheduled,  nodes.deadline as deadline,  nodes.title as title,
               nodes.properties as properties,  nodes.olp as olp,  files.atime as atime,
               files.title as filetitle,
               files.mtime as mtime,  tags.tag as tags,    aliases.alias as aliases,
               '(' || group_concat(RTRIM (refs.\"type\", '\"') || ':' || LTRIM(refs.ref, '\"'), ' ') || ')' as refs
             FROM nodes
             LEFT JOIN files ON files.file = nodes.file
             LEFT JOIN tags ON tags.node_id = nodes.id
             LEFT JOIN aliases ON aliases.node_id = nodes.id
             LEFT JOIN refs ON refs.node_id = nodes.id
             GROUP BY nodes.id, tags.tag, aliases.alias )
             -- end inner from clause
           GROUP BY id, tags )
           --- end outer from clause
         GROUP BY id\n"
  "Query which returns all nodes with all fields.")

(defun delve-query-node-list ()
  "Return all nodes."
  (org-roam-node-list))

(defun delve-query-do-super-query (query)
  "Call one big SQL QUERY and return results as Org Roam node structs.
QUERY must be `delve-query--super-query' or a subset.  See the
query `delve-query--super-query' for allowed fields."
  (cl-loop for row in (delve-query query)
           append (pcase-let* ((`(,id ,file ,file-title ,level ,todo ,pos ,priority ,scheduled ,deadline
                                      ,title ,properties ,olp ,atime ,mtime ,tags ,aliases ,refs)
                                row)
                               (all-titles (cons title aliases)))
                    (mapcar (lambda (temp-title)
                              (org-roam-node-create :id id
                                                    :file file
                                                    :file-title file-title
                                                    :file-atime atime
                                                    :file-mtime mtime
                                                    :level level
                                                    :point pos
                                                    :todo todo
                                                    :priority priority
                                                    :scheduled scheduled
                                                    :deadline deadline
                                                    :title temp-title
                                                    :properties properties
                                                    :olp olp
                                                    :tags tags
                                                    :refs refs))
                            all-titles))))

(defun delve-query--scalar-string (string)
  "Return STRING as a quoted scalar string."
  (thread-first string
    (emacsql-quote-identifier)
    (emacsql-quote-scalar)))

(defun delve-query--scalar-strings (strings)
  "Return STRINGS as a string with quoted scalar values."
  (string-join (mapcar #'delve-query--scalar-string
                       strings)
               ", "))

(defun delve-query-nodes-by-tags (tag-list)
  "Return all nodes with tags TAG-LIST."
  (when tag-list
    (delve-query-do-super-query
     (concat "SELECT * FROM ( " delve-query--super-query " ) "
             (format "WHERE tags LIKE %s ORDER BY title"
                     (string-join (mapcar (lambda (s)
                                            (thread-last s
                                              ;; FIXME this does not work
                                              ;; for \" as intended
                                              ;; (e.g. tag "\"test\"")
                                              (emacsql-quote-identifier)
                                              ;; emacsql-parse passes SQL to
                                              ;; #'format, so double % to avoid
                                              ;; interpretation as format char
                                              (format "%%%%%s%%%%")
                                              ;; surround with '...'
                                              (emacsql-quote-scalar)))
                                          tag-list)
                                  " AND tags LIKE "))))))

(defun delve-query-tags (&optional ids)
  "Return all tags as a sorted list of strings.
Optionally restrict to those nodes with an id in IDS."
  (let* ((base-query [:select :distinct [tag] :from tags])
         (query      (if (null ids)
                         base-query
                       (vconcat base-query `[:where (in node_id ,(seq-into ids 'vector))]))))
    (seq-sort #'string< (seq-uniq (mapcar #'car (delve-query query))))))

(defun delve-query-nodes-by-todo (todo-state)
  "Return all nodes having TODO-STATE, sorted by title."
  (delve-query-do-super-query
   (concat delve-query--super-query
           (format "HAVING todo=%s ORDER BY title"
                   (delve-query--scalar-string todo-state)))))

(defun delve-query-nodes-by-id (id-list)
  "Return all nodes in ID-LIST sorted by the node's title."
  (let ((nodes (with-temp-message (format "Querying database for %d nodes..." (length id-list))
                 (delve-query-do-super-query
                  (concat delve-query--super-query
                          (format "HAVING id IN (%s) ORDER BY title"
                                  (delve-query--scalar-strings id-list)))))))
    (unless (eq (length nodes) (length id-list))
      ;; make sure inequality is not due to aliased nodes with same ID
      (when (-difference (-uniq (mapcar #'org-roam-node-id nodes))
                         (-uniq id-list))
          (message "delve: Could not get all requested IDs, maybe DB is out of sync?")))
    nodes))

(defun delve-query-node-by-id (id)
  "Return node with ID."
  (car (delve-query-nodes-by-id (list id))))

;;; TODO Write tests
(defun delve-query--ids-linking-to (id)
  "Get all ids linking to ID (backlinks)."
  (flatten-tree (delve-query [:select [ source ]
                                      :from links
                                      :where (= dest $s1)
                                      :and (= type "id")]
                             id)))

;;; TODO Write tests
(defun delve-query--ids-linking-from (id)
  "Get all ids linking from node ID (fromlinks)."
  (flatten-tree (delve-query [:select [ dest ]
                                      :from links
                                      :where (= source $s1)
                                      :and (= type "id")]
                             id)))

(defun delve-query-backlinks-by-id (id)
  "Get all nodes linking to ID."
  (let ((backlinks (delve-query--ids-linking-to id)))
    (delve-query-nodes-by-id (flatten-tree backlinks))))

(defun delve-query-fromlinks-by-id (id)
  "Get all nodes linking from ID."
  (let ((tolinks (delve-query--ids-linking-from id)))
    (delve-query-nodes-by-id (flatten-tree tolinks))))

(defun delve-query-unlinked ()
  "Get all nodes with no backlinks or tolinks."
  (let* ((ids (delve-query "SELECT id FROM nodes WHERE id NOT IN
  (SELECT source AS id FROM links WHERE type='\"id\"'
   UNION SELECT dest AS id FROM links WHERE type='\"id\"')")))
    (delve-query-nodes-by-id (flatten-tree ids))))

(defun delve-query-last-modified (&optional limit)
  "Get LIMIT last modified Org Roam nodes.
If LIMIT is unspecified, return the last 10 modified nodes."
  (-take (or limit 10)
         (-sort (-on (-compose #'not #'time-less-p) #'org-roam-node-file-mtime)
                (delve-query-node-list))))

(provide 'delve-query)
;;; delve-query.el ends here
