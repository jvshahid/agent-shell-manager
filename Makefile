EMACS ?= emacs

.PHONY: test
test:
	$(EMACS) -Q --batch \
	  -L . -L tests \
	  -l tests/agent-shell-manager-test.el \
	  -f ert-run-tests-batch-and-exit
