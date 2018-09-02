;;; polymode-methods.el --- Methods for polymode classes -*- lexical-binding: t -*-
;;
;; Copyright (C) 2013-2018, Vitalie Spinu
;; Author: Vitalie Spinu
;; URL: https://github.com/vspinu/polymode
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; This file is *NOT* part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:
;;
;;; Code:

(require 'polymode-core)


;;; INITIALIZATION

(cl-defgeneric pm-initialize (object)
  "Initialize current buffer with OBJECT.")

(cl-defmethod pm-initialize ((config pm-polymode))
  "Initialization of host buffers.
Ran by the polymode mode function."
  ;; Not calling config's :minor-mode in hosts because this pm-initialize is
  ;; called from minor-mode itself.
  (let* ((hostmode-name (eieio-oref config 'hostmode))
         (hostmode (if hostmode-name
                       (clone (symbol-value hostmode-name))
                     (pm-host-chunkmode :name "ANY" :mode nil))))
    (let ((pm-initialization-in-progress t)
          ;; Set if nil! This allows unspecified host chunkmodes to be used in
          ;; minor modes.
          (host-mode (or (eieio-oref hostmode 'mode)
                         (oset hostmode :mode major-mode))))
      ;; host-mode hooks are run here, but polymode is not initialized
      (pm--mode-setup host-mode)
      (oset hostmode -buffer (current-buffer))
      (oset config -hostmode hostmode)
      (setq pm/polymode config
            pm/chunkmode hostmode
            pm/current t
            pm/type nil)
      (pm--common-setup)
      ;; Initialize innermodes
      (oset config -innermodes
            (mapcar (lambda (sub-name)
                      (clone (symbol-value sub-name)))
                    (eieio-oref config 'innermodes)))
      ;; FIXME: must go into polymode-compat.el
      (add-hook 'flyspell-incorrect-hook
                'pm--flyspel-dont-highlight-in-chunkmodes nil t))
    (pm--run-init-hooks hostmode 'polymode-init-host-hook)))

(cl-defmethod pm-initialize ((chunkmode pm-chunkmode) &optional type mode)
  "Initialization of chunk (indirect) buffers."
  ;; run in chunkmode indirect buffer
  (setq mode (or mode (pm--get-chunkmode-mode chunkmode type)))
  (let ((pm-initialization-in-progress t)
        (new-name  (generate-new-buffer-name
                    (format "%s[%s]" (buffer-name (pm-base-buffer))
                            (replace-regexp-in-string "poly-\\|-mode" ""
                                                      (symbol-name mode))))))
    (rename-buffer new-name)
    (pm--mode-setup (pm--get-existent-mode mode))
    (pm--move-vars '(pm/polymode buffer-file-coding-system) (pm-base-buffer))
    ;; fixme: This breaks if different chunkmodes use same-mode buffer. Even for
    ;; head/tail the value of pm/type will be wrong for tail
    (setq pm/chunkmode chunkmode
          pm/type (pm-true-span-type chunkmode type))
    ;; Call polymode mode for the sake of the keymap. Same minor mode which runs
    ;; in the host buffer but without all the heavy initialization.
    (funcall (eieio-oref pm/polymode 'minor-mode))
    ;; FIXME: should not be here?
    (vc-refresh-state)
    (pm--common-setup)
    (pm--run-init-hooks chunkmode 'polymode-init-inner-hook)))

(defvar poly-lock-allow-fontification)
(defun pm--mode-setup (mode &optional buffer)
  ;; General major-mode install. Should work for both indirect and base buffers.
  ;; PM objects are not yet initialized (pm/polymode, pm/chunkmode, pm/type)
  (with-current-buffer (or buffer (current-buffer))
    ;; don't re-install if already there; polymodes can be used as minor modes.
    (unless (eq major-mode mode)
      (let ((polymode-mode t)           ;major-modes might check this
            (base (buffer-base-buffer))
            ;; (font-lock-fontified t)
            ;; Modes often call font-lock functions directly. We prevent that.
            (font-lock-function 'ignore)
            (font-lock-flush-function 'ignore)
            (font-lock-fontify-buffer-function 'ignore)
            ;; Mode functions can do arbitrary things. We inhibt all PM hooks
            ;; because PM objects have not been setup yet.
            (pm-allow-after-change-hook nil)
            (poly-lock-allow-fontification nil))
        ;; run-mode-hooks needs buffer-file-name
        (when base
          (pm--move-vars pm-move-vars-from-base base (current-buffer)))
        (condition-case-unless-debug err
            (funcall mode)
          (error (message "Polymode error (pm--mode-setup '%s): %s" mode (error-message-string err))))))
    (setq polymode-mode t)
    (current-buffer)))

(defvar syntax-ppss-wide)
(defun pm--common-setup (&optional buffer)
  "Run common setup in BUFFER.
Runs after major mode and core polymode structures have been
initialized. Return the buffer."
  (with-current-buffer (or buffer (current-buffer))
    (when pm-verbose
      (message "common-setup for %s: [%s]" major-mode (current-buffer)))
    (object-add-to-list pm/polymode '-buffers (current-buffer))

    ;; INDENTATION
    (when (and indent-line-function     ; not that it should ever be nil...
               (eieio-oref pm/chunkmode 'protect-indent))
      (setq-local pm--indent-line-function-original indent-line-function)
      (setq-local indent-line-function #'pm-indent-line-dispatcher))

    ;; SYNTAX
    ;; Ideally this should be called in some hook to avoid minor-modes messing
    ;; it up Setting even if syntax-propertize-function is nil to have more
    ;; control over syntax-propertize--done.
    (unless (eq syntax-propertize-function #'polymode-syntax-propertize)
      (setq-local pm--syntax-propertize-function-original syntax-propertize-function)
      (setq-local syntax-propertize-function #'polymode-syntax-propertize))

    (with-no-warnings
      ;; [OBSOLETE as of 25.1 but we still protect it]
      (pm-around-advice syntax-begin-function 'pm-override-output-position))

    ;; VS[19-08-2018]: doesn't work and doesn't fix the problem
    ;; Make sure that none of the `syntax-propertize-extend-region-functions'
    ;; extends the region beyond current span. In practice the only negative
    ;; effect of such extra-extension is slight performance hit. Not sure here,
    ;; but there might be situations when extending beyond current span does
    ;; make sense. Remains to be seen. Make sure it's the last hook.
    ;; (remove-hook 'syntax-propertize-extend-region-functions
    ;;              'polymode-set-syntax-propertize-end
    ;;              t)
    ;; (add-hook 'syntax-propertize-extend-region-functions
    ;;           'polymode-set-syntax-propertize-end
    ;;           t t)

    ;; advising all functions even those with :protect-syntax nil in order to
    ;; get the debug message
    ;; (pm-around-advice syntax-propertize-extend-region-functions
    ;;                   #'polymode-restrict-syntax-propertize-extension)
    ;; flush ppss in all buffers and hook checks
    (add-hook 'before-change-functions 'polymode-before-change-setup t t)
    (setq-local syntax-ppss-wide (cons nil nil))

    ;; HOOKS
    (add-hook 'kill-buffer-hook #'polymode-after-kill-fixes nil t)
    (add-hook 'post-command-hook #'polymode-post-command-select-buffer nil t)
    (add-hook 'pre-command-hook #'polymode-pre-command-synchronize-state nil t)

    ;; FONT LOCK (see poly-lock.el)
    (setq-local font-lock-function 'poly-lock-mode)
    ;; Font lock is initialized `after-change-major-mode-hook' by means of
    ;; `run-mode-hooks' and poly-lock won't get installed if polymode is
    ;; installed as minor mode or interactively.
    ;; Use font-lock-mode instead of poly-lock-mode because modes which don't
    ;; want font-lock can simply set `font-lock-mode' to nil.
    (font-lock-mode t)
    (font-lock-flush)

    (current-buffer)))



;;; BUFFER CREATION

(cl-defgeneric pm-get-buffer-create (chunkmode &optional type)
  "Get the indirect buffer associated with SUBMODE and SPAN-TYPE.
Create and initialize the buffer if does not exist yet.")

;; hostmode only gets this ATM
(cl-defmethod pm-get-buffer-create ((chunkmode pm-chunkmode) &optional type)
  (let ((buff (eieio-oref chunkmode '-buffer)))
    (or (and (buffer-live-p buff) buff)
        (oset chunkmode -buffer
              (pm--get-chunkmode-buffer-create chunkmode type)))))

(cl-defmethod pm-get-buffer-create ((chunkmode pm-inner-chunkmode) &optional type)
  (let ((buff (cond ((eq 'body type) (eieio-oref chunkmode '-buffer))
                    ((eq 'head type) (eieio-oref chunkmode '-head-buffer))
                    ((eq 'tail type) (eieio-oref chunkmode '-tail-buffer))
                    (t (error "Don't know how to select buffer of type '%s' for chunkmode '%s'"
                              type (eieio-object-name chunkmode))))))
    (if (buffer-live-p buff)
        buff
      (pm--set-chunkmode-buffer chunkmode type
                                (pm--get-chunkmode-buffer-create chunkmode type)))))

(defun pm--get-chunkmode-buffer-create (chunkmode type)
  (let ((mode (pm--get-existent-mode
               (pm--get-chunkmode-mode chunkmode type))))
    (or
     ;; 1. look through existent buffer list
     (cl-loop for bf in (eieio-oref pm/polymode '-buffers)
              when (and (buffer-live-p bf)
                        (eq mode (buffer-local-value 'major-mode bf)))
              return bf)
     ;; 2. create new
     (with-current-buffer (pm-base-buffer)
       (let* ((new-name (generate-new-buffer-name (buffer-name)))
              (new-buffer (make-indirect-buffer (current-buffer) new-name)))
         (with-current-buffer new-buffer
           (pm-initialize chunkmode type mode))
         new-buffer)))))

(defun pm--set-chunkmode-buffer (obj type buff)
  "Assign BUFF to OBJ's slot(s) corresponding to TYPE."
  (with-slots (-buffer head-mode -head-buffer tail-mode -tail-buffer) obj
    (pcase (list type head-mode tail-mode)
      (`(body body ,(or `nil `body))
       (setq -buffer buff
             -head-buffer buff
             -tail-buffer buff))
      (`(body ,_ body)
       (setq -buffer buff
             -tail-buffer buff))
      (`(body ,_ ,_ )
       (setq -buffer buff))
      (`(head ,_ ,(or `nil `head))
       (setq -head-buffer buff
             -tail-buffer buff))
      (`(head ,_ ,_)
       (setq -head-buffer buff))
      (`(tail ,_ ,(or `nil `head))
       (setq -tail-buffer buff
             -head-buffer buff))
      (`(tail ,_ ,_)
       (setq -tail-buffer buff))
      (_ (error "Type must be one of 'body, 'head or 'tail")))))


;;; SPAN MANIPULATION

(cl-defgeneric pm-get-span (chunkmode &optional pos)
  "Ask the CHUNKMODE for the span at point.
Return a list of three elements (TYPE BEG END OBJECT) where TYPE
is a symbol representing the type of the span surrounding
POS (head, tail, body). BEG and END are the coordinates of the
span. OBJECT is a suitable object which is 'responsible' for this
span. This is an object that could be dispatched upon with
`pm-select-buffer'. Should return nil if there is no SUBMODE
specific span around POS. Not to be used in programs directly;
use `pm-innermost-span'.")

(cl-defmethod pm-get-span (chunkmode &optional _pos)
  "Return nil.
Base modes usually do not compute spans."
  (unless chunkmode
    (error "Dispatching `pm-get-span' on a nil object"))
  nil)

(cl-defmethod pm-get-span ((chunkmode pm-inner-chunkmode) &optional pos)
  "Return a list of the form (TYPE POS-START POS-END SELF).
TYPE can be 'body, 'head or 'tail. SELF is just a chunkmode object
in this case."
  (with-slots (head-matcher tail-matcher head-mode tail-mode) chunkmode
    (let ((span (pm--span-at-point head-matcher tail-matcher pos
                                   (eieio-oref chunkmode 'can-overlap))))
      (when span
        (append span (list chunkmode))))))

(cl-defmethod pm-get-span ((_chunkmode pm-inner-auto-chunkmode) &optional _pos)
  (let ((span (cl-call-next-method)))
    (if (null (car span))
        span
      (pm--get-auto-span span))))

;; fixme: cache somehow?
(defun pm--get-auto-span (span)
  (let* ((proto (nth 3 span))
         (type (car span)))
    (save-excursion
      (goto-char (nth 1 span))
      (unless (eq type 'head)
        (goto-char (nth 2 span)) ; fixme: add multiline matchers to micro-optimize this
        (let ((matcher (pm-fun-matcher (eieio-oref proto 'head-matcher))))
          (goto-char (car (funcall matcher -1)))))
      (let* ((str (let ((matcher (eieio-oref proto 'mode-matcher)))
                    (when (stringp matcher)
                      (setq matcher (cons matcher 0)))
                    (cond  ((consp matcher)
                            (re-search-forward (car matcher) (point-at-eol) t)
                            (match-string-no-properties (cdr matcher)))
                           ((functionp matcher)
                            (funcall matcher)))))
             (mode (or (pm--get-mode-symbol-from-name str)
                       (eieio-oref proto 'mode)
                       poly-default-inner-mode
                       'poly-fallback-mode)))
        (if (eq mode 'host)
            span
          ;; chunkname:MODE serves as ID (e.g. `markdown-fenced-code:emacs-lisp-mode`).
          ;; Head/tail/body indirect buffers are shared across chunkmodes and span
          ;; types.
          (let* ((name (concat (pm-object-name proto) ":" (symbol-name mode)))
                 (outchunk (or
                            ;; a. loop through installed inner modes
                            (cl-loop for obj in (eieio-oref pm/polymode '-auto-innermodes)
                                     when (equal name (pm-object-name obj))
                                     return obj)
                            ;; b. create new
                            (let ((innermode (clone proto :name name :mode mode)))
                              (object-add-to-list pm/polymode '-auto-innermodes innermode)
                              innermode))))
            (setf (nth 3 span) outchunk)
            span))))))


;;; INDENT

(defun pm--indent-line (span)
  (let ((point (point)))
    ;; do fast synchronization here
    (save-current-buffer
      (pm-set-buffer span)
      (pm-with-narrowed-to-span span
        (goto-char point)
        (funcall pm--indent-line-function-original)
        (setq point (point))))
    (goto-char point)))

(defun pm-indent-line-dispatcher (&optional span)
  "Dispatch `pm-indent-line' methods on current SPAN.
Value of `indent-line-function' in polymode buffers."
  (let ((span (or span (pm-innermost-span)))
        (inhibit-read-only t))
    (pm-indent-line (car (last span)) span)))

(cl-defgeneric pm-indent-line (chunkmode &optional span)
  "Indent current line.
Protect and call original indentation function associated with
the chunkmode.")

(cl-defmethod pm-indent-line ((_chunkmode pm-chunkmode) span)
  (let ((bol (point-at-bol))
        (span (or span (pm-innermost-span))))
    (if (or (< (nth 1 span) bol)
            (= bol (point-min)))
        (pm--indent-line span)
      ;; dispatch to previous span
      (let ((delta (- (point) (nth 1 span)))
            (prev-span (pm-innermost-span (1- bol))))
        (goto-char bol)
        (pm-indent-line-dispatcher prev-span)
        (goto-char (+ (point) delta))
        (pm-switch-to-buffer)))))

(cl-defmethod pm-indent-line ((chunkmode pm-inner-chunkmode) span)
  "Indent line in inner chunkmodes.
When point is at the beginning of head or tail, use parent chunk
to indent."
  (let ((pos (point))
        (delta nil))
    (unwind-protect
        (cond
         ;; 1. in head or tail (we assume head or tail fits in one line for now)
         ((or (eq 'head (car span))
              (eq 'tail (car span)))
          (goto-char (nth 1 span))
          (setq delta (- pos (point)))
          (when (not (bobp))
            (let ((prev-span (pm-innermost-span (1- pos))))
              (if (and (eq 'tail (car span))
                       (eq (point) (save-excursion (back-to-indentation) (point))))
                  ;; if tail is first on the line, indent as head
                  (indent-to (pm--head-indent prev-span))
                (pm--indent-line prev-span)))))

         ;; 2. body
         (t
          (back-to-indentation)
          (if (> (nth 1 span) (point))
              ;; first body line in the same line with header (re-indent at indentation)
              (pm-indent-line-dispatcher)
            (setq delta (- pos (point)))
            (pm--indent-line span)
            (let ((fl-indent (pm--first-line-indent span)))
              (if fl-indent
                  (when (bolp)
                    ;; Not first line. Indent only when original indent is at
                    ;; 0. Otherwise it's a continuation indentation and we assume
                    ;; the original function did it correctly with respect to
                    ;; previous lines.
                    (indent-to fl-indent))
                ;; First line. Indent with respect to header line.
                (indent-to
                 (+ (- (point) (point-at-bol)) ;; non-0 if code in header line
                    (pm--head-indent span) ;; indent with respect to header line
                    (eieio-oref chunkmode 'indent-offset))))))))
      ;; keep point on same characters
      (when (and delta (> delta 0))
        (goto-char (+ (point) delta))))))

(defun pm--first-line-indent (&optional span)
  (save-excursion
    (let ((pos (point)))
      (goto-char (nth 1 (or span (pm-innermost-span))))
      ;; when body starts at bol move to previous line
      (when (and (= (point) (point-at-bol))
                 (not (bobp)))
        (backward-char 1))
      (goto-char (point-at-eol))
      (skip-chars-forward " \t\n")
      (let ((indent (- (point) (point-at-bol))))
        (when (< (point-at-eol) pos)
          indent)))))

(defun pm--head-indent (&optional span)
  (save-excursion
    (goto-char (nth 1 (or span (pm-innermost-span))))
    ;; when body starts at bol move to previous line
    (when (and (= (point) (point-at-bol))
               (not (bobp)))
      (backward-char 1))
    (back-to-indentation)
    (- (point) (point-at-bol))))


;;; FACES
(cl-defgeneric pm-get-adjust-face (chunkmode type))

(cl-defmethod pm-get-adjust-face ((chunkmode pm-chunkmode) _type)
  (eieio-oref chunkmode 'adjust-face))

(cl-defmethod pm-get-adjust-face ((chunkmode pm-inner-chunkmode) type)
  (cond ((eq type 'head)
         (eieio-oref chunkmode 'head-adjust-face))
        ((eq type 'tail)
         (or (eieio-oref chunkmode 'tail-adjust-face)
             (eieio-oref chunkmode 'head-adjust-face)))
        (t (eieio-oref chunkmode 'adjust-face))))

(provide 'polymode-methods)

(provide 'polymode-methods)

;;; polymode-methods.el ends here
