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
