;;; agent-shell-manager-test.el --- ERT tests for agent-shell-manager  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'agent-shell-manager)
(require 'test-helper)

(defvar agent-shell-preferred-agent-config)

;;;; Abstraction layer

(ert-deftest agent-shell-manager-test/session-name-strips-earmuffs ()
  (let ((buf (generate-new-buffer "*claude code*")))
    (unwind-protect
        (should (equal "claude code"
                       (agent-shell-manager--session-name buf)))
      (kill-buffer buf))))

(ert-deftest agent-shell-manager-test/session-name-passes-plain-names ()
  (let ((buf (generate-new-buffer "weirdname")))
    (unwind-protect
        (should (equal "weirdname"
                       (agent-shell-manager--session-name buf)))
      (kill-buffer buf))))

(ert-deftest agent-shell-manager-test/session-busy-p-reads-heartbeat-status ()
  (let ((buf (generate-new-buffer "*s*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local agent-shell--state
                      '((:heartbeat . ((:status . busy)))))
          (should (agent-shell-manager--session-busy-p buf))
          (setq-local agent-shell--state
                      '((:heartbeat . ((:status . started)))))
          (should (agent-shell-manager--session-busy-p buf))
          (setq-local agent-shell--state
                      '((:heartbeat . ((:status . ended)))))
          (should-not (agent-shell-manager--session-busy-p buf))
          (setq-local agent-shell--state
                      '((:heartbeat . ((:status . idle)))))
          (should-not (agent-shell-manager--session-busy-p buf)))
      (kill-buffer buf))))

(ert-deftest agent-shell-manager-test/session-busy-p-falls-back-to-shell-maker-busy ()
  (let ((buf (generate-new-buffer "*s*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local shell-maker--busy t)
          (should (agent-shell-manager--session-busy-p buf))
          (setq-local shell-maker--busy nil)
          (should-not (agent-shell-manager--session-busy-p buf)))
      (kill-buffer buf))))

(ert-deftest agent-shell-manager-test/session-cwd-returns-default-directory ()
  (let ((buf (agent-shell-manager-test--make-mock-session
              "*s1*" "/tmp/")))
    (unwind-protect
        (should (equal "/tmp/"
                       (agent-shell-manager--session-cwd buf)))
      (kill-buffer buf))))

;;;; Eshell pairing

(ert-deftest agent-shell-manager-test/eshell-created-on-first-lookup ()
  (agent-shell-manager-test--reset-state)
  (let ((agent (agent-shell-manager-test--make-mock-session "*agent-a*" "/tmp/")))
    (unwind-protect
        (let ((eshell-buf (agent-shell-manager--eshell-for agent)))
          (should (buffer-live-p eshell-buf))
          (should (eq eshell-buf
                      (gethash agent agent-shell-manager--eshell-by-agent))))
      (agent-shell-manager--forget-eshell agent)
      (kill-buffer agent))))

(ert-deftest agent-shell-manager-test/eshell-reused-on-second-lookup ()
  (agent-shell-manager-test--reset-state)
  (let ((agent (agent-shell-manager-test--make-mock-session "*agent-b*" "/tmp/")))
    (unwind-protect
        (let ((first (agent-shell-manager--eshell-for agent))
              (second (agent-shell-manager--eshell-for agent)))
          (should (eq first second)))
      (agent-shell-manager--forget-eshell agent)
      (kill-buffer agent))))

(ert-deftest agent-shell-manager-test/eshell-recreated-after-manual-kill ()
  (agent-shell-manager-test--reset-state)
  (let ((agent (agent-shell-manager-test--make-mock-session "*agent-c*" "/tmp/")))
    (unwind-protect
        (let* ((first (agent-shell-manager--eshell-for agent))
               (_ (let ((kill-buffer-query-functions nil))
                    (kill-buffer first)))
               (second (agent-shell-manager--eshell-for agent)))
          (should-not (buffer-live-p first))
          (should (buffer-live-p second))
          (should-not (eq first second)))
      (agent-shell-manager--forget-eshell agent)
      (kill-buffer agent))))

(ert-deftest agent-shell-manager-test/eshell-buffer-name-format ()
  (let ((agent (generate-new-buffer "*my-agent*")))
    (unwind-protect
        (should (equal "*eshell: my-agent*"
                       (agent-shell-manager--eshell-buffer-name agent)))
      (kill-buffer agent))))

(ert-deftest agent-shell-manager-test/forget-eshell-kills-and-clears ()
  (agent-shell-manager-test--reset-state)
  (let ((agent (agent-shell-manager-test--make-mock-session "*agent-d*" "/tmp/")))
    (unwind-protect
        (let ((eshell-buf (agent-shell-manager--eshell-for agent)))
          (agent-shell-manager--forget-eshell agent)
          (should-not (buffer-live-p eshell-buf))
          (should-not (gethash agent agent-shell-manager--eshell-by-agent)))
      (kill-buffer agent))))

(ert-deftest agent-shell-manager-test/eshell-manual-kill-clears-mapping ()
  ;; When the user kills the eshell, the kill-buffer-hook should drop the
  ;; mapping so the next lookup recreates rather than returning a dead buffer.
  (agent-shell-manager-test--reset-state)
  (let ((agent (agent-shell-manager-test--make-mock-session "*agent-e*" "/tmp/")))
    (unwind-protect
        (let ((eshell-buf (agent-shell-manager--eshell-for agent)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer eshell-buf))
          (should-not (gethash agent agent-shell-manager--eshell-by-agent)))
      (kill-buffer agent))))

;;;; Tabulated-list entries

(ert-deftest agent-shell-manager-test/entry-shape-idle ()
  (let ((s1 (agent-shell-manager-test--make-mock-session
             "*agent-a*" "/tmp/" nil))
        (agent-shell-manager--active-session nil))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (let ((entry (agent-shell-manager--entry-for s1)))
        (should (eq (car entry) s1))
        (should (= (length (cadr entry)) 3))
        (should (equal (aref (cadr entry) 0) agent-shell-manager-inactive-indicator))
        (should (equal (aref (cadr entry) 1) agent-shell-manager-idle-indicator))
        (should (equal (aref (cadr entry) 2) "agent-a"))))))

(ert-deftest agent-shell-manager-test/entry-shape-busy ()
  (let ((s1 (agent-shell-manager-test--make-mock-session
             "*agent-busy*" "/tmp/" t))
        (agent-shell-manager--active-session nil))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (let ((entry (agent-shell-manager--entry-for s1)))
        (should (equal (aref (cadr entry) 1)
                       agent-shell-manager-busy-indicator))))))

(ert-deftest agent-shell-manager-test/entry-marks-active-session ()
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/"))
        (s2 (agent-shell-manager-test--make-mock-session "*b*" "/tmp/")))
    (agent-shell-manager-test--with-mock-sessions (list s1 s2)
      (let ((agent-shell-manager--active-session s2))
        (should (equal (aref (cadr (agent-shell-manager--entry-for s1)) 0)
                       agent-shell-manager-inactive-indicator))
        (should (equal (aref (cadr (agent-shell-manager--entry-for s2)) 0)
                       agent-shell-manager-active-indicator))))))

(ert-deftest agent-shell-manager-test/kill-clears-active-when-it-was-active ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/")))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (let ((buf (agent-shell-manager--get-or-create-buffer))
            (agent-shell-manager--active-session s1))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                (agent-shell-manager-kill-session))
              (should-not agent-shell-manager--active-session))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/kill-preserves-active-when-other-killed ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/"))
        (s2 (agent-shell-manager-test--make-mock-session "*b*" "/tmp/")))
    (agent-shell-manager-test--with-mock-sessions (list s1 s2)
      (let ((buf (agent-shell-manager--get-or-create-buffer))
            (agent-shell-manager--active-session s2))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              ;; Point on s1, kill it; s2 stays active.
              (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                (agent-shell-manager-kill-session))
              (should (eq agent-shell-manager--active-session s2)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/entries-preserves-order ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/"))
        (s2 (agent-shell-manager-test--make-mock-session "*b*" "/tmp/"))
        (s3 (agent-shell-manager-test--make-mock-session "*c*" "/tmp/")))
    (agent-shell-manager-test--with-mock-sessions (list s1 s2 s3)
      (let ((entries (agent-shell-manager--entries)))
        (should (equal (mapcar #'car entries) (list s1 s2 s3)))))))

(ert-deftest agent-shell-manager-test/order-is-stable-against-source-reorder ()
  (agent-shell-manager-test--reset-state)
  (let* ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/"))
         (s2 (agent-shell-manager-test--make-mock-session "*b*" "/tmp/"))
         (s3 (agent-shell-manager-test--make-mock-session "*c*" "/tmp/"))
         (order (list s1 s2 s3)))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-manager--session-buffers)
                   (lambda () order)))
          (should (equal (mapcar #'car (agent-shell-manager--entries))
                         (list s1 s2 s3)))
          ;; Simulate agent-shell-buffers shuffling on access.
          (setq order (list s3 s1 s2))
          (should (equal (mapcar #'car (agent-shell-manager--entries))
                         (list s1 s2 s3)))
          (setq order (list s2 s3 s1))
          (should (equal (mapcar #'car (agent-shell-manager--entries))
                         (list s1 s2 s3))))
      (mapc (lambda (b)
              (let ((kill-buffer-query-functions nil))
                (kill-buffer b)))
            (list s1 s2 s3)))))

(ert-deftest agent-shell-manager-test/order-appends-new-sessions ()
  (agent-shell-manager-test--reset-state)
  (let* ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/"))
         (s2 (agent-shell-manager-test--make-mock-session "*b*" "/tmp/"))
         (s3 (agent-shell-manager-test--make-mock-session "*c*" "/tmp/"))
         (order (list s1 s2)))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-manager--session-buffers)
                   (lambda () order)))
          (should (equal (mapcar #'car (agent-shell-manager--entries))
                         (list s1 s2)))
          ;; New session, returned at the head of the source list.
          (setq order (list s3 s1 s2))
          (should (equal (mapcar #'car (agent-shell-manager--entries))
                         (list s1 s2 s3))))
      (mapc (lambda (b)
              (let ((kill-buffer-query-functions nil))
                (kill-buffer b)))
            (list s1 s2 s3)))))

