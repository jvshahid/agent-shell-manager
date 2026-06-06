# agent-shell-manager

A sidebar manager for [agent-shell](https://github.com/xenodium/agent-shell) sessions.

## Status

This is an **opinionated** package built around my personal workflow for
working with agentic coding tools inside Emacs. It is not intended to be
configurable for every layout preference — it imposes a specific way of
arranging sessions on the screen. If that arrangement matches how you
already work, you may find it useful; otherwise you will probably want
something else.

This package was **heavily developed by Claude Code**: most of the
elisp, tests, and design refinement happened through pair-programming
with an LLM. Reviewer beware.

## What it does

Opens a dedicated left side-window listing every live `agent-shell`
session. Moving the cursor between rows arranges the rest of the frame
as:

```
+-----+--------------------------------+
|  s  |                                |
|  i  |          agent-shell           |
|  d  |                                |
|  e  +--------------------------------+
|  b  |                                |
|  a  |            eshell              |
|  r  |                                |
+-----+--------------------------------+
```

Each session has its own paired eshell, lazily created and rooted at
the agent's working directory. The pairing is automatic — switching to
another session switches to that session's eshell.

A `▶` marker shows the currently active session; `●` shows sessions
that are mid-request (driven by `agent-shell`'s heartbeat events, so it
updates the moment a session goes idle).

## Installation

Not on MELPA.

### straight.el

```elisp
(straight-use-package
 '(agent-shell-manager
   :type git
   :host github
   :repo "jvshahid/emacs-agent-shell-manager"))
```

With `use-package`:

```elisp
(use-package agent-shell-manager
  :straight (agent-shell-manager
             :type git
             :host github
             :repo "jvshahid/emacs-agent-shell-manager")
  :commands (agent-shell-manager-toggle))
```

### Manual

```elisp
(add-to-list 'load-path "/path/to/emacs-agent-shell-manager")
(require 'agent-shell-manager)
```

## Usage

`M-x agent-shell-manager-toggle` opens or closes the sidebar.

Inside the sidebar:

| key   | action                                                                  |
|-------|-------------------------------------------------------------------------|
| `n`   | next session and activate                                               |
| `p`   | previous session and activate                                           |
| `C-n` | next row (no activation)                                                |
| `C-p` | previous row (no activation)                                            |
| `RET` | activate and focus the agent buffer                                     |
| `e`   | activate and switch to the session's eshell (creates layout if needed)  |
| `r`   | mark the session read without switching buffers                         |
| `u`   | mark the session unread without switching buffers                       |
| `c`   | create a new session, prompts for a directory                           |
| `C`   | create a new session and prompt for the provider                        |
| `R`   | restart at point, prompting for new or existing                         |
| `k`   | kill the session at point and its paired eshell                         |
| `g`   | refresh                                                                 |
| `q`   | hide the sidebar                                                        |

## Configuration

```elisp
;; Sidebar width: integer (columns) or float (0–1, fraction of frame width).
(setq agent-shell-manager-sidebar-width 0.3)

;; Confirm before killing a session.
(setq agent-shell-manager-confirm-kill t)

;; Indicators.
(setq agent-shell-manager-active-indicator "▶")
(setq agent-shell-manager-busy-indicator "●")
```

## Development

Tests use ERT against a stubbed abstraction layer (no real `agent-shell`
required to run them).

```
make test
```
