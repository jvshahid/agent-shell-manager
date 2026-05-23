# Fix Unbalanced Parentheses in Elisp

When elisp code has unbalanced parentheses, Emacs will fail to load with `end-of-file` or `scan-error: unbalanced parentheses` error. Here's the systematic approach to find the missing paren:

## The Approach

### Step 1: Load the Entire Expression
First, try to load the complete file or expression. Expect it to fail.

```elisp
(load "/path/to/file.el" t)
;; Expected: (end-of-file /path/to/file.el) or similar error
```

### Step 2: Extract Top-Level Sub-Expressions
Break the file/module into its top-level top-level forms and test each independently. Strip the outer parens of the parent form when testing sub-expressions.

For example, for `(defun foo () "doc" (interactive) (let ...) (body...))`, test:
- `"doc"` (the docstring)
- `(interactive)`
- `(let ...)` (the body forms)
- `(body...)`

```elisp
;; Test docstring
(load "/tmp/test-docstring.el" t)  ; should succeed

;; Test interactive
(load "/tmp/test-interactive.el" t)  ; should succeed

;; Test let block
(load "/tmp/test-let.el" t)  ; may fail
```

### Step 3: Identify the Unbalanced Sub-expression
The sub-expression that fails with `end-of-file` is the one with the missing paren.

### Step 4: Drill Down into the Unbalanced Sub-expression
Repeat the process: break the failing sub-expression into its own sub-expressions and test each.

For `(let ((binding1 val1) (binding2 val2)) body)`:
- Test `((binding1 val1) (binding2 val2))` (bindings)
- Test `(body)` (body forms)

### Step 5: Continue Until You Find the Exact Missing Paren
Keep drilling down until you find the exact form that's missing its closing paren.

## Example

Given this broken function:
```elisp
(defun foo ()
  "Doc."
  (interactive)
  (let ((x (bar)))
    (when (< x 2)
      (message "hi"))
    (let* ((y (baz))
           (z (qux)))
      (message "done"))))
```

If `(y (baz))` is missing its closing paren:

1. Load entire file → `end-of-file`
2. Load `(let ((x (bar))) ...)` → `end-of-file` (the let block has the issue)
3. Load `((x (bar)))` → OK (binding is balanced)
4. Load body → need to test let* part
5. Load `(let* ((y (baz)) (z (qux))) ...)` → `end-of-file` (let* has the issue)
6. Load `((y (baz)) (z (qux)))` → `end-of-file` (bindings have the issue)
7. Load `(y (baz))` → `end-of-file` (this binding is missing its closing paren!)
8. Fix: `(y (baz))` → should be `(y (baz)))`

## Common Patterns

When drilling into bindings, remember:
- A binding is `(symbol value)` — needs closing paren after value
- A list of bindings is `((binding1) (binding2) ...)` — each binding needs its own `)`

## Key Tip

When you strip the outer parens of a parent form to test sub-expressions, remember that:
- For `(parent (sub1) (sub2))`, test `(sub1)` and `(sub2)` independently
- For `(parent binding1 binding2)`, test `binding1` and `binding2`
- For a list of bindings `((b1) (b2))`, test `(b1)` and `(b2)` — strip the outer double-parens
