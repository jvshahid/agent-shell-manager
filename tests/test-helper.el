;;; test-helper.el --- Test helpers for agent-shell-manager  -*- lexical-binding: t; -*-

;;; Commentary:

;; Helpers for the ERT suite.  We avoid loading the real `agent-shell'
;; package by stubbing the small abstraction layer in
;; `agent-shell-manager.el' via `cl-letf'.

;;; Code:

(require 'cl-lib)
(require 'ert)

(defvar agent-shell-manager-test--mock-sessions nil
  "List of mock session buffers used by stubbed abstraction layer.")

(defun agent-shell-manager-test--make-mock-session (name &optional cwd busy)
  "Create a mock agent-shell session buffer named NAME.
CWD becomes its `default-directory'.  BUSY is stored in a buffer-local
var consumed by the stubbed `--session-busy-p'."
  (let ((buf (generate-new-buffer name)))
    (with-current-buffer buf
      (setq default-directory (or cwd default-directory))
      (setq-local agent-shell-manager-test--busy busy))
    buf))

(defmacro agent-shell-manager-test--with-mock-sessions (sessions &rest body)
  "Bind SESSIONS as the mock session list and stub the abstraction layer.
Executes BODY with stubs installed.  All SESSIONS buffers are killed on
exit."
  (declare (indent 1) (debug t))
  `(let ((agent-shell-manager-test--mock-sessions ,sessions))
     (unwind-protect
         (cl-letf (((symbol-function 'agent-shell-manager--session-buffers)
                    (lambda ()
                      (cl-remove-if-not #'buffer-live-p
                                        agent-shell-manager-test--mock-sessions)))
                   ((symbol-function 'agent-shell-manager--session-busy-p)
                    (lambda (buf)
                      (buffer-local-value 'agent-shell-manager-test--busy buf))))
           ,@body)
       (dolist (buf agent-shell-manager-test--mock-sessions)
         (when (buffer-live-p buf)
           (let ((kill-buffer-query-functions nil))
             (kill-buffer buf)))))))

(defun agent-shell-manager-test--reset-state ()
  "Reset module state between tests."
  (clrhash agent-shell-manager--eshell-by-agent)
  (clrhash agent-shell-manager--unseen-idle)
  (clrhash agent-shell-manager--last-busy)
  (clrhash agent-shell-manager--coding-layout-by-agent)
  (setq agent-shell-manager--display-order nil)
  (setq agent-shell-manager--active-session nil)
  (setq agent-shell-manager--coding-pane-visible nil))

(provide 'test-helper)

;;; test-helper.el ends here