(ert-deftest agent-shell-manager-test/order-drops-dead-sessions ()
  (agent-shell-manager-test--reset-state)
  (let* ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/"))
         (s2 (agent-shell-manager-test--make-mock-session "*b*" "/tmp/"))
         (s3 (agent-shell-manager-test--make-mock-session "*c*" "/tmp/"))
         (order (list s1 s2 s3)))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-manager--session-buffers)
                   (lambda () order)))
          (agent-shell-manager--entries) ;; seed order
          (setq order (list s1 s3))
          (should (equal (mapcar #'car (agent-shell-manager--entries))
                         (list s1 s3))))
      (mapc (lambda (b)
              (let ((kill-buffer-query-functions nil))
                (kill-buffer b)))
            (list s1 s2 s3)))))

(ert-deftest agent-shell-manager-test/entries-empty-when-no-sessions ()
  (agent-shell-manager-test--reset-state)
  (agent-shell-manager-test--with-mock-sessions nil
    (should (null (agent-shell-manager--entries)))))

;;;; Unseen-idle tracking

(ert-deftest agent-shell-manager-test/unseen-idle-set-on-busy-to-idle-not-selected ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/" nil)))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (puthash s1 t agent-shell-manager--last-busy)
      (cl-letf (((symbol-function 'agent-shell-manager--buffer-selected-p)
                 (lambda (_) nil)))
        (agent-shell-manager--update-unseen-state))
      (should (gethash s1 agent-shell-manager--unseen-idle)))))

