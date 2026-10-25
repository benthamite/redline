EMACS ?= emacs
ELPACA_REPOS ?= $(dir $(CURDIR))
LOAD_PATH := -L $(CURDIR) -L test \
             -L $(ELPACA_REPOS)yaml \
             -L $(ELPACA_REPOS)markdown-mode

TEST_FILES := $(wildcard test/redline-*-test.el)
LOAD_TESTS = $(foreach f,$(TEST_FILES),-l $(f))
SRC_FILES := $(wildcard redline*.el)

.PHONY: test test-verbose compile clean

test:
	$(EMACS) -Q --batch $(LOAD_PATH) -l ert $(LOAD_TESTS) \
	  -f ert-run-tests-batch-and-exit

test-verbose:
	$(EMACS) -Q --batch $(LOAD_PATH) -l ert $(LOAD_TESTS) \
	  --eval '(ert-run-tests-batch-and-exit t)'

compile:
	$(EMACS) -Q --batch $(LOAD_PATH) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRC_FILES)

clean:
	rm -f *.elc test/*.elc
