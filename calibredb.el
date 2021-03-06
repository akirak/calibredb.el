;;; calibredb.el --- Yet another calibre client -*- lexical-binding: t; -*-

;; Copyright (C) 2020 Damon Chan

;; Author: Damon Chan <elecming@gmail.com>
;; URL: https://github.com/chenyanming/calibredb.el
;; Keywords: faces
;; Created: 9 May 2020
;; Version: 1.1.0
;; Package-Requires: ((emacs "25.1") (org "9.0"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package is a wrapper for calibredb
;; <https://manual.calibre-ebook.com/generated/en/calibredb.html> integrating
;; with counsel/helm support.

;;; Code:

(require 'org)
(require 'cl-lib)
(require 'sql)
(ignore-errors
  (require 'ivy)
  (require 'helm)
  (require 'transient))

(defgroup calibredb nil
  "calibredb group"
  :group 'calibredb)

(defvar calibredb-root-dir "~/Documents/Calibre/")

(defvar calibredb-db-dir
  (concat (file-name-as-directory
           calibredb-root-dir) "metadata.db"))

(defvar calibredb-program "/Applications/calibre.app/Contents/MacOS/calibredb")

(defvar calibredb-query-string "
SELECT id, author_sort, path, name, format, pubdate, title, group_concat(DISTINCT tag) AS tag, uncompressed_size, text, last_modified
FROM
  (SELECT sub2.id, sub2.author_sort, sub2.path, sub2.name, sub2.format, sub2.pubdate, sub2.title, sub2.tag, sub2.uncompressed_size, comments.text, sub2.last_modified
  FROM
    (SELECT child.id, child.author_sort, child.path, child.name, child.format, child.pubdate, child.title, child.last_modified, tags.name AS tag, child.uncompressed_size
    FROM
      (SELECT sub.id, sub.author_sort, sub.path, sub.name, sub.format, sub.pubdate, sub.title, sub.last_modified, sub.uncompressed_size, books_tags_link.tag
      FROM
        (SELECT b.id, b.author_sort, b.path, d.name, d.format, b.pubdate, b.title, b.last_modified, d.uncompressed_size
        FROM data AS d
        LEFT OUTER JOIN books AS b
        ON d.book = b.id) AS sub
        LEFT OUTER JOIN books_tags_link
        ON sub.id = books_tags_link.book) AS child
      LEFT OUTER JOIN tags
      ON child.tag = tags.id) as sub2
    LEFT OUTER JOIN comments
    ON sub2.id = comments.book)
GROUP BY id"
  "TODO calibre database query statement.")

(defvar calibredb-helm-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map helm-map)
    (define-key map (kbd "C-c t") #'calibredb-set-metadata--tags-1)
    (define-key map (kbd "C-c c") #'calibredb-set-metadata--comments-1)
    map)
  "Keymap for `calibredb-find-helm'.")

(defvar calibredb-helm-source
  (helm-build-sync-source "calibredb"
    :header-name (lambda (name)
                   (concat name " in [" (helm-default-directory) "]"))
    :candidates 'calibredb-candidates
    ;; :filtered-candidate-transformer 'helm-findutils-transformer
    ;; :action-transformer 'helm-transform-file-load-el
    :persistent-action 'calibredb-find-cover
    :action 'calibredb-helm-actions
    ;; :help-message 'helm-generic-file-help-message
    :keymap calibredb-helm-map
    :candidate-number-limit 9999
    ;; :requires-pattern 3
    )
  "calibredb helm source.")

(defvar calibredb-selected-entry nil)

(defvar calibredb-show-entry nil
  "The entry being displayed in this buffer.")

(defvar calibredb-show-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\C-cg" 'calibredb-dispatch)
    map)
  "Keymap for `calibredb-show-mode'.")

(defcustom calibredb-show-unique-buffers nil
  "When non-nil, every entry buffer gets a unique name.
This allows for displaying multiple show buffers at the same
time."
  :group 'calibredb
  :type 'boolean)

(defcustom calibredb-show-entry-switch #'switch-to-buffer
  "Function used to display the calibre entry buffer."
  :group 'calibredb
  :type '(choice (function-item switch-to-buffer)
                 (function-item pop-to-buffer)
                 function))

(defcustom calibredb-helm-actions
  (helm-make-actions
   "Open file"                   'calibredb-find-file
   "Show details"                'calibredb-show-entry
   "Open file other frame"       'calibredb-find-file-other-frame
   "Open file with default tool" 'calibredb-open-file-with-default-tool
   "Open Cover Page"             'calibredb-find-cover
   "set_metadata, tags"          'calibredb-set-metadata--tags
   "set_metadata, comments"      'calibredb-set-metadata--comments
   "set_metadata, --list-fileds" 'calibredb-set-metadata--list-fields
   "show_metadata"               'calibredb-show-metadata
   "remove"                      'calibredb-remove)
  "Default actions for calibredb helm."
  :group 'calibredb
  :type '(alist :key-type string :value-type function))

(ivy-set-actions
 'calibredb-ivy-read
 '(("o" (lambda (candidate)
          (calibredb-find-file (cdr candidate)) ) "Open")
   ("O" (lambda (candidate)
          (calibredb-show-entry (cdr candidate)) ) "Show details")
   ("v" (lambda (candidate)
          (calibredb-open-file-with-default-tool (cdr candidate)) ) "Open with default tool")
   ("V" (lambda (candidate)
          (calibredb-find-file-other-frame (cdr candidate)) ) "Find file other frame")
   ("d" (lambda ()
          (calibredb-remove)) "Delete ebook")
   ("t" (lambda (candidate)
          (calibredb-set-metadata--tags (cdr candidate)) ) "Tag ebook")
   ("c" (lambda (candidate)
          (calibredb-set-metadata--comments (cdr candidate)) )"Comment ebook")
   ("q"
    (lambda ()
      (message "cancelled")) "(or anything else) to cancel")))

;; Utility

(cl-defstruct calibredb-struct
  command option input id action)

(defun calibredb-get-action (state)
  "Get the action function from STATE."
  (let ((action (calibredb-struct-action state)))
    (when action
      (if (functionp action)
          action
        (cadr (nth (car action) action))))))

(cl-defun calibredb-command (&key command option input id action)
  (let* ((command-string (make-calibredb-struct
                          :command command
                          :option option
                          :input input
                          :id id
                          :action action))
         (line (mapconcat 'identity
                          `(,calibredb-program
                            ,(calibredb-struct-command command-string)
                            ,(calibredb-struct-option command-string)
                            ,(calibredb-struct-input command-string)
                            ,(calibredb-struct-id command-string)) " ")))
    (message line)
    ;; (calibredb-get-action command-string)
    ;; (add-to-list 'display-buffer-alist (cons "\\*Async Shell Command\\*" (cons #'display-buffer-no-window t)))
    ;; (let* ((output-buffer (get-buffer-create "*Async Shell Command*"))
    ;;        (proc (progn
    ;;                (async-shell-command line output-buffer)
    ;;                (get-buffer-process output-buffer))))
    ;;   (if (process-live-p proc)
    ;;       ;; (set-process-sentinel proc #'do-something)
    ;;       nil
    ;;     (message "No process running.")))
    (shell-command-to-string line)))

(defun calibredb-chomp (s)
  (replace-regexp-in-string "[\s\n]+$" "" s))

(defun calibredb-open-with-default-tool (filepath)
  ;; TODO: consolidate default-opener with dispatcher
  (if (eq system-type 'windows-nt)
      (start-process "shell-process" "*Messages*"
                     "cmd.exe" "/c" filepath)
    (start-process "shell-process" "*Messages*"
                   (cond ((eq system-type 'gnu/linux)
                          (calibredb-chomp
                           (shell-command-to-string
                            (concat
                             "grep Exec "
                             (first
                              (delq nil (let ((mime-appname (calibredb-chomp (replace-regexp-in-string
                                                                              "kde4-" "kde4/"
                                                                              (shell-command-to-string "xdg-mime query default application/pdf")))))
                                          (mapcar
                                           #'(lambda (dir) (let ((outdir (concat dir "/" mime-appname))) (if (file-exists-p outdir) outdir)))
                                           '("~/.local/share/applications" "/usr/local/share/applications" "/usr/share/applications")))))
                             "|head -1|awk '{print $1}'|cut -d '=' -f 2"))))
                         ((eq system-type 'windows-nt)
                          "start")
                         ((eq system-type 'darwin)
                          "open")
                         (t (message "unknown system!?"))) filepath)))

(defun calibredb-query (sql-query)
  "Query calibre databse and return the result."
  (interactive)
  (shell-command-to-string
   (format "%s -separator \"\t\" \"%s\" \"%s\""
           sql-sqlite-program
           (replace-regexp-in-string "\"" "\\\\\"" calibredb-db-dir)
           sql-query)))

(defun calibredb-query-to-alist (query-result)
  "Builds alist out of a full calibredb-query query record result."
  (if query-result
      (let ((spl-query-result (split-string (calibredb-chomp query-result) "\t")))
        `((:id                     ,(nth 0 spl-query-result))
          (:author-sort            ,(nth 1 spl-query-result))
          (:book-dir               ,(nth 2 spl-query-result))
          (:book-name              ,(nth 3 spl-query-result))
          (:book-format  ,(downcase (nth 4 spl-query-result)))
          (:book-pubdate           ,(nth 5 spl-query-result))
          (:book-title             ,(nth 6 spl-query-result))
          (:file-path    ,(concat (file-name-as-directory calibredb-root-dir)
                                  (file-name-as-directory (nth 2 spl-query-result))
                                  (nth 3 spl-query-result) "." (downcase (nth 4 spl-query-result))))
          (:tag                    ,(nth 7 spl-query-result))
          (:size                   ,(format "%.2f" (/ (string-to-number (nth 8 spl-query-result) ) 1048576.0) ))
          (:comment                ,(format "%s"
                                            (if (not (nth 9 spl-query-result))
                                                ""
                                              (nth 9 spl-query-result))))))))

(defun calibredb-list ()
  "Generate an org buffer which contains all ebooks' cover image, title and the file link."
  (interactive)
  (let* ((buf-name "*calibredb*")
         occur-buf)
    (when (get-buffer buf-name)
      (kill-buffer buf-name))
    (setq occur-buf (get-buffer-create buf-name))
    (let ((res-list (calibredb-candidates)))
      (with-current-buffer occur-buf
        (erase-buffer)
        (insert "#+STARTUP: inlineimages nofold"))
      (dolist (res res-list)
        (let ((cover (concat (file-name-directory (calibredb-getattr (cdr res) :file-path)) "cover.jpg"))
              (title (calibredb-getattr (cdr res) :book-title))
              (book (calibredb-getattr (cdr res) :file-path)))
          (if (file-exists-p cover)
              (with-current-buffer occur-buf
                (insert "\n")
                (insert "#+attr_org: :width 200px\n")
                (insert (concat "[[file:" cover "]]"))
                (insert "\n")
                (org-insert-link nil book title)
                ;; (insert "\n")
                ;; (setq start (point))
                ;; (insert title)
                ;; (calibredb-insert-image cover "")
                ;; (setq end (point))
                (insert "\n"))))))
    (when (buffer-live-p occur-buf)
      (switch-to-buffer-other-window occur-buf)
      (read-only-mode)
      (org-mode)
      (goto-char (point-min)))))

(defun calibredb-mouse-1 (event)
  "TODO: Copy the url click on.
Argument EVENT mouse event."
  (interactive "e")
  ;; (message "click mouse-2")
  (let ((window (posn-window (event-end event)))
        (pos (posn-point (event-end event))))
    (if (not (windowp window))
        (error "No URL chosen"))
    (with-current-buffer (window-buffer window)
      (goto-char pos)
      (let ((url (get-text-property (point) 'help-echo)))
        (find-file url)))))

(defun calibredb-getattr (my-alist key)
  (cadr (assoc key (car my-alist))))

(defun calibredb-insert-image (path alt)
  "TODO: Insert an image for PATH at point, falling back to ALT.
This function honors `shr-max-image-proportion' if possible."
  (cond
   ((not (display-graphic-p))
    (insert alt))
   ;; TODO: add native resizing support once it's official
   ((fboundp 'imagemagick-types)
    ;; adapted from `shr-rescale-image'
    (let ((edges (window-inside-pixel-edges
                  (get-buffer-window (current-buffer)))))
      (insert-image
       (create-image path 'imagemagick nil
                     :ascent 100
                     :max-width 500 ;; (truncate (* shr-max-image-proportion
                     ;;              (- (nth 2 edges)
                     ;;                 (nth 0 edges))))
                     :max-height 500;; (truncate (* shr-max-image-proportion
                     ;;              (- (nth 3 edges)
                     ;;                 (nth 1 edges))))
                     ))))
   (t
    ;; `create-image' errors out for unsupported image types
    (let ((image (ignore-errors (create-image path nil nil :ascent 100))))
      (if image
          (insert-image image)
        (insert alt))))))

(defun calibredb-find-file (&optional candidate)
  (interactive)
  (unless candidate
    (setq candidate calibredb-selected-entry))
  (find-file (calibredb-getattr candidate :file-path)))

(defun calibredb-find-file-other-frame (&optional candidate)
  (interactive)
  (unless candidate
    (setq candidate calibredb-selected-entry))
  (find-file-other-frame (calibredb-getattr candidate :file-path)))

(defun calibredb-open-file-with-default-tool (&optional candidate)
  (interactive)
  (unless candidate
    (setq candidate calibredb-selected-entry))
  (calibredb-open-with-default-tool (calibredb-getattr candidate :file-path)))

;; add

(defun calibredb-add ()
  "Add a file into calibre database."
  (interactive)
  (calibredb-command :command "add"
                     :input (calibredb-complete-file)))

(defun calibredb-complete-file (&optional arg)
  "Get file name using completion."
  (let ((file (read-file-name "File: ")))
    (expand-file-name file)))

;; remove

(defun calibredb-remove (candidate)
  (let ((id (calibredb-getattr candidate :id)))
    (calibredb-command :command "remove"
                       :id id)))

;; set_metadata

(defun calibredb-set-metadata--tags (&optional candidate)
  "Add tags, divided by comma, on marked candidates."
  (interactive)
  (unless candidate
    (setq candidate calibredb-selected-entry))
  (let ((last-input))
    (dolist (cand (cond ((memq this-command '(ivy-dispatching-done)) (list candidate))
                        ((memq this-command '(helm-maybe-exit-minibuffer)) (helm-marked-candidates))
                        (t (list candidate))))
      (let* ((title (calibredb-getattr cand :book-title))
             (tag (calibredb-getattr cand :tag))
             (id (calibredb-getattr cand :id))
             (input (or last-input (read-string (concat "Add tags for " title ": ") tag))))
        (calibredb-command :command "set_metadata"
                           :option "--field"
                           :input (format "tags:\"%s\"" input)
                           :id id)
        (setq last-input input)
        (when (equal major-mode 'calibredb-show-mode)
          ;; set the comments back, it is messy, will be improved later
          (setf (car (cdr (assoc :tag (car calibredb-selected-entry)))) input)
          (calibredb-show-refresh calibredb-selected-entry))))))

(defun calibredb-set-metadata--comments (&optional candidate)
  "Add comments on one candidate."
  (interactive)
  (unless candidate
    (setq candidate calibredb-selected-entry))
  (let* ((title (calibredb-getattr candidate :book-title))
         (comment (calibredb-getattr candidate :comment))
         (id (calibredb-getattr candidate :id))
         (input (read-string (concat "Add comments for " title ": ") comment)))
    (calibredb-command :command "set_metadata"
                       :option "--field"
                       :input (format "comments:\"%s\"" input)
                       :id id)
    (when (equal major-mode 'calibredb-show-mode)
      ;; set the comments back, it is messy, will be improved later
      (setf (car (cdr (assoc :comment (car calibredb-selected-entry)))) input)
      (calibredb-show-refresh calibredb-selected-entry))))

(defun calibredb-set-metadata--list-fields (&optional candidate)
  "List the selected candidate supported fileds."
  (interactive)
  (unless candidate
    (setq candidate calibredb-selected-entry))
  (let* ((id (calibredb-getattr candidate :id)))
    (message (calibredb-command :command "set_metadata"
                       :option "--list-fields"
                       :id id) )))

;; show_metadata

(defun calibredb-show-metadata (&optional candidate)
  "Show selected candidate metadata."
  (interactive)
  (unless candidate
    (setq candidate calibredb-selected-entry))
  (let* ((id (calibredb-getattr candidate :id)))
    (calibredb-command :command "show_metadata"
                       :id id)))

;; export

(defun calibredb-export (&optional candidate)
  "TODO: Export the selected candidate."
  (unless candidate
    (setq candidate calibredb-selected-entry))
  (let ((id (calibredb-getattr candidate :id)))
    (calibredb-command :command "export"
                       :options 
                       :id id)))

(defun calibredb-find-cover (candidate)
  "Open the cover page image of selected candidate."
  (if (get-buffer "cover.jpg")
      (kill-buffer "cover.jpg"))
  (let* ((path (calibredb-getattr candidate :file-path))
        (cover (concat (file-name-directory path) "cover.jpg")))
    (if (file-exists-p cover)
        (find-file cover)
      ;; (message "No cover")
      )))

(defun calibredb-item-string (book-alist)
  "Format the candidate string shown in helm or ivy."
  (format
   "%s\t%s %s %s %s %s %s%s"
   ;; (all-the-icons-icon-for-file (getattr book-alist :file-path))
   ;; (all-the-icons-icon-for-file (getattr book-alist :file-path))
   (propertize (calibredb-getattr (list book-alist) :id) 'face 'font-lock-keyword-face)
   (propertize (calibredb-getattr (list book-alist) :tag) 'face 'font-lock-warning-face)
   (propertize (calibredb-getattr (list book-alist) :book-format) 'face 'font-lock-string-face)
   (propertize (calibredb-getattr (list book-alist) :book-title) 'face 'default)
   (propertize (calibredb-getattr (list book-alist) :author-sort) 'face 'font-lock-variable-name-face)
   (if (stringp (calibredb-getattr (list book-alist) :comment))
       (propertize (calibredb-getattr (list book-alist) :comment) 'face 'font-lock-type-face)
     "")
   (propertize (calibredb-getattr (list book-alist) :size) 'face 'font-lock-comment-face)
   (propertize "Mb" 'face 'font-lock-comment-face)))

(defun calibredb-ivy-read ()
  (ivy-read "Pick a book: "
            (calibredb-candidates)
            :sort nil           ; actually sort them
            :caller 'calibredb-ivy-read))


(defun calibredb-getbooklist (calibre-item-list)
  (let (display-alist)
    (dolist (item calibre-item-list display-alist)
      (setq display-alist
            (cons (list (calibredb-item-string item) item) display-alist)))))

(defun calibredb-candidates()
  "Generate ebooks candidates alist."
  (let* ((query-result (calibredb-query calibredb-query-string))
         (line-list (split-string (calibredb-chomp query-result) "\n"))
         (num-result (length line-list)))
    (if (= 0 num-result)
        (progn
          (message "nothing found.")
          (deactivate-mark))
      (let ((res-list (mapcar #'(lambda (line) (calibredb-query-to-alist line)) line-list)))
        (calibredb-getbooklist res-list)))))

(defun calibredb-helm-read ()
  (helm :sources 'calibredb-helm-source
        :buffer "*helm calibredb*"))

(defun calibredb-find-helm ()
  "Use helm to list all ebooks details."
  (interactive)
  (calibredb-helm-read))

(defun calibredb-find-counsel ()
  "Use counsel to list all ebooks details."
  (interactive)
  (calibredb-ivy-read))

;; calibredb-mode-map functions

(defun calibredb-set-metadata--tags-1 ()
  (interactive)
  (with-helm-alive-p
    (helm-exit-and-execute-action #'calibredb-set-metadata--tags)))

(defun calibredb-set-metadata--comments-1 ()
  (interactive)
  (with-helm-alive-p
    (helm-exit-and-execute-action #'calibredb-set-metadata--comments)))

;; Transient dispatch

(defun calibredb-dispatch nil
  (transient-args 'calibredb-dispatch))

;;;###autoload
(define-transient-command calibredb-dispatch ()
  "Invoke a calibredb command from a list of available commands."
  ["calibredb commands"
   [("s" "set_metadata"   calibredb-set-metadata-dispatch)
    ("S" "show_metadata"         calibredb-show-metadata)]
   [("o" "Open file"         calibredb-find-file)
    ("O" "Open file other frame"            calibredb-find-file-other-frame)]
   [("v" "Open file with default tool"  calibredb-open-file-with-default-tool)]]
  (interactive)
  (transient-setup 'calibredb-dispatch))

(define-transient-command calibredb-set-metadata-dispatch ()
  "Create a new commit or replace an existing commit."
  [["Field"
    ("t" "tags"         calibredb-set-metadata--tags)
    ("c" "comments"         calibredb-set-metadata--comments)]
   ["List fields"
    ("l" "list fileds"         calibredb-set-metadata--list-fields)]]
  (interactive)
  (transient-setup 'calibredb-set-metadata-dispatch))

(defun calibredb-show-mode ()
  "Mode for displaying book entry details.
\\{calibredb-show-mode-map}"
  (interactive)
  (kill-all-local-variables)
  (use-local-map calibredb-show-mode-map)
  (setq major-mode 'calibredb-show-mode
        mode-name "calibredb-show"
        buffer-read-only t)
  (buffer-disable-undo)
  (run-mode-hooks 'calibredb-show-mode-hook))

(defun calibredb-show--buffer-name (entry)
  "Return the appropriate buffer name for ENTRY.
The result depends on the value of `calibredb-show-unique-buffers'."
  (if calibredb-show-unique-buffers
      (format "*calibredb-entry-<%s>*"
              (calibredb-getattr entry :book-title))
    "*calibredb-entry*"))

(defun calibredb-show-entry (entry)
  "Display ENTRY in the current buffer."
  (when (get-buffer (calibredb-show--buffer-name entry))
    (kill-buffer (calibredb-show--buffer-name entry)))
  (setq calibredb-selected-entry entry)
  (let ((buff (get-buffer-create (calibredb-show--buffer-name entry)))
        (cover (concat (file-name-directory (calibredb-getattr entry :file-path)) "cover.jpg")))
    (with-current-buffer buff
      ;; (setq start (point))
      ;; (insert title)
      (insert (calibredb-show-metadata entry))
      ;; (insert book)
      (insert "\n")
      (calibredb-insert-image cover "")
      ;; (setq end (point))
      (calibredb-show-mode)
      (setq calibredb-show-entry entry))
    (funcall calibredb-show-entry-switch buff)))

(defun calibredb-show-refresh (entry)
  "Refresh ENTRY in the current buffer."
  (setq calibredb-selected-entry entry)
  (let* ((inhibit-read-only t)
        (buff (get-buffer-create (calibredb-show--buffer-name entry)))
        (cover (concat (file-name-directory (calibredb-getattr entry :file-path)) "cover.jpg")))
    (with-current-buffer buff
      (erase-buffer)
      ;; (setq start (point))
      ;; (insert title)
      (insert (calibredb-show-metadata entry))
      ;; (insert book)
      (calibredb-insert-image cover "")
      ;; (setq end (point))
      (calibredb-show-mode)
      (setq calibredb-show-entry entry))
    (funcall calibredb-show-entry-switch buff)))

(provide 'calibredb)

;;; calibredb.el ends here