(ert-deftest agent-shell-manager-test/unseen-idle-not-set-when-selected ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/" nil)))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (puthash s1 t agent-shell-manager--last-busy)
      (cl-letf (((symbol-function 'agent-shell-manager--buffer-selected-p)
                 (lambda (_) t)))
        (agent-shell-manager--update-unseen-state))
      (should-not (gethash s1 agent-shell-manager--unseen-idle)))))

(ert-deftest agent-shell-manager-test/unseen-idle-cleared-when-buffer-selected ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/" nil)))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (puthash s1 t agent-shell-manager--unseen-idle)
      (cl-letf (((symbol-function 'agent-shell-manager--buffer-selected-p)
                 (lambda (_) t)))
        (agent-shell-manager--update-unseen-state))
      (should-not (gethash s1 agent-shell-manager--unseen-idle)))))

(ert-deftest agent-shell-manager-test/unseen-idle-not-cleared-by-mere-visibility ()
  ;; Being displayed in a window the user is not focused on must not clear
  ;; the marker — only selecting the buffer should.
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/" nil)))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (puthash s1 t agent-shell-manager--unseen-idle)
      (cl-letf (((symbol-function 'agent-shell-manager--buffer-selected-p)
                 (lambda (_) nil)))
        (agent-shell-manager--update-unseen-state))
      (should (gethash s1 agent-shell-manager--unseen-idle)))))

(ert-deftest agent-shell-manager-test/unseen-idle-no-transition-when-still-busy ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/" t)))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (puthash s1 t agent-shell-manager--last-busy)
      (cl-letf (((symbol-function 'agent-shell-manager--buffer-selected-p)
                 (lambda (_) nil)))
        (agent-shell-manager--update-unseen-state))
      (should-not (gethash s1 agent-shell-manager--unseen-idle)))))

(ert-deftest agent-shell-manager-test/unseen-idle-no-transition-when-never-busy ()
  ;; A session that's been idle the whole time should not be marked unseen
  ;; just because the user isn't focused on it.
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/" nil)))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (cl-letf (((symbol-function 'agent-shell-manager--buffer-selected-p)
                 (lambda (_) nil)))
        (agent-shell-manager--update-unseen-state)
        (agent-shell-manager--update-unseen-state))
      (should-not (gethash s1 agent-shell-manager--unseen-idle)))))

