;;; magit-autorefresh.el --- Refresh Magit buffers when the repository changes  -*- lexical-binding: t; -*-

;; Author: Tatu Lahtela
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (magit "4.0"))
;; Keywords: vc, git, tools

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Magit only refreshes its buffers after commands run from within
;; Emacs.  Changes made elsewhere (a terminal, another editor, an AI
;; agent, a cron job auto-committing) leave the status buffer stale.
;;
;; `magit-autorefresh-mode' polls every visible Magit status buffer on
;; a timer.  Each poll runs an asynchronous
;;
;;   git status --porcelain=v2 --branch --show-stash
;;
;; and hashes its output together with the modification times of the
;; listed paths.  When the fingerprint changes, the buffer is
;; refreshed.  Because the comparison is between snapshots, Magit's
;; own index writes cannot cause refresh loops, and ignored files
;; never trigger a refresh.
;;
;; Polling is cheap when Git's builtin filesystem monitor is enabled
;; (macOS and Windows, Git >= 2.37):
;;
;;   git config core.fsmonitor true
;;   git config core.untrackedCache true
;;
;; `magit-autorefresh-enable-fsmonitor' does this for the current
;; repository.
;;
;; Polls use GIT_OPTIONAL_LOCKS=0, so they never take `index.lock'
;; and cannot make concurrent git commands fail.
;;
;; Refreshes are deferred while the region is active in the buffer,
;; the minibuffer is in use, or a transient menu is open.  Buffers
;; that are not visible are not polled; they are checked as soon as
;; they are displayed again.
;;
;; Usage:
;;
;;   (use-package magit-autorefresh
;;     :after magit
;;     :config (magit-autorefresh-mode 1))

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'magit-mode)
(require 'magit-git)

(defvar magit-autorefresh-mode)
(defvar magit-this-process)
(defvar transient--prefix)

(defgroup magit-autorefresh nil
  "Refresh Magit buffers when the repository changes outside Emacs."
  :group 'magit-extensions
  :prefix "magit-autorefresh-")

(defcustom magit-autorefresh-interval 2.0
  "Seconds between polls of visible Magit buffers.
Changing this takes effect when `magit-autorefresh-mode' is re-enabled."
  :type 'number)

(defcustom magit-autorefresh-modes '(magit-status-mode)
  "Major modes (and their derivatives) whose buffers are auto-refreshed."
  :type '(repeat symbol))

(defcustom magit-autorefresh-untracked-files "all"
  "Value passed to `git status --untracked-files'.
\"all\" detects edits to files inside untracked directories but lists
every untracked file; \"normal\" is cheaper in repositories with large
untracked directories."
  :type '(choice (const "all") (const "normal") (const "no")))

(defvar magit-autorefresh--timer nil)
(defvar-local magit-autorefresh--fingerprint nil
  "Fingerprint of the repository state the buffer was last refreshed for.")
(defvar-local magit-autorefresh--process nil
  "In-flight poll process for this buffer, if any.")

(defconst magit-autorefresh--path-regexps
  '("^1 \\(?:[^ ]+ \\)\\{7\\}\\(.*\\)$"         ; ordinary change
    "^2 \\(?:[^ ]+ \\)\\{8\\}\\([^\t]*\\)"       ; rename/copy
    "^u \\(?:[^ ]+ \\)\\{9\\}\\(.*\\)$"         ; unmerged
    "^\\? \\(.*\\)$")                          ; untracked
  "Regexps extracting the path from `git status --porcelain=v2' lines.")

(defun magit-autorefresh--fingerprint (output)
  "Return a fingerprint for git status OUTPUT run in `default-directory'.
Modification times of the listed paths are included, because further
edits to an already modified file do not change the status output."
  (let ((parts (list output)))
    (dolist (line (split-string output "\n" t))
      (when-let* ((path (seq-some (lambda (re)
                                    (and (string-match re line)
                                         (match-string 1 line)))
                                  magit-autorefresh--path-regexps)))
        (push (format "%S" (file-attribute-modification-time
                            (file-attributes (expand-file-name path))))
              parts)))
    (secure-hash 'sha1 (apply #'concat parts))))

