ELPACA ?= $(HOME)/.emacs.d/elpaca/builds
LOAD_PATH := $(foreach d,$(wildcard $(ELPACA)/*/),-L $(d)) -L .
EMACS ?= emacs

.PHONY: compile test clean
compile:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile magit-autorefresh.el

test:
	$(EMACS) -Q --batch $(LOAD_PATH) -l test/magit-autorefresh-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc
