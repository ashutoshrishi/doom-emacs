;;; core-popup.el --- taming stray windows

;; I use a slew of hackery to get Emacs to treat 'pop-up' windows in a sane and "modern"
;; way (whatever that means). It goes through great lengths to tame helm, flycheck, help
;; buffers--*even* the beast that is org-mode.
;;
;; Be warned, an update could break any of this.

(use-package shackle
  :config
  (shackle-mode 1)
  (setq shackle-rules
        `(;; Util
          ("^\\*.+-Profiler-Report .+\\*$" :align below :size 0.3 :regexp t)
          ("*esup*"            :align below :size 30  :noselect t)
          ("*minor-modes*"     :align below :size 0.5 :noselect t)
          ;; Emacs
          ("*Pp Eval Output*"  :align below :size 0.3)
          ("*Apropos*"         :align below :size 0.3)
          ("*Backtrace*"       :align below :size 25  :noselect t)
          ("*Completions*"     :align below :size 20  :noselect t)
          ("*Help*"            :align below :size 16  :select t)
          ("*Messages*"        :align below :size 15  :select t)
          ("*Warnings*"        :align below :size 10  :noselect t)
          (compilation-mode    :align below :size 15  :noselect t)
          (eww-mode            :align below :size 30  :select t)
          ;; vcs
          ("*vc-diff*"         :align below :size 15  :noselect t)
          ("*vc-change-log*"   :align below :size 15  :select t)
          (vc-annotate-mode    :same t)))

  (defvar doom-popup-windows '()
    "A list of windows that have been opened via shackle. Do not touch this!")
  (defvar doom-last-popup nil
    "The last (important) popup buffer.")
  (defvar doom-prev-buffer nil
    "The buffer from which the popup was invoked.")
  (defvar-local doom-popup-protect nil
    "If non-nil, this popup buffer won't be killed when closed.")

  (defvar doom-popup-inescapable-modes
    '(compilation-mode comint-mode "^\\*doom.*\\*$")
    "A list of modes that should not be closeable with a single ESC.")
  (defvar doom-popup-protect-modes
    '(messages-buffer-mode esup-mode help-mode tabulated-list-mode comint-mode)
    "A list of modes that shouldn't be killed and can be revived.")

  ;; There is no shackle-popup hook, so I hacked one in
  (defvar doom-popup-pre-hook  '() "Hooks run after a popup is opened.")
  (defvar doom-popup-post-hook '() "Hooks run before a popup is opened.")
  (advice-add 'shackle-display-buffer :before 'doom*run-popup-pre-hooks)
  (advice-add 'shackle-display-buffer :after  'doom*run-popup-post-hooks)
  (add-hook 'doom-popup-post-hook 'doom|popup-init)     ; Keep track of popups
  (add-hook 'doom-popup-post-hook 'doom|hide-mode-line) ; No mode line in popups
  ;; Prevents popups from messaging with windows-moving functions
  (advice-add 'doom/evil-window-move :around 'doom*save-popups))


;;
;; Hacks
;;

(defun doom-popup-magit-hacks ()
  ;; Some wrassling must be done to get magit to kill itself, and trigger my
  ;; shackle popup hooks.
  (setq magit-bury-buffer-function
        (lambda (&rest _) (doom/popup-close (selected-window)))
        magit-display-buffer-function
        (lambda (b)
          (funcall (if (doom/popup-p (selected-window)) 'switch-to-buffer 'doom/popup-buffer) b)
          (get-buffer-window b))
        magit-display-file-buffer-function
        (lambda (b)
          (when doom-prev-buffer
            (select-window (get-buffer-window doom-prev-buffer)))
          (switch-to-buffer b))))

(after! evil
  (defun doom*evil-command-window (hist cmd-key execute-fn)
    (when (eq major-mode 'evil-command-window-mode)
      (user-error "Cannot recursively open command line window"))
    (dolist (win (window-list))
      (when (equal (buffer-name (window-buffer win))
                   "*Command Line*")
        (kill-buffer (window-buffer win))
        (delete-window win)))
    (setq evil-command-window-current-buffer (current-buffer))
    (ignore-errors (kill-buffer "*Command Line*"))
    (with-current-buffer (pop-to-buffer "*Command Line*")
      (setq-local evil-command-window-execute-fn execute-fn)
      (setq-local evil-command-window-cmd-key cmd-key)
      (evil-command-window-mode)
      (evil-command-window-insert-commands hist)
      (doom|hide-mode-line)))
  (advice-add 'evil-command-window :override 'doom*evil-command-window))

(after! help-mode
  ;; So that file links in help buffers don't replace the help buffer, we need
  ;; to redefine these three button types to use `doom/popup-save' and
  ;; `switch-to-buffer' rather than `pop-to-buffer'. This way, it is sure to
  ;; open links in the source buffer.
  (define-button-type 'help-function-def
    :supertype 'help-xref
    'help-function (lambda (fun file)
                     (require 'find-func)
                     (when (eq file 'C-source)
                       (setq file (help-C-file-name (indirect-function fun) 'fun)))
                     (let ((location
                            (find-function-search-for-symbol fun nil file)))
                       (doom/popup-save
                        (switch-to-buffer (car location)))
                       (if (cdr location)
                           (goto-char (cdr location))
                         (message "Unable to find location in file"))))
    'help-echo (purecopy "mouse-2, RET: find function's definition"))

  (define-button-type 'help-variable-def
    :supertype 'help-xref
    'help-function (lambda (var &optional file)
                     (when (eq file 'C-source)
                       (setq file (help-C-file-name var 'var)))
                     (let ((location (find-variable-noselect var file)))
                       (doom/popup-save
                        (switch-to-buffer (car location)))
                       (if (cdr location)
                           (goto-char (cdr location))
                         (message "Unable to find location in file"))))
    'help-echo (purecopy "mouse-2, RET: find variable's definition"))

  (define-button-type 'help-face-def
    :supertype 'help-xref
    'help-function (lambda (fun file)
                     (require 'find-func)
                     (let ((location
                            (find-function-search-for-symbol fun 'defface file)))
                       (doom/popup-save
                        (switch-to-buffer (car location)))
                       (if (cdr location)
                           (goto-char (cdr location))
                         (message "Unable to find location in file"))))
    'help-echo (purecopy "mouse-2, RET: find face's definition")))

(after! helm
  ;; This is a good alternative to either popwin or shackle, specifically for
  ;; helm. If either fail me (for the last time), this is where I'll turn.
  ;;(add-to-list 'display-buffer-alist
  ;;             `(,(rx bos "*helm" (* not-newline) "*" eos)
  ;;               (display-buffer-in-side-window)
  ;;               (inhibit-same-window . t)
  ;;               (window-height . 0.4)))

  ;; Helm tries to clean up after itself, but shackle has already done this.
  ;; This fixes that. To reproduce, add a helm rule in `shackle-rules', open two
  ;; splits side-by-side, move to the buffer on the right and invoke helm. It
  ;; will close all but the left-most buffer.
  (setq-default helm-reuse-last-window-split-state t
                helm-split-window-in-side-p t))

(after! helm-swoop
  (setq helm-swoop-split-window-function (lambda (b) (doom/popup-buffer b))))

(after! helm-ag
  ;; This prevents helm-ag from switching between windows and buffers.
  (defadvice helm-ag--edit-abort (around helm-ag-edit-abort-popup-compat activate)
    (cl-letf (((symbol-function 'select-window) 'ignore)) ad-do-it)
    (doom/popup-close nil t t))
  (defadvice helm-ag--edit-commit (around helm-ag-edit-commit-popup-compat activate)
    (cl-letf (((symbol-function 'select-window) 'ignore)) ad-do-it)
    (doom/popup-close nil t t))
  (defadvice helm-ag--edit (around helm-ag-edit-popup-compat activate)
    (cl-letf (((symbol-function 'other-window) 'ignore)
              ((symbol-function 'switch-to-buffer) 'doom/popup-buffer))
      ad-do-it)))

(after! quickrun
  ;; This allows us to rerun code from inside a quickrun buffer.
  (defun doom*quickrun-close-popup (&optional _ _ _ _)
    (let* ((buffer (get-buffer quickrun/buffer-name))
           (window (and buffer (get-buffer-window buffer))))
      (when buffer
        (shut-up! (quickrun/kill-running-process))
        (doom/popup-close window nil t))))
  (advice-add 'quickrun :before 'doom*quickrun-close-popup)
  (advice-add 'quickrun-region :before 'doom*quickrun-close-popup)

  ;; Ensures window is scrolled to BOF
  (defun doom|quickrun-after-run ()
    (with-selected-window (get-buffer-window quickrun/buffer-name)
      (goto-char (point-min))))
  (add-hook 'quickrun-after-run-hook 'doom|quickrun-after-run)
  (add-hook 'quickrun/mode-hook 'doom|hide-mode-line))

(add-hook! org-load
  ;; Ensures org-src-edit yields control of its buffer to shackle.
  (defun org-src-switch-to-buffer (buffer context)
    (pop-to-buffer buffer))

  ;; And these for org-todo, org-link and org-agenda
  (defun org-pop-to-buffer-same-window (&optional buffer-or-name norecord label)
    "Pop to buffer specified by BUFFER-OR-NAME in the selected window."
    (display-buffer buffer-or-name))

  (defun org-switch-to-buffer-other-window (&rest args)
    (mapc (lambda (b)
            (let ((buf (if (stringp b) (get-buffer-create b) b)))
              (pop-to-buffer buf t t)))
          args))

  ;; Taming Org-agenda!
  (defun doom/org-agenda-quit ()
    "Necessary to finagle org-agenda into shackle popups and behave properly on quit."
    (interactive)
    (if org-agenda-columns-active
        (org-columns-quit)
      (let ((buf (current-buffer)))
        (and (not (eq org-agenda-window-setup 'current-window))
             (not (one-window-p))
             (delete-window))
        (kill-buffer buf)
        (setq org-agenda-archives-mode nil
              org-agenda-buffer nil))))

  (after! org-agenda
    (map! :map org-agenda-mode-map
          :e "<escape>" 'doom/org-agenda-quit
          :e "ESC" 'doom/org-agenda-quit
          :e [escape] 'doom/org-agenda-quit
          "q" 'doom/org-agenda-quit
          "Q" 'doom/org-agenda-quit)))

(after! realgud
  ;; This allows realgud debuggers to run in a popup.
  ;; TODO Find a more elegant advice-based solution
  ;; FIXME Causes realgud:cmd-* to focus popup on every invocation
  (defun realgud:run-process(debugger-name script-filename cmd-args minibuffer-history &optional no-reset)
    (let ((cmd-buf))
      (setq cmd-buf
            (apply 'realgud-exec-shell debugger-name script-filename
                   (car cmd-args) no-reset (cdr cmd-args)))
      (let ((process (get-buffer-process cmd-buf)))
        (if (and process (eq 'run (process-status process)))
            (progn
              (pop-to-buffer cmd-buf)
              (define-key evil-emacs-state-local-map (kbd "ESC ESC") 'doom/debug-quit)
              (realgud:track-set-debugger debugger-name)
              (realgud-cmdbuf-info-in-debugger?= 't)
              (realgud-cmdbuf-info-cmd-args= cmd-args)
              (when cmd-buf
                (switch-to-buffer cmd-buf)
                (when realgud-cmdbuf-info
                  (let* ((info realgud-cmdbuf-info)
                         (cmd-args (realgud-cmdbuf-info-cmd-args info))
                         (cmd-str  (mapconcat 'identity  cmd-args " ")))
                    (set minibuffer-history
                         (list-utils-uniq (cons cmd-str (eval minibuffer-history))))))))
          ;; else
          (progn
            (if cmd-buf (switch-to-buffer cmd-buf))
            (message "Error running command: %s" (mapconcat 'identity cmd-args " ")))))
      cmd-buf)))

(provide 'core-popup)
;;; core-popup.el ends here