(ert-deftest agent-shell-manager-test/idle-to-busy-bounces-focus-to-sidebar ()
  ;; Submitting a prompt while focused on the agent buffer should kick
  ;; focus back to the sidebar, otherwise the user stays "selected" on
  ;; the agent and the busy→idle marker would never fire.
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/" t))
        (sidebar-win 'mock-sidebar)
        (selected 'agent-window)
        (selected-calls nil))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (puthash s1 nil agent-shell-manager--last-busy)
      (cl-letf (((symbol-function 'agent-shell-manager--buffer-selected-p)
                 (lambda (_) t))
                ((symbol-function 'agent-shell-manager--sidebar-window)
                 (lambda () sidebar-win))
                ((symbol-function 'selected-window)
                 (lambda () selected))
                ((symbol-function 'select-window)
                 (lambda (win &optional _norecord)
                   (push win selected-calls)
                   (setq selected win))))
        (agent-shell-manager--update-unseen-state))
      (should (equal selected-calls (list sidebar-win))))))

(ert-deftest agent-shell-manager-test/idle-to-busy-no-focus-change-when-unfocused ()
  ;; If the user isn't on the agent buffer when it goes busy, leave
  ;; whatever window they're in alone.
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/" t))
        (selected-calls nil))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (puthash s1 nil agent-shell-manager--last-busy)
      (cl-letf (((symbol-function 'agent-shell-manager--buffer-selected-p)
                 (lambda (_) nil))
                ((symbol-function 'agent-shell-manager--sidebar-window)
                 (lambda () 'mock-sidebar))
                ((symbol-function 'selected-window)
                 (lambda () 'other-window))
                ((symbol-function 'select-window)
                 (lambda (win &optional _norecord)
                   (push win selected-calls))))
        (agent-shell-manager--update-unseen-state))
      (should-not selected-calls))))

(ert-deftest agent-shell-manager-test/first-observation-not-treated-as-transition ()
  ;; A brand-new session observed for the first time as busy must not be
  ;; mistaken for an idle→busy transition (no prior recording exists).
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/" t))
        (selected-calls nil))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (cl-letf (((symbol-function 'agent-shell-manager--buffer-selected-p)
                 (lambda (_) t))
                ((symbol-function 'agent-shell-manager--sidebar-window)
                 (lambda () 'mock-sidebar))
                ((symbol-function 'selected-window)
                 (lambda () 'agent-window))
                ((symbol-function 'select-window)
                 (lambda (win &optional _norecord)
                   (push win selected-calls))))
        (agent-shell-manager--update-unseen-state))
      (should-not selected-calls))))

(ert-deftest agent-shell-manager-test/update-cleans-up-stale-entries ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/" nil))
        (s2 (agent-shell-manager-test--make-mock-session "*b*" "/tmp/" nil)))
    (unwind-protect
        (agent-shell-manager-test--with-mock-sessions (list s2)
          (puthash s1 t agent-shell-manager--unseen-idle)
          (puthash s1 t agent-shell-manager--last-busy)
          (cl-letf (((symbol-function 'agent-shell-manager--buffer-selected-p)
                     (lambda (_) nil)))
            (agent-shell-manager--update-unseen-state))
          (should-not (gethash s1 agent-shell-manager--unseen-idle))
          (should-not (gethash s1 agent-shell-manager--last-busy)))
      (when (buffer-live-p s1)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer s1))))))

(ert-deftest agent-shell-manager-test/entry-applies-face-when-unseen ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/" nil)))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (puthash s1 t agent-shell-manager--unseen-idle)
      (let* ((entry (agent-shell-manager--entry-for s1))
             (name (aref (cadr entry) 2)))
        (should (eq (get-text-property 0 'face name)
                    'agent-shell-manager-unseen-idle))))))

(ert-deftest agent-shell-manager-test/entry-no-face-when-not-unseen ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/" nil)))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (let* ((entry (agent-shell-manager--entry-for s1))
             (name (aref (cadr entry) 2)))
        (should-not (get-text-property 0 'face name))))))

(ert-deftest agent-shell-manager-test/on-agent-buffer-killed-clears-unseen ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/" nil)))
    (puthash s1 t agent-shell-manager--unseen-idle)
    (puthash s1 t agent-shell-manager--last-busy)
    (with-current-buffer s1
      (agent-shell-manager--on-agent-buffer-killed))
    (should-not (gethash s1 agent-shell-manager--unseen-idle))
    (should-not (gethash s1 agent-shell-manager--last-busy))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer s1))))

;;;; Sidebar buffer

(ert-deftest agent-shell-manager-test/get-or-create-buffer-uses-mode ()
  (let ((buf (agent-shell-manager--get-or-create-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (should (derived-mode-p 'agent-shell-manager-mode))
          (should (derived-mode-p 'tabulated-list-mode)))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf)))))

(ert-deftest agent-shell-manager-test/refresh-populates-entries ()
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/" nil))
        (s2 (agent-shell-manager-test--make-mock-session "*b*" "/tmp/" t)))
    (agent-shell-manager-test--with-mock-sessions (list s1 s2)
      (let ((buf (agent-shell-manager--get-or-create-buffer)))
        (unwind-protect
            (progn
              (with-current-buffer buf (tabulated-list-print t))
              (with-current-buffer buf
                (goto-char (point-min))
                (should (eq (tabulated-list-get-id) s1))
                (forward-line 1)
                (should (eq (tabulated-list-get-id) s2))))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/refresh-preserves-window-point-when-sidebar-unselected ()
  ;; Regression: when the sidebar is shown in an unselected window, refresh
  ;; must read the saved row from window-point (not buffer point) and re-sync
  ;; window-point after `tabulated-list-print' erases the buffer.
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/"))
        (s2 (agent-shell-manager-test--make-mock-session "*b*" "/tmp/"))
        (s3 (agent-shell-manager-test--make-mock-session "*c*" "/tmp/")))
    (agent-shell-manager-test--with-mock-sessions (list s1 s2 s3)
      (let* ((buf (agent-shell-manager--get-or-create-buffer))
             (win (display-buffer-in-side-window
                   buf '((side . left) (slot . 0)))))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (tabulated-list-print t)
                ;; Place window-point on s2; force buffer point elsewhere
                ;; so the two diverge (mirroring the unselected-window case).
                (goto-char (point-min))
                (forward-line 1)
                (set-window-point win (point))
                (goto-char (point-min)))
              (agent-shell-manager-refresh)
              (with-selected-window win
                (should (eq (tabulated-list-get-id) s2))))
          (when (window-live-p win) (delete-window win))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/show-lands-on-active-session ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/"))
        (s2 (agent-shell-manager-test--make-mock-session "*b*" "/tmp/"))
        (s3 (agent-shell-manager-test--make-mock-session "*c*" "/tmp/")))
    (agent-shell-manager-test--with-mock-sessions (list s1 s2 s3)
      (unwind-protect
          (cl-letf (((symbol-function 'agent-shell-manager--display-sidebar)
                     (lambda (_) nil))
                    ((symbol-function 'select-window)
                     (lambda (&rest _) nil)))
            (setq agent-shell-manager--active-session s2)
            (agent-shell-manager-show)
            (with-current-buffer agent-shell-manager--buffer-name
              (should (eq (tabulated-list-get-id) s2))))
        (when-let ((b (get-buffer agent-shell-manager--buffer-name)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer b)))))))

(ert-deftest agent-shell-manager-test/show-with-no-active-falls-back-to-top ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/"))
        (s2 (agent-shell-manager-test--make-mock-session "*b*" "/tmp/")))
    (agent-shell-manager-test--with-mock-sessions (list s1 s2)
      (unwind-protect
          (cl-letf (((symbol-function 'agent-shell-manager--display-sidebar)
                     (lambda (_) nil))
                    ((symbol-function 'select-window)
                     (lambda (&rest _) nil)))
            (setq agent-shell-manager--active-session nil)
            (agent-shell-manager-show)
            (with-current-buffer agent-shell-manager--buffer-name
              (should (eq (tabulated-list-get-id) s1))))
        (when-let ((b (get-buffer agent-shell-manager--buffer-name)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer b)))))))

(ert-deftest agent-shell-manager-test/point-to-session-moves-point ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/"))
        (s2 (agent-shell-manager-test--make-mock-session "*b*" "/tmp/"))
        (s3 (agent-shell-manager-test--make-mock-session "*c*" "/tmp/")))
    (agent-shell-manager-test--with-mock-sessions (list s1 s2 s3)
      (let ((buf (agent-shell-manager--get-or-create-buffer)))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              (agent-shell-manager--point-to-session s3)
              (should (eq (tabulated-list-get-id) s3))
              (agent-shell-manager--point-to-session s1)
              (should (eq (tabulated-list-get-id) s1)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

;;;; Kill-session

(ert-deftest agent-shell-manager-test/kill-session-kills-agent-and-eshell ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/")))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (let ((eshell-buf (agent-shell-manager--eshell-for s1))
            (buf (agent-shell-manager--get-or-create-buffer)))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                (agent-shell-manager-kill-session))
              (should-not (buffer-live-p s1))
              (should-not (buffer-live-p eshell-buf))
              (should-not (gethash s1 agent-shell-manager--eshell-by-agent)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/kill-session-aborts-when-declined ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/")))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (let ((eshell-buf (agent-shell-manager--eshell-for s1))
            (buf (agent-shell-manager--get-or-create-buffer)))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
                (agent-shell-manager-kill-session))
              (should (buffer-live-p s1))
              (should (buffer-live-p eshell-buf)))
          (agent-shell-manager--forget-eshell s1)
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/kill-session-no-confirm-when-disabled ()
  (agent-shell-manager-test--reset-state)
  (let ((s1 (agent-shell-manager-test--make-mock-session "*a*" "/tmp/"))
        (agent-shell-manager-confirm-kill nil))
    (agent-shell-manager-test--with-mock-sessions (list s1)
      (let ((buf (agent-shell-manager--get-or-create-buffer))
            (prompted nil))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              (cl-letf (((symbol-function 'yes-or-no-p)
                         (lambda (&rest _) (setq prompted t) t)))
                (agent-shell-manager-kill-session))
              (should-not prompted)
              (should-not (buffer-live-p s1)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

;;;; Resolved width

(ert-deftest agent-shell-manager-test/resolved-width-integer-passthrough ()
  (let ((agent-shell-manager-sidebar-width 40))
    (should (= 40 (agent-shell-manager--resolved-width)))))

(ert-deftest agent-shell-manager-test/resolved-width-fraction-uses-frame ()
  (let ((agent-shell-manager-sidebar-width 0.3))
    (cl-letf (((symbol-function 'frame-width) (lambda (&optional _) 200)))
      (should (= 60 (agent-shell-manager--resolved-width))))))

(ert-deftest agent-shell-manager-test/resolved-width-fraction-clamps-min ()
  (let ((agent-shell-manager-sidebar-width 0.01))
    (cl-letf (((symbol-function 'frame-width) (lambda (&optional _) 100)))
      (should (= 8 (agent-shell-manager--resolved-width))))))

(ert-deftest agent-shell-manager-test/resolved-width-invalid-signals ()
  (let ((agent-shell-manager-sidebar-width 1.5))
    (should-error (agent-shell-manager--resolved-width)
                  :type 'user-error)))

;;;; New-session

(ert-deftest agent-shell-manager-test/new-session-uses-directory-as-default-directory ()
  (let* ((seen-default-dir nil)
         (fake-buf (generate-new-buffer "*new-agent*"))
         (sessions '()))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-new-shell)
                   (lambda ()
                     (setq seen-default-dir default-directory)
                     (push fake-buf sessions)))
                  ((symbol-function 'agent-shell-manager--session-buffers)
                   (lambda () sessions))
                  ((symbol-function 'agent-shell-manager--activate)
                   (lambda (&rest _) nil)))
          (agent-shell-manager-new-session "/tmp/")
          (should (equal seen-default-dir (expand-file-name "/tmp/"))))
      (kill-buffer fake-buf))))

(ert-deftest agent-shell-manager-test/new-session-discovers-buffer-via-diff ()
  (let* ((existing (generate-new-buffer "*existing*"))
         (fake-buf (generate-new-buffer "*new-agent*"))
         (sessions (list existing))
         (activated nil))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-new-shell)
                   (lambda () (push fake-buf sessions)))
                  ((symbol-function 'agent-shell-manager--session-buffers)
                   (lambda () sessions))
                  ((symbol-function 'agent-shell-manager--activate)
                   (lambda (buf _focus) (setq activated buf))))
          (agent-shell-manager-new-session "/tmp/")
          (should (eq activated fake-buf)))
      (kill-buffer existing)
      (kill-buffer fake-buf))))

(ert-deftest agent-shell-manager-test/new-session-preserves-window-config ()
  (let ((fake-buf (generate-new-buffer "*new-agent*"))
        (sessions '())
        (calls nil))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-new-shell)
                   (lambda ()
                     (switch-to-buffer fake-buf)
                     (push fake-buf sessions)
                     (push 'created calls)))
                  ((symbol-function 'agent-shell-manager--session-buffers)
                   (lambda () sessions))
                  ((symbol-function 'agent-shell-manager--activate)
                   (lambda (buf _) (push (cons 'activated buf) calls))))
          (agent-shell-manager-new-session "/tmp/")
          (should (equal (reverse calls)
                         `(created (activated . ,fake-buf))))
          (should-not (eq (window-buffer (selected-window)) fake-buf)))
      (kill-buffer fake-buf))))

(ert-deftest agent-shell-manager-test/new-session-activates-with-focus ()
  (let ((fake-buf (generate-new-buffer "*new-agent*"))
        (sessions '())
        (focus-arg 'unset))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-new-shell)
                   (lambda () (push fake-buf sessions)))
                  ((symbol-function 'agent-shell-manager--session-buffers)
                   (lambda () sessions))
                  ((symbol-function 'agent-shell-manager--activate)
                   (lambda (_buf focus) (setq focus-arg focus))))
          (agent-shell-manager-new-session "/tmp/")
          (should (eq focus-arg t)))
      (kill-buffer fake-buf))))

(ert-deftest agent-shell-manager-test/new-session-without-force-keeps-preferred ()
  (let ((seen 'unset)
        (fake-buf (generate-new-buffer "*new-agent*"))
        (sessions '())
        (agent-shell-preferred-agent-config 'claude))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-new-shell)
                   (lambda ()
                     (setq seen agent-shell-preferred-agent-config)
                     (push fake-buf sessions)))
                  ((symbol-function 'agent-shell-manager--session-buffers)
                   (lambda () sessions))
                  ((symbol-function 'agent-shell-manager--activate)
                   (lambda (&rest _) nil)))
          (agent-shell-manager-new-session "/tmp/")
          (should (eq seen 'claude)))
      (kill-buffer fake-buf))))

(ert-deftest agent-shell-manager-test/new-session-with-force-suppresses-preferred ()
  (let ((seen 'unset)
        (fake-buf (generate-new-buffer "*new-agent*"))
        (sessions '())
        (agent-shell-preferred-agent-config 'claude))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-new-shell)
                   (lambda ()
                     (setq seen agent-shell-preferred-agent-config)
                     (push fake-buf sessions)))
                  ((symbol-function 'agent-shell-manager--session-buffers)
                   (lambda () sessions))
                  ((symbol-function 'agent-shell-manager--activate)
                   (lambda (&rest _) nil)))
          (agent-shell-manager-new-session "/tmp/" :force-select-config t)
          (should (null seen))
          ;; The outer value is restored after the call.
          (should (eq agent-shell-preferred-agent-config 'claude)))
      (kill-buffer fake-buf))))

(ert-deftest agent-shell-manager-test/new-session-pick-config-forces-selection ()
  (let ((seen 'unset)
        (fake-buf (generate-new-buffer "*new-agent*"))
        (sessions '())
        (agent-shell-preferred-agent-config 'claude))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-new-shell)
                   (lambda ()
                     (setq seen agent-shell-preferred-agent-config)
                     (push fake-buf sessions)))
                  ((symbol-function 'agent-shell-manager--session-buffers)
                   (lambda () sessions))
                  ((symbol-function 'agent-shell-manager--activate)
                   (lambda (&rest _) nil)))
          (agent-shell-manager-new-session-pick-config "/tmp/")
          (should (null seen)))
      (kill-buffer fake-buf))))

(ert-deftest agent-shell-manager-test/new-session-errors-when-agent-shell-missing ()
  (cl-letf (((symbol-function 'fboundp)
             (lambda (sym) (not (eq sym 'agent-shell-new-shell)))))
    (should-error (agent-shell-manager-new-session "/tmp/")
                  :type 'user-error)))

;;;; Restart

(defmacro agent-shell-manager-test--with-restart-sessions (sessions bindings &rest body)
  "Run BODY with SESSIONS mocked and `--start-shell' stubbed.

BINDINGS is a plist supporting:
  :captured-args  a symbol bound to a list that collects the keyword
                  args passed to `--start-shell'.
  :new-buffer-fn  a function returning the buffer to install as the
                  newly-created session.  Called with no arguments
                  from inside the stubbed `--start-shell'.  The
                  returned buffer is appended to the mock session
                  list so the diff used by the restart helper picks
                  it up.

`yes-or-no-p' is stubbed to auto-confirm so the body does not block
on the restart confirmation prompt.  Tests exercising the prompt
itself should override the stub locally."
  (declare (indent 2) (debug t))
  (let ((captured (plist-get bindings :captured-args))
        (new-fn (plist-get bindings :new-buffer-fn)))
    `(agent-shell-manager-test--with-mock-sessions ,sessions
       (cl-letf (((symbol-function 'agent-shell-manager--start-shell)
                  (lambda (&rest args)
                    ,(when captured `(setq ,captured args))
                    (let ((new (funcall ,new-fn)))
                      (push new agent-shell-manager-test--mock-sessions)
                      new)))
                 ((symbol-function 'agent-shell-manager--session-config)
                  (lambda (buf)
                    (buffer-local-value 'agent-shell-manager-test--config buf)))
                 ((symbol-function 'agent-shell-manager--session-id)
                  (lambda (buf)
                    (buffer-local-value 'agent-shell-manager-test--session-id buf)))
                 ((symbol-function 'yes-or-no-p)
                  (lambda (&rest _) t)))
         ,@body))))

(defun agent-shell-manager-test--make-restartable-session
    (name cwd &optional config session-id)
  "Like `--make-mock-session' but also sets stub config/session-id."
  (let ((buf (agent-shell-manager-test--make-mock-session name cwd)))
    (with-current-buffer buf
      (setq-local agent-shell-manager-test--config (or config 'mock-config))
      (setq-local agent-shell-manager-test--session-id session-id))
    buf))

(ert-deftest agent-shell-manager-test/restart-preserves-position ()
  (agent-shell-manager-test--reset-state)
  (let* ((s1 (agent-shell-manager-test--make-restartable-session
              "*a*" "/tmp/" 'cfg-a "id-a"))
         (s2 (agent-shell-manager-test--make-restartable-session
              "*b*" "/tmp/" 'cfg-b "id-b"))
         (s3 (agent-shell-manager-test--make-restartable-session
              "*c*" "/tmp/" 'cfg-c "id-c"))
         (captured nil))
    (agent-shell-manager-test--with-restart-sessions (list s1 s2 s3)
        (:captured-args captured
         :new-buffer-fn (lambda ()
                          (agent-shell-manager-test--make-restartable-session
                           "*b-new*" "/tmp/" 'cfg-b "id-b")))
      (let ((buf (agent-shell-manager--get-or-create-buffer)))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              (forward-line 1) ;; on s2
              (agent-shell-manager-restart-session)
              (should-not (buffer-live-p s2))
              ;; The middle slot should still be the restarted session.
              (should (= 3 (length agent-shell-manager--display-order)))
              (should (eq s1 (nth 0 agent-shell-manager--display-order)))
              (should (eq s3 (nth 2 agent-shell-manager--display-order)))
              (let ((new (nth 1 agent-shell-manager--display-order)))
                (should (buffer-live-p new))
                (should-not (eq new s2))))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/restart-passes-same-config-and-session-id ()
  (agent-shell-manager-test--reset-state)
  (let* ((s1 (agent-shell-manager-test--make-restartable-session
              "*a*" "/tmp/" 'cfg-claude "sess-42"))
         (captured nil))
    (agent-shell-manager-test--with-restart-sessions (list s1)
        (:captured-args captured
         :new-buffer-fn (lambda ()
                          (agent-shell-manager-test--make-restartable-session
                           "*a-new*" "/tmp/" 'cfg-claude "sess-42")))
      (let ((buf (agent-shell-manager--get-or-create-buffer)))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              (agent-shell-manager-restart-session)
              (should (eq (plist-get captured :config) 'cfg-claude))
              (should (equal (plist-get captured :session-id) "sess-42"))
              (should (null (plist-get captured :session-strategy))))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/restart-pick-uses-prompt-strategy ()
  (agent-shell-manager-test--reset-state)
  (let* ((s1 (agent-shell-manager-test--make-restartable-session
              "*a*" "/tmp/" 'cfg-claude "sess-42"))
         (captured nil))
    (agent-shell-manager-test--with-restart-sessions (list s1)
        (:captured-args captured
         :new-buffer-fn (lambda ()
                          (agent-shell-manager-test--make-restartable-session
                           "*a-new*" "/tmp/" 'cfg-claude nil)))
      (let ((buf (agent-shell-manager--get-or-create-buffer)))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              (agent-shell-manager-restart-session-pick)
              (should (eq (plist-get captured :config) 'cfg-claude))
              (should (null (plist-get captured :session-id)))
              (should (eq (plist-get captured :session-strategy) 'prompt)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/restart-preserves-eshell-pairing ()
  (agent-shell-manager-test--reset-state)
  (let* ((s1 (agent-shell-manager-test--make-restartable-session
              "*a*" "/tmp/" 'cfg-a "id-a"))
         (eshell-buf (agent-shell-manager--eshell-for s1)))
    (agent-shell-manager-test--with-restart-sessions (list s1)
        (:captured-args _
         :new-buffer-fn (lambda ()
                          (agent-shell-manager-test--make-restartable-session
                           "*a-new*" "/tmp/" 'cfg-a "id-a")))
      (let ((buf (agent-shell-manager--get-or-create-buffer)))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              (agent-shell-manager-restart-session)
              (let ((new (car agent-shell-manager--display-order)))
                (should (buffer-live-p eshell-buf))
                (should (eq eshell-buf
                            (gethash new agent-shell-manager--eshell-by-agent)))
                (should-not (gethash s1 agent-shell-manager--eshell-by-agent))))
          (agent-shell-manager--forget-eshell
           (car agent-shell-manager--display-order))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/restart-preserves-active-pointer ()
  (agent-shell-manager-test--reset-state)
  (let* ((s1 (agent-shell-manager-test--make-restartable-session
              "*a*" "/tmp/" 'cfg-a "id-a"))
         (s2 (agent-shell-manager-test--make-restartable-session
              "*b*" "/tmp/" 'cfg-b "id-b")))
    (agent-shell-manager-test--with-restart-sessions (list s1 s2)
        (:captured-args _
         :new-buffer-fn (lambda ()
                          (agent-shell-manager-test--make-restartable-session
                           "*a-new*" "/tmp/" 'cfg-a "id-a")))
      (let ((buf (agent-shell-manager--get-or-create-buffer))
            (agent-shell-manager--active-session s1))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min)) ;; on s1
              (agent-shell-manager-restart-session)
              (should (eq agent-shell-manager--active-session
                          (car agent-shell-manager--display-order))))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/restart-replaces-displayed-buffer ()
  ;; Regression: killing the old buffer evicts it from any window, so the
  ;; layout's main window ends up showing some unrelated replacement.  The
  ;; restart must put the new buffer back into those windows so the sidebar
  ;; "active" arrow matches what the user actually sees.
  (agent-shell-manager-test--reset-state)
  (let* ((s1 (agent-shell-manager-test--make-restartable-session
              "*a*" "/tmp/" 'cfg-a "id-a")))
    (agent-shell-manager-test--with-restart-sessions (list s1)
        (:captured-args _
         :new-buffer-fn (lambda ()
                          (agent-shell-manager-test--make-restartable-session
                           "*a-new*" "/tmp/" 'cfg-a "id-a")))
      (let* ((buf (agent-shell-manager--get-or-create-buffer))
             (saved-config (current-window-configuration))
             (main-win (selected-window)))
        (unwind-protect
            (progn
              (set-window-buffer main-win s1)
              (with-current-buffer buf
                (tabulated-list-print t)
                (goto-char (point-min)))
              (setq agent-shell-manager--active-session s1)
              (with-current-buffer buf
                (goto-char (point-min))
                (agent-shell-manager-restart-session))
              (let ((new-buf (car agent-shell-manager--display-order)))
                (should (buffer-live-p new-buf))
                (should (window-live-p main-win))
                (should (eq (window-buffer main-win) new-buf))))
          (set-window-configuration saved-config)
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/restart-errors-without-session-id ()
  (agent-shell-manager-test--reset-state)
  (let* ((s1 (agent-shell-manager-test--make-restartable-session
              "*a*" "/tmp/" 'cfg-a nil)))
    (agent-shell-manager-test--with-restart-sessions (list s1)
        (:captured-args _
         :new-buffer-fn (lambda () (error "should not be called")))
      (let ((buf (agent-shell-manager--get-or-create-buffer)))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              (should-error (agent-shell-manager-restart-session)
                            :type 'user-error)
              ;; The original session must still be alive when the
              ;; precondition fails.
              (should (buffer-live-p s1)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/restart-confirms-before-killing ()
  (agent-shell-manager-test--reset-state)
  (let* ((s1 (agent-shell-manager-test--make-restartable-session
              "*a*" "/tmp/" 'cfg-a "id-a"))
         (prompts nil))
    (agent-shell-manager-test--with-restart-sessions (list s1)
        (:captured-args _
         :new-buffer-fn (lambda ()
                          (agent-shell-manager-test--make-restartable-session
                           "*a-new*" "/tmp/" 'cfg-a "id-a")))
      (let ((buf (agent-shell-manager--get-or-create-buffer)))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              (cl-letf (((symbol-function 'yes-or-no-p)
                         (lambda (msg) (push msg prompts) t)))
                (agent-shell-manager-restart-session))
              (should (= 1 (length prompts)))
              (should (string-match-p "resume" (car prompts)))
              (should-not (buffer-live-p s1)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/restart-pick-prompt-mentions-pick ()
  (agent-shell-manager-test--reset-state)
  (let* ((s1 (agent-shell-manager-test--make-restartable-session
              "*a*" "/tmp/" 'cfg-a "id-a"))
         (prompts nil))
    (agent-shell-manager-test--with-restart-sessions (list s1)
        (:captured-args _
         :new-buffer-fn (lambda ()
                          (agent-shell-manager-test--make-restartable-session
                           "*a-new*" "/tmp/" 'cfg-a nil)))
      (let ((buf (agent-shell-manager--get-or-create-buffer)))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              (cl-letf (((symbol-function 'yes-or-no-p)
                         (lambda (msg) (push msg prompts) t)))
                (agent-shell-manager-restart-session-pick))
              (should (= 1 (length prompts)))
              (should (string-match-p "pick" (car prompts))))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/restart-aborts-when-declined ()
  (agent-shell-manager-test--reset-state)
  (let* ((s1 (agent-shell-manager-test--make-restartable-session
              "*a*" "/tmp/" 'cfg-a "id-a"))
         (start-called nil))
    (agent-shell-manager-test--with-restart-sessions (list s1)
        (:captured-args _
         :new-buffer-fn (lambda ()
                          (setq start-called t)
                          (agent-shell-manager-test--make-restartable-session
                           "*a-new*" "/tmp/" 'cfg-a "id-a")))
      (let ((buf (agent-shell-manager--get-or-create-buffer)))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              (cl-letf (((symbol-function 'yes-or-no-p)
                         (lambda (&rest _) nil)))
                (should-error (agent-shell-manager-restart-session)
                              :type 'user-error))
              (should-not start-called)
              (should (buffer-live-p s1)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/restart-no-confirm-when-disabled ()
  (agent-shell-manager-test--reset-state)
  (let* ((s1 (agent-shell-manager-test--make-restartable-session
              "*a*" "/tmp/" 'cfg-a "id-a"))
         (agent-shell-manager-confirm-kill nil)
         (prompted nil))
    (agent-shell-manager-test--with-restart-sessions (list s1)
        (:captured-args _
         :new-buffer-fn (lambda ()
                          (agent-shell-manager-test--make-restartable-session
                           "*a-new*" "/tmp/" 'cfg-a "id-a")))
      (let ((buf (agent-shell-manager--get-or-create-buffer)))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              (cl-letf (((symbol-function 'yes-or-no-p)
                         (lambda (&rest _) (setq prompted t) t)))
                (agent-shell-manager-restart-session))
              (should-not prompted)
              (should-not (buffer-live-p s1)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/restart-errors-without-config ()
  (agent-shell-manager-test--reset-state)
  (let* ((s1 (agent-shell-manager-test--make-restartable-session
              "*a*" "/tmp/" 'cfg-a "id-a")))
    (with-current-buffer s1
      (setq-local agent-shell-manager-test--config nil))
    (agent-shell-manager-test--with-restart-sessions (list s1)
        (:captured-args _
         :new-buffer-fn (lambda () (error "should not be called")))
      (let ((buf (agent-shell-manager--get-or-create-buffer)))
        (unwind-protect
            (with-current-buffer buf
              (tabulated-list-print t)
              (goto-char (point-min))
              (should-error (agent-shell-manager-restart-session)
                            :type 'user-error)
              (should (buffer-live-p s1)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))))))

(ert-deftest agent-shell-manager-test/current-session-errors-on-empty ()
  (agent-shell-manager-test--with-mock-sessions nil
    (let ((buf (agent-shell-manager--get-or-create-buffer)))
      (unwind-protect
          (with-current-buffer buf
            (tabulated-list-print t)
            (goto-char (point-min))
            (should-error (agent-shell-manager--current-session)
                          :type 'user-error))
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf))))))

(provide 'agent-shell-manager-test)

;;; agent-shell-manager-test.el ends here