(defun magit-autorefresh--buffer-p (buffer)
  "Return non-nil if BUFFER should be auto-refreshed."
  (provided-mode-derived-p (buffer-local-value 'major-mode buffer)
                           magit-autorefresh-modes))

(defun magit-autorefresh--busy-p ()
  "Return non-nil if refreshing the current buffer now would disturb the user."
  (or (region-active-p)
      (active-minibuffer-window)
      (bound-and-true-p transient--prefix)
      (bound-and-true-p magit-this-process)))

(defun magit-autorefresh--visible-buffers ()
  "Return the auto-refreshable buffers shown in visible frames."
  (let (buffers)
    (dolist (frame (visible-frame-list))
      (dolist (window (window-list frame 'nomini))
        (let ((buffer (window-buffer window)))
          (when (magit-autorefresh--buffer-p buffer)
            (cl-pushnew buffer buffers)))))
    buffers))

(defun magit-autorefresh--poll (buffer &optional resync)
  "Start an asynchronous poll of the repository shown in BUFFER.
With RESYNC, cancel any in-flight poll and only record the new
fingerprint instead of comparing it."
  (with-current-buffer buffer
    (when (and resync (process-live-p magit-autorefresh--process))
      (delete-process magit-autorefresh--process))
    (unless (or (process-live-p magit-autorefresh--process)
                (file-remote-p default-directory))
      (let* ((process-environment
              (cons "GIT_OPTIONAL_LOCKS=0" process-environment))
             (chunks nil)
             (proc nil))
        (setq proc
              (make-process
               :name "magit-autorefresh"
               :command (list magit-git-executable "--no-pager"
                              "-c" "core.quotePath=false"
                              "status" "--porcelain=v2" "--branch"
                              "--show-stash"
                              (concat "--untracked-files="
                                      magit-autorefresh-untracked-files))
               :connection-type 'pipe
               :noquery t
               :stderr (get-buffer-create " *magit-autorefresh-stderr*")
               :filter (lambda (_proc string) (push string chunks))
               :sentinel
               (lambda (proc _event)
                 (unless (process-live-p proc)
                   (magit-autorefresh--handle
                    buffer proc (apply #'concat (nreverse chunks)) resync)))))
        (setq magit-autorefresh--process proc)))))

(defun magit-autorefresh--handle (buffer proc output resync)
  "Act on the OUTPUT of poll PROC for BUFFER.  See `magit-autorefresh--poll'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq proc magit-autorefresh--process)
        (setq magit-autorefresh--process nil)
        (when (and (eq (process-status proc) 'exit)
                   (zerop (process-exit-status proc)))
          (let ((fingerprint (magit-autorefresh--fingerprint output)))
            (cond
             ((or resync (null magit-autorefresh--fingerprint))
              (setq magit-autorefresh--fingerprint fingerprint))
             ((equal fingerprint magit-autorefresh--fingerprint))
             ;; Busy or hidden: keep the old fingerprint so a later
             ;; poll detects the change again.
             ((or (magit-autorefresh--busy-p)
                  (not (get-buffer-window buffer 'visible))))
             (t
              ;; `magit-autorefresh--after-refresh' records the new
              ;; fingerprint once the refresh is done.
              (magit-refresh-buffer)))))))))

(defun magit-autorefresh--tick ()
  "Poll every visible auto-refreshable buffer."
  (with-demoted-errors "magit-autorefresh: %S"
    (dolist (buffer (magit-autorefresh--visible-buffers))
      (magit-autorefresh--poll buffer))))

(defun magit-autorefresh--after-refresh ()
  "Record the repository state a buffer was just refreshed for.
Runs from `magit-refresh-buffer-hook', so refreshes started by Magit
itself do not trigger a redundant auto-refresh."
  (when (and magit-autorefresh-mode
             (magit-autorefresh--buffer-p (current-buffer)))
    (magit-autorefresh--poll (current-buffer) t)))

;;;###autoload
(define-minor-mode magit-autorefresh-mode
  "Refresh visible Magit buffers when the repository changes outside Emacs."
  :global t
  :group 'magit-autorefresh
  (when magit-autorefresh--timer
    (cancel-timer magit-autorefresh--timer)
    (setq magit-autorefresh--timer nil))
  (remove-hook 'magit-refresh-buffer-hook #'magit-autorefresh--after-refresh)
  (when magit-autorefresh-mode
    (add-hook 'magit-refresh-buffer-hook #'magit-autorefresh--after-refresh)
    (setq magit-autorefresh--timer
          (run-with-timer magit-autorefresh-interval
                          magit-autorefresh-interval
                          #'magit-autorefresh--tick))))

;;;###autoload
(defun magit-autorefresh-enable-fsmonitor ()
  "Enable Git's builtin fsmonitor and untracked cache in the current repository.
This makes the polls done by `magit-autorefresh-mode' cheap."
  (interactive)
  (let ((default-directory (or (magit-toplevel)
                               (user-error "Not inside a Git repository"))))
    (magit-git-success "config" "core.fsmonitor" "true")
    (magit-git-success "config" "core.untrackedCache" "true")
    (message "Enabled core.fsmonitor and core.untrackedCache in %s"
             (abbreviate-file-name default-directory))))

(provide 'magit-autorefresh)
;;; magit-autorefresh.el ends here
