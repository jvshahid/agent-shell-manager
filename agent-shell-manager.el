;;; agent-shell-manager.el --- Sidebar manager for agent-shell sessions  -*- lexical-binding: t; -*-

;; Author: John Shahid
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, processes

;;; Commentary:

;; A side-window panel that lists open `agent-shell' sessions and lets the
;; user switch between them quickly.  Selecting a session arranges the frame
;; so that the chosen agent buffer is on the top-right and a paired eshell
;; buffer is on the bottom-right.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'map)
(require 'tabulated-list)
(require 'eshell)

(declare-function agent-shell-buffers "agent-shell")
(declare-function agent-shell-new-shell "agent-shell")
(defvar agent-shell-preferred-agent-config)

;;;; Customization

(defgroup agent-shell-manager nil
  "Sidebar manager for `agent-shell' sessions."
  :group 'tools
  :prefix "agent-shell-manager-")

(defcustom agent-shell-manager-sidebar-width 0.3
  "Width of the sidebar side-window.
An integer is taken as a number of columns.  A float between 0 and 1 is
taken as a fraction of the selected frame's width."
  :type '(choice (integer :tag "Columns")
                 (float :tag "Fraction of frame width"))
  :group 'agent-shell-manager)

(defun agent-shell-manager--resolved-width ()
  "Return the sidebar width in columns, resolving fractions against the frame."
  (let ((w agent-shell-manager-sidebar-width))
    (cond
     ((integerp w) w)
     ((and (floatp w) (> w 0) (< w 1))
      (max 8 (floor (* w (frame-width)))))
     (t (user-error "Invalid `agent-shell-manager-sidebar-width': %S" w)))))

