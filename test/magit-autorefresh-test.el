;;; magit-autorefresh-test.el --- Tests for magit-autorefresh  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'magit)
(require 'magit-autorefresh)

(defvar magit-autorefresh-test--refreshes 0)

(defun magit-autorefresh-test--count (&rest _)
  (cl-incf magit-autorefresh-test--refreshes))

(defun magit-autorefresh-test--wait (buffer)
  "Wait until BUFFER has no in-flight poll."
  (with-timeout (10 (error "Poll did not finish"))
    (while (process-live-p (buffer-local-value 'magit-autorefresh--process buffer))
      (accept-process-output nil 0.05)))
  ;; Let the sentinel run.
  (accept-process-output nil 0.05))

(defun magit-autorefresh-test--git (&rest args)
  (unless (zerop (apply #'process-file "git" nil nil nil args))
    (error "git %S failed" args)))

(defmacro magit-autorefresh-test--with-repo (&rest body)
  "Run BODY with `buf' bound to a Magit status buffer of a fresh repo."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "mar-test" t)))
          (default-directory dir)
          (process-environment
           (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                     "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t")
                   process-environment))
          (magit-autorefresh-test--refreshes 0))
     (unwind-protect
         (progn
           (magit-autorefresh-test--git "init" "-q" "-b" "main")
           (write-region "one\n" nil (expand-file-name "a.txt" dir))
           (magit-autorefresh-test--git "add" "a.txt")
           (magit-autorefresh-test--git "commit" "-q" "-m" "init")
           (magit-autorefresh-mode 1)
           (let ((buf (magit-status-setup-buffer dir)))
             (switch-to-buffer buf)
             (magit-autorefresh-test--wait buf)
             (advice-add 'magit-refresh-buffer :before
                         #'magit-autorefresh-test--count)
             (unwind-protect (progn ,@body)
               (advice-remove 'magit-refresh-buffer
                              #'magit-autorefresh-test--count)
               (kill-buffer buf))))
       (magit-autorefresh-mode -1)
       (delete-directory dir t))))

(defun magit-autorefresh-test--poll (buf)
  (magit-autorefresh--poll buf)
  (magit-autorefresh-test--wait buf))

(ert-deftest magit-autorefresh-baseline-recorded ()
  (magit-autorefresh-test--with-repo
    (should (buffer-local-value 'magit-autorefresh--fingerprint buf))))

(ert-deftest magit-autorefresh-no-change-no-refresh ()
  (magit-autorefresh-test--with-repo
    (magit-autorefresh-test--poll buf)
    (magit-autorefresh-test--poll buf)
    (should (= magit-autorefresh-test--refreshes 0))))

(ert-deftest magit-autorefresh-external-edit-refreshes ()
  (magit-autorefresh-test--with-repo
    (write-region "two\n" nil (expand-file-name "a.txt" default-directory))
    (magit-autorefresh-test--poll buf)
    (should (= magit-autorefresh-test--refreshes 1))
    (with-current-buffer buf
      (should (string-match-p "a\\.txt" (buffer-string))))
    ;; The refresh resynced the fingerprint: no further refreshes.
    (magit-autorefresh-test--wait buf)
    (magit-autorefresh-test--poll buf)
    (should (= magit-autorefresh-test--refreshes 1))))

(ert-deftest magit-autorefresh-re-edit-of-modified-file-refreshes ()
  (magit-autorefresh-test--with-repo
    (let ((file (expand-file-name "a.txt" default-directory)))
      (write-region "two\n" nil file)
      (magit-autorefresh-test--poll buf)
      (magit-autorefresh-test--wait buf)
      ;; Status output stays " M a.txt"; only the mtime changes.
      (set-file-times file (time-add nil 10))
      (write-region "three\n" nil file)
      (set-file-times file (time-add nil 10))
      (magit-autorefresh-test--poll buf)
      (should (= magit-autorefresh-test--refreshes 2)))))

(ert-deftest magit-autorefresh-tick-polls-visible-buffers ()
  (magit-autorefresh-test--with-repo
    (should (memq buf (magit-autorefresh--visible-buffers)))
    (write-region "two\n" nil (expand-file-name "a.txt" default-directory))
    (magit-autorefresh--tick)
    (magit-autorefresh-test--wait buf)
    (should (= magit-autorefresh-test--refreshes 1))))

(ert-deftest magit-autorefresh-external-commit-refreshes ()
  (magit-autorefresh-test--with-repo
    (magit-autorefresh-test--git "commit" "-q" "--allow-empty" "-m" "ext")
    (magit-autorefresh-test--poll buf)
    (should (= magit-autorefresh-test--refreshes 1))))

(ert-deftest magit-autorefresh-deferred-while-region-active ()
  (magit-autorefresh-test--with-repo
    (write-region "two\n" nil (expand-file-name "a.txt" default-directory))
    (with-current-buffer buf
      (let ((transient-mark-mode t))
        (push-mark (point-min) t t)
        (goto-char (point-max))
        (magit-autorefresh-test--poll buf)
        (should (= magit-autorefresh-test--refreshes 0))
        (deactivate-mark)
        (magit-autorefresh-test--poll buf)
        (should (= magit-autorefresh-test--refreshes 1))))))

(ert-deftest magit-autorefresh-ignored-files-do-not-refresh ()
  (magit-autorefresh-test--with-repo
    (write-region "*.log\n" nil (expand-file-name ".gitignore" default-directory))
    (magit-autorefresh-test--git "add" ".gitignore")
    (magit-autorefresh-test--git "commit" "-q" "-m" "ignore")
    (magit-autorefresh-test--poll buf)
    (magit-autorefresh-test--wait buf)
    (setq magit-autorefresh-test--refreshes 0)
    (write-region "x\n" nil (expand-file-name "noise.log" default-directory))
    (magit-autorefresh-test--poll buf)
    (should (= magit-autorefresh-test--refreshes 0))))

;;; magit-autorefresh-test.el ends here