(defcustom agent-shell-manager-confirm-kill t
  "When non-nil, prompt for confirmation before killing a session via `k'."
  :type 'boolean
  :group 'agent-shell-manager)

(defcustom agent-shell-manager-busy-indicator "●"
  "Glyph shown for sessions that are currently busy."
  :type 'string
  :group 'agent-shell-manager)

(defcustom agent-shell-manager-idle-indicator " "
  "Glyph shown for sessions that are idle."
  :type 'string
  :group 'agent-shell-manager)

(defcustom agent-shell-manager-active-indicator "▶"
  "Glyph shown next to the currently active session."
  :type 'string
  :group 'agent-shell-manager)

(defcustom agent-shell-manager-inactive-indicator " "
  "Glyph shown next to sessions that are not currently active."
  :type 'string
  :group 'agent-shell-manager)

(defcustom agent-shell-manager-poll-interval 0.5
  "Seconds between background refreshes of the sidebar.
The poll runs only while the sidebar is visible.  Set to nil to disable
polling and rely solely on heartbeat advice."
  :type '(choice (number :tag "Seconds")
                 (const :tag "Disabled" nil))
  :group 'agent-shell-manager)

;;;; Abstraction layer over agent-shell
;;
;; All access to `agent-shell' internals goes through these functions.  Tests
;; override them with `cl-letf' to feed mock data without loading the real
;; package.

(defun agent-shell-manager--session-buffers ()
  "Return the list of live agent-shell session buffers, most-recent first."
  (when (fboundp 'agent-shell-buffers)
    (cl-remove-if-not #'buffer-live-p (funcall 'agent-shell-buffers))))

(defun agent-shell-manager--session-name (buffer)
  "Return a short display name for BUFFER."
  (let ((name (buffer-name buffer)))
    ;; Strip surrounding earmuffs and a leading "agent-shell" prefix so the
    ;; sidebar isn't dominated by boilerplate.
    (when (string-match "\\`\\*\\(.*\\)\\*\\'" name)
      (setq name (match-string 1 name)))
    name))

(defun agent-shell-manager--session-busy-p (buffer)
  "Return non-nil if BUFFER's agent is currently processing a request.
Checks `agent-shell''s heartbeat state, falling back to shell-maker's
buffer-local busy flag.  The heartbeat is `started' briefly before the
first tick promotes it to `busy', so we treat both as in-flight."
  (with-current-buffer buffer
    (or (and (boundp 'agent-shell--state)
             (memq (map-nested-elt agent-shell--state
                                   '(:heartbeat :status))
                   '(started busy)))
        (bound-and-true-p shell-maker--busy))))

(defun agent-shell-manager--session-cwd (buffer)
  "Return the working directory for BUFFER's session."
  (with-current-buffer buffer default-directory))

(defun agent-shell-manager--session-config (buffer)
  "Return the agent configuration alist for BUFFER's session, or nil."
  (with-current-buffer buffer
    (and (boundp 'agent-shell--state)
         (map-elt agent-shell--state :agent-config))))

(defun agent-shell-manager--session-id (buffer)
  "Return the ACP session id string for BUFFER, or nil."
  (with-current-buffer buffer
    (and (boundp 'agent-shell--state)
         (map-nested-elt agent-shell--state '(:session :id)))))

(cl-defun agent-shell-manager--start-shell (&key config session-id session-strategy)
  "Start a new agent-shell session and return its buffer.
CONFIG is the agent configuration alist.  SESSION-ID, if non-nil,
resumes that ACP session.  SESSION-STRATEGY, if non-nil, overrides
the buffer-local `agent-shell-session-strategy' on the new shell."
  (unless (fboundp 'agent-shell--start)
    (user-error "agent-shell is not loaded"))
  (funcall 'agent-shell--start
           :config config
           :session-id session-id
           :session-strategy session-strategy
           :new-session t
           :no-focus t))

;;;; Eshell pairing
;;
;; A hash table maps agent buffer -> paired eshell buffer.  Entries are
;; cleaned up when either buffer is killed.  Lookups recreate when needed.

(defconst agent-shell-manager--buffer-name "*Agent Sessions*"
  "Name of the sidebar buffer.")

(defvar agent-shell-manager--eshell-by-agent (make-hash-table :test 'eq)
  "Map from agent-shell buffer to its paired eshell buffer.")

(defvar agent-shell-manager--active-session nil
  "The agent buffer currently shown by the manager, or nil.")

(defvar agent-shell-manager--display-order nil
  "Stable ordering of session buffers as displayed in the sidebar.
Insulates the UI from reorderings of `agent-shell-buffers' (which
shuffles by recent access).  New sessions append; dead sessions drop.")

(defun agent-shell-manager--eshell-buffer-name (agent-buffer)
  "Return the eshell buffer name paired with AGENT-BUFFER."
  (format "*eshell: %s*" (agent-shell-manager--session-name agent-buffer)))

(defun agent-shell-manager--make-eshell-for (agent-buffer)
  "Create a fresh eshell paired with AGENT-BUFFER and return it."
  (let* ((default-directory (agent-shell-manager--session-cwd agent-buffer))
         (eshell-buffer-name (agent-shell-manager--eshell-buffer-name agent-buffer))
         (buf (save-window-excursion (eshell t))))
    (with-current-buffer buf
      (add-hook 'kill-buffer-hook
                (lambda ()
                  (remhash agent-buffer agent-shell-manager--eshell-by-agent))
                nil t))
    (puthash agent-buffer buf agent-shell-manager--eshell-by-agent)
    buf))

(defun agent-shell-manager--eshell-for (agent-buffer)
  "Return the eshell paired with AGENT-BUFFER, creating it if missing."
  (let ((existing (gethash agent-buffer agent-shell-manager--eshell-by-agent)))
    (if (buffer-live-p existing)
        existing
      (when existing
        (remhash agent-buffer agent-shell-manager--eshell-by-agent))
      (agent-shell-manager--make-eshell-for agent-buffer)))
  )

(defun agent-shell-manager--forget-eshell (agent-buffer)
  "Remove the eshell mapping for AGENT-BUFFER and kill the eshell if alive."
  (when-let ((eshell-buf (gethash agent-buffer agent-shell-manager--eshell-by-agent)))
    (remhash agent-buffer agent-shell-manager--eshell-by-agent)
    (when (buffer-live-p eshell-buf)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer eshell-buf)))))

(defun agent-shell-manager--on-agent-buffer-killed ()
  "Hook installed on agent buffers; clean up paired eshell and refresh sidebar."
  (agent-shell-manager--forget-eshell (current-buffer))
  (when (get-buffer agent-shell-manager--buffer-name)
    (run-at-time 0 nil #'agent-shell-manager-refresh)))

;;;; Tabulated-list display

(defun agent-shell-manager--entry-for (buffer)
  "Build a `tabulated-list-entries' row for session BUFFER.
The row id is BUFFER itself, so commands can recover it from point."
  (let ((active (if (eq buffer agent-shell-manager--active-session)
                    agent-shell-manager-active-indicator
                  agent-shell-manager-inactive-indicator))
        (busy (if (agent-shell-manager--session-busy-p buffer)
                  agent-shell-manager-busy-indicator
                agent-shell-manager-idle-indicator))
        (name (agent-shell-manager--session-name buffer)))
    (list buffer (vector active busy name))))

(defun agent-shell-manager--ordered-buffers ()
  "Return session buffers in stable display order.
Reconciles `agent-shell-manager--display-order' against the current set
of live sessions: dead entries are dropped, new entries are appended at
the end, and surviving entries keep their position."
  (let ((current (agent-shell-manager--session-buffers)))
    (setq agent-shell-manager--display-order
          (cl-remove-if-not (lambda (b) (memq b current))
                            agent-shell-manager--display-order))
    (dolist (b current)
      (unless (memq b agent-shell-manager--display-order)
        (setq agent-shell-manager--display-order
              (append agent-shell-manager--display-order (list b)))))
    agent-shell-manager--display-order))

(defun agent-shell-manager--entries ()
  "Return `tabulated-list-entries' for all live sessions."
  (mapcar #'agent-shell-manager--entry-for
          (agent-shell-manager--ordered-buffers)))

(defvar agent-shell-manager-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    map)
  "Keymap for `agent-shell-manager-mode'.")

(define-derived-mode agent-shell-manager-mode tabulated-list-mode "AgentMgr"
  "Major mode for the agent-shell session sidebar."
  (let ((width (agent-shell-manager--resolved-width)))
    (setq tabulated-list-format
          (vector
           `("" 1 nil)
           `("" 1 nil)
           `("Session" ,(max 8 (- width 4)) t))))
  (setq tabulated-list-padding 0)
  (setq tabulated-list-entries #'agent-shell-manager--entries)
  (tabulated-list-init-header))

(defun agent-shell-manager--get-or-create-buffer ()
  "Return the sidebar buffer, creating it if missing."
  (let ((buf (get-buffer agent-shell-manager--buffer-name)))
    (unless buf
      (setq buf (get-buffer-create agent-shell-manager--buffer-name))
      (with-current-buffer buf
        (agent-shell-manager-mode)))
    buf))

(defun agent-shell-manager-refresh ()
  "Refresh the sidebar list, preserving the visible cursor row.
The saved row is read from the sidebar window's `window-point' (not the
buffer's point, which drifts when the sidebar isn't the selected
window).  After repainting we re-sync `window-point' because
`tabulated-list-print' erases the buffer, which invalidates window-point
and would otherwise snap the visible cursor to the top of the sidebar."
  (interactive)
  (when-let ((buf (get-buffer agent-shell-manager--buffer-name)))
    (with-current-buffer buf
      (let* ((win (get-buffer-window buf t))
             (saved (save-excursion
                      (when win (goto-char (window-point win)))
                      (tabulated-list-get-id))))
        (tabulated-list-print t)
        (when saved
          (goto-char (point-min))
          (while (and (not (eobp))
                      (not (eq (tabulated-list-get-id) saved)))
            (forward-line 1))
          (when (eobp)
            (goto-char (point-min))))
        (when win
          (set-window-point win (point)))))))

;;;; Background polling
;;
;; The sidebar is repainted by a low-rate poll that runs only while the
;; sidebar is visible.  Polling tolerates any source of state change
;; (`agent-shell''s heartbeat, `shell-maker--busy', etc.) and avoids the
;; redisplay quirks of refreshing from inside process-filter callbacks.

(defvar agent-shell-manager--poll-timer nil
  "Repeating timer that refreshes the sidebar, or nil.")

(defvar agent-shell-manager--last-signature nil
  "Cached signature of the last rendered entries; cheap change-detector.")

(defun agent-shell-manager--signature ()
  "Return a value that changes when any visible session attribute changes."
  (mapcar (lambda (buf)
            (cons (buffer-name buf)
                  (and (buffer-live-p buf)
                       (agent-shell-manager--session-busy-p buf))))
          (agent-shell-manager--ordered-buffers)))

(defun agent-shell-manager--poll-tick ()
  "Refresh the sidebar if any session's display-relevant state changed."
  (if (not (get-buffer-window agent-shell-manager--buffer-name t))
      (agent-shell-manager--stop-polling)
    (let ((sig (agent-shell-manager--signature)))
      (unless (equal sig agent-shell-manager--last-signature)
        (setq agent-shell-manager--last-signature sig)
        (agent-shell-manager-refresh)))))

(defun agent-shell-manager--start-polling ()
  "Start the background poll timer if not already running."
  (when (and agent-shell-manager-poll-interval
             (not (timerp agent-shell-manager--poll-timer)))
    (setq agent-shell-manager--last-signature nil)
    (setq agent-shell-manager--poll-timer
          (run-with-timer agent-shell-manager-poll-interval
                          agent-shell-manager-poll-interval
                          #'agent-shell-manager--poll-tick))))

(defun agent-shell-manager--stop-polling ()
  "Cancel the background poll timer, if any."
  (when (timerp agent-shell-manager--poll-timer)
    (cancel-timer agent-shell-manager--poll-timer))
  (setq agent-shell-manager--poll-timer nil))

(defun agent-shell-manager--point-to-session (buffer)
  "Move point in the sidebar to the row whose id is BUFFER.
Updates window-point as well, so the move is visible even when the
sidebar window is not selected."
  (when-let ((sb (get-buffer agent-shell-manager--buffer-name)))
    (with-current-buffer sb
      (goto-char (point-min))
      (while (and (not (eobp))
                  (not (eq (tabulated-list-get-id) buffer)))
        (forward-line 1))
      (when-let ((win (get-buffer-window sb t)))
        (set-window-point win (point))))))

;;;; Sidebar window

(defun agent-shell-manager--display-sidebar (buffer)
  "Display BUFFER as a dedicated left side-window and return the window."
  (display-buffer-in-side-window
   buffer
   `((side . left)
     (slot . 0)
     (window-width . ,(agent-shell-manager--resolved-width))
     (dedicated . t)
     (window-parameters . ((no-other-window . nil)
                           (no-delete-other-windows . t))))))

(defun agent-shell-manager--sidebar-window ()
  "Return the live sidebar window, or nil."
  (when-let ((buf (get-buffer agent-shell-manager--buffer-name)))
    (get-buffer-window buf t)))

;;;###autoload
(defun agent-shell-manager-show ()
  "Show the agent sessions sidebar and focus it.
If there is an active session, point lands on its row."
  (interactive)
  (let* ((buf (agent-shell-manager--get-or-create-buffer))
         (win (or (agent-shell-manager--sidebar-window)
                  (agent-shell-manager--display-sidebar buf))))
    (with-current-buffer buf
      (tabulated-list-print t))
    (when (and agent-shell-manager--active-session
               (buffer-live-p agent-shell-manager--active-session))
      (agent-shell-manager--point-to-session
       agent-shell-manager--active-session))
    (agent-shell-manager--start-polling)
    (when win (select-window win))))

(defun agent-shell-manager-hide ()
  "Hide the agent sessions sidebar."
  (interactive)
  (agent-shell-manager--stop-polling)
  (when-let ((win (agent-shell-manager--sidebar-window)))
    (delete-window win)))

;;;###autoload
(defun agent-shell-manager-toggle ()
  "Toggle the agent sessions sidebar."
  (interactive)
  (if (agent-shell-manager--sidebar-window)
      (agent-shell-manager-hide)
    (agent-shell-manager-show)))

;;;; Layout activation

(defun agent-shell-manager--current-session ()
  "Return the agent buffer for the row at point, or signal a user error."
  (let ((buf (tabulated-list-get-id)))
    (unless (and buf (buffer-live-p buf))
      (user-error "No agent session on this line"))
    buf))

(defun agent-shell-manager--activate (agent-buffer &optional focus-agent)
  "Lay out the frame around AGENT-BUFFER.
Sidebar stays on the left; AGENT-BUFFER goes top-right; its paired eshell
goes bottom-right.  When FOCUS-AGENT is non-nil, select the agent window;
otherwise keep focus in the sidebar."
  (let* ((sidebar-win (agent-shell-manager--sidebar-window))
         (eshell-buf (agent-shell-manager--eshell-for agent-buffer)))
    (unless sidebar-win
      (user-error "Sidebar is not visible"))
    (setq agent-shell-manager--active-session agent-buffer)
    (agent-shell-manager-refresh)
    (agent-shell-manager--point-to-session agent-buffer)
    ;; Collapse everything except the sidebar, then split the main area.
    (let ((main-win (next-window sidebar-win nil 'visible)))
      (select-window main-win)
      (delete-other-windows main-win)
      (set-window-buffer main-win agent-buffer)
      (let ((bottom (split-window main-win nil 'below)))
        (set-window-buffer bottom eshell-buf))
      (if focus-agent
          (select-window main-win)
        (select-window sidebar-win)))))

;;;; Commands bound in the sidebar

(defun agent-shell-manager-next ()
  "Move to next session and activate it."
  (interactive)
  (forward-line 1)
  (when (eobp) (forward-line -1))
  (agent-shell-manager--activate (agent-shell-manager--current-session)))

(defun agent-shell-manager-previous ()
  "Move to previous session and activate it."
  (interactive)
  (forward-line -1)
  (agent-shell-manager--activate (agent-shell-manager--current-session)))

(defun agent-shell-manager-visit ()
  "Activate the session at point and focus the agent buffer."
  (interactive)
  (agent-shell-manager--activate (agent-shell-manager--current-session) t))

(cl-defun agent-shell-manager-new-session (directory &key force-select-config)
  "Create a new agent session in DIRECTORY and lay it out via the manager.
The current window configuration is preserved during creation so the new
agent buffer does not steal a window; the manager's layout activator then
arranges the frame and creates the paired eshell.

When FORCE-SELECT-CONFIG is non-nil, `agent-shell-preferred-agent-config'
is suppressed for this call so `agent-shell' prompts for which provider
to use.

Interactively prompts for the directory."
  (interactive
   (list (read-directory-name "New agent session in: " default-directory nil t)))
  (unless (fboundp 'agent-shell-new-shell)
    (user-error "agent-shell is not loaded"))
  (let* ((before (agent-shell-manager--session-buffers))
         (default-directory (expand-file-name directory))
         (agent-shell-preferred-agent-config
          (if force-select-config
              nil
            (and (boundp 'agent-shell-preferred-agent-config)
                 agent-shell-preferred-agent-config)))
         (new-buf (save-window-excursion
                    (funcall 'agent-shell-new-shell)
                    (car (cl-set-difference
                          (agent-shell-manager--session-buffers)
                          before)))))
    (agent-shell-manager-refresh)
    (when (buffer-live-p new-buf)
      (agent-shell-manager--activate new-buf t))))

(defun agent-shell-manager-new-session-pick-config (directory)
  "Create a new agent session in DIRECTORY, prompting for the provider.
Like `agent-shell-manager-new-session' but bypasses
`agent-shell-preferred-agent-config' so the agent picker is always
shown."
  (interactive
   (list (read-directory-name "New agent session in: " default-directory nil t)))
  (agent-shell-manager-new-session directory :force-select-config t))

(cl-defun agent-shell-manager--restart-at-point (&key resume session-strategy)
  "Restart the agent at point with the same agent config.
When RESUME is non-nil, pass the current ACP session id so the new
shell continues the same conversation.  When SESSION-STRATEGY is
non-nil, override the new shell's `agent-shell-session-strategy'.

The new buffer is spliced into the sidebar at the position the old
buffer occupied, and the paired eshell (if any) is carried over so
scrollback and working directory survive the restart."
  (let* ((old-agent (agent-shell-manager--current-session))
         (config (agent-shell-manager--session-config old-agent))
         (session-id (and resume (agent-shell-manager--session-id old-agent)))
         (directory (agent-shell-manager--session-cwd old-agent))
         (index (cl-position old-agent agent-shell-manager--display-order))
         (eshell-buf (gethash old-agent agent-shell-manager--eshell-by-agent))
         (was-active (eq old-agent agent-shell-manager--active-session))
         (name (agent-shell-manager--session-name old-agent))
         (prompt (if resume
                     (format "Restart agent session %s (resume conversation)? " name)
                   (format "Restart agent session %s (pick new or existing)? " name))))
    (unless config
      (user-error "Cannot determine agent config for this session"))
    (when (and resume (not session-id))
      (user-error "No session id available to resume"))
    (when (and agent-shell-manager-confirm-kill
               (not (yes-or-no-p prompt)))
      (user-error "Cancelled"))
    ;; Detach the paired eshell so the agent buffer's kill-buffer-hook
    ;; (which would otherwise kill it) leaves it alone.  We re-attach
    ;; once the replacement buffer exists.
    (when eshell-buf
      (remhash old-agent agent-shell-manager--eshell-by-agent))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer old-agent))
    (let* ((before (agent-shell-manager--session-buffers))
           (default-directory (expand-file-name directory))
           (_ (save-window-excursion
                (agent-shell-manager--start-shell
                 :config config
                 :session-id session-id
                 :session-strategy session-strategy)))
           (new-buf (car (cl-set-difference
                          (agent-shell-manager--session-buffers)
                          before))))
      (when (and new-buf (buffer-live-p new-buf))
        (when (and eshell-buf (buffer-live-p eshell-buf))
          (puthash new-buf eshell-buf agent-shell-manager--eshell-by-agent))
        (when index
          (setq agent-shell-manager--display-order
                (cl-remove new-buf agent-shell-manager--display-order))
          (let* ((order agent-shell-manager--display-order)
                 (pos (min index (length order))))
            (setq agent-shell-manager--display-order
                  (append (cl-subseq order 0 pos)
                          (list new-buf)
                          (cl-subseq order pos)))))
        (when was-active
          (setq agent-shell-manager--active-session new-buf))
        (agent-shell-manager-refresh)
        (agent-shell-manager--point-to-session new-buf))
      new-buf)))

(defun agent-shell-manager-restart-session ()
  "Restart the agent at point, resuming the same conversation.
Uses the same agent configuration and ACP session id as the existing
session, so the model and chat history are preserved."
  (interactive)
  (agent-shell-manager--restart-at-point :resume t))

(defun agent-shell-manager-restart-session-pick ()
  "Restart the agent at point, prompting for new or existing conversation.
Uses the same agent configuration but lets the agent prompt for
whether to start a fresh conversation or resume one of its existing
sessions."
  (interactive)
  (agent-shell-manager--restart-at-point :session-strategy 'prompt))

(defun agent-shell-manager-kill-session ()
  "Kill the agent buffer at point and its paired eshell."
  (interactive)
  (let* ((agent (agent-shell-manager--current-session))
         (name (agent-shell-manager--session-name agent)))
    (when (or (not agent-shell-manager-confirm-kill)
              (yes-or-no-p (format "Kill agent session %s? " name)))
      (agent-shell-manager--forget-eshell agent)
      (when (eq agent agent-shell-manager--active-session)
        (setq agent-shell-manager--active-session nil))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer agent))
      (agent-shell-manager-refresh))))

(let ((map agent-shell-manager-mode-map))
  (define-key map (kbd "n") #'agent-shell-manager-next)
  (define-key map (kbd "p") #'agent-shell-manager-previous)
  (define-key map (kbd "C-n") #'next-line)
  (define-key map (kbd "C-p") #'previous-line)
  (define-key map (kbd "RET") #'agent-shell-manager-visit)
  (define-key map (kbd "c") #'agent-shell-manager-new-session)
  (define-key map (kbd "C") #'agent-shell-manager-new-session-pick-config)
  (define-key map (kbd "r") #'agent-shell-manager-restart-session)
  (define-key map (kbd "R") #'agent-shell-manager-restart-session-pick)
  (define-key map (kbd "k") #'agent-shell-manager-kill-session)
  (define-key map (kbd "g") #'agent-shell-manager-refresh)
  (define-key map (kbd "q") #'agent-shell-manager-hide))

;;;; Hooks into agent-shell lifecycle

(defun agent-shell-manager--maybe-install-buffer-hooks ()
  "Install per-buffer hooks on the current agent-shell buffer."
  (add-hook 'kill-buffer-hook
            #'agent-shell-manager--on-agent-buffer-killed
            nil t)
  (agent-shell-manager-refresh))

(add-hook 'agent-shell-mode-hook
          #'agent-shell-manager--maybe-install-buffer-hooks)

(provide 'agent-shell-manager)

;;; agent-shell-manager.el ends here
