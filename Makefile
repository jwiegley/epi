SHELL := /bin/sh

.DEFAULT_GOAL := test
.DELETE_ON_ERROR:
.NOTPARALLEL:

EPI_EMACS ?=
GPTEL_ROOT ?=
PI_ROOT ?=
JCS_ORACLE_ROOT ?=
EPI_EXTRA_LOAD_PATH ?=

export EPI_EMACS GPTEL_ROOT PI_ROOT JCS_ORACLE_ROOT EPI_EXTRA_LOAD_PATH
export SELECTOR

override BUILD_DIRECTORY := .build
override ELC_DIRECTORY := $(BUILD_DIRECTORY)/elc

override PRODUCTION_CANDIDATES := \
	epi.el \
	epi-ledger.el \
	epi-resources.el \
	epi-tools.el \
	epi-gptel.el \
	epi-runtime.el \
	epi-ui.el
override PRODUCTION_FILES := \
	$(strip $(foreach file,$(PRODUCTION_CANDIDATES),$(if $(wildcard $(file)),$(file))))

override NON_IN_PROCESS_TESTS := \
	test/epi-ledger-process-test.el \
	test/epi-scale-test.el
override OFFLINE_TESTS := \
	$(filter-out $(NON_IN_PROCESS_TESTS),$(sort $(wildcard test/epi-*-test.el)))

# Build Emacs argv entirely inside the shell.  Dependency paths remain data in
# quoted positional parameters instead of becoming syntax through Make
# expansion.  Keep the trusted parent prefix separate so preflight can treat
# GPTEL_ROOT solely as validator input.
override define EPI_BUILD_TRUSTED_EMACS_ARGV
set -- "$$EPI_EMACS" --batch -Q; \
remaining=$$EPI_EXTRA_LOAD_PATH; \
while [ -n "$$remaining" ]; do \
	case "$$remaining" in \
		*:*) directory=$${remaining%%:*}; remaining=$${remaining#*:} ;; \
		*) directory=$$remaining; remaining= ;; \
	esac; \
	if [ -n "$$directory" ]; then \
		set -- "$$@" -L "$$directory"; \
	fi; \
done
endef

override define EPI_BUILD_EMACS_ARGV
$(EPI_BUILD_TRUSTED_EMACS_ARGV); \
set -- "$$@" -L "$$GPTEL_ROOT" -L . -L test
endef

override define EPI_BUILD_PREFLIGHT_ARGV
set -- "$$EPI_EMACS" --batch -Q -L . -L test
endef

.PHONY: \
	require-emacs \
	require-runtime-inputs \
	require-preflight-inputs \
	preflight \
	jcs-goldens \
	test-one \
	test \
	compile \
	checkdoc \
	clean

require-emacs:
	@if [ -z "$$EPI_EMACS" ]; then \
		echo "EPI_EMACS is required" >&2; \
		exit 2; \
	fi
	@case "$$EPI_EMACS" in \
		/*) ;; \
		*) echo "EPI_EMACS must be an absolute path: $$EPI_EMACS" >&2; exit 2 ;; \
	esac
	@if [ ! -x "$$EPI_EMACS" ]; then \
		echo "EPI_EMACS is not executable: $$EPI_EMACS" >&2; \
		exit 2; \
	fi

require-runtime-inputs: require-emacs
	@if [ -z "$$GPTEL_ROOT" ]; then \
		echo "GPTEL_ROOT is required" >&2; \
		exit 2; \
	fi
	@if [ ! -d "$$GPTEL_ROOT" ]; then \
		echo "GPTEL_ROOT is not a directory: $$GPTEL_ROOT" >&2; \
		exit 2; \
	fi
	@if [ -z "$$EPI_EXTRA_LOAD_PATH" ]; then \
		echo "EPI_EXTRA_LOAD_PATH is required" >&2; \
		exit 2; \
	fi
	@remaining=$$EPI_EXTRA_LOAD_PATH; found=; \
	while [ -n "$$remaining" ]; do \
		case "$$remaining" in \
			*:*) directory=$${remaining%%:*}; remaining=$${remaining#*:} ;; \
			*) directory=$$remaining; remaining= ;; \
		esac; \
		if [ -z "$$directory" ]; then \
			continue; \
		fi; \
		found=t; \
		if [ ! -d "$$directory" ]; then \
			echo "EPI_EXTRA_LOAD_PATH entry is not a directory: $$directory" >&2; \
			exit 2; \
		fi; \
	done; \
	if [ -z "$$found" ]; then \
		echo "EPI_EXTRA_LOAD_PATH must contain a directory" >&2; \
		exit 2; \
	fi

require-preflight-inputs: require-runtime-inputs
	@if [ -z "$$PI_ROOT" ]; then \
		echo "PI_ROOT is required" >&2; \
		exit 2; \
	fi
	@if [ ! -d "$$PI_ROOT" ]; then \
		echo "PI_ROOT is not a directory: $$PI_ROOT" >&2; \
		exit 2; \
	fi
	@if [ -z "$$JCS_ORACLE_ROOT" ]; then \
		echo "JCS_ORACLE_ROOT is required" >&2; \
		exit 2; \
	fi
	@if [ ! -d "$$JCS_ORACLE_ROOT" ]; then \
		echo "JCS_ORACLE_ROOT is not a directory: $$JCS_ORACLE_ROOT" >&2; \
		exit 2; \
	fi

preflight: require-preflight-inputs
	@TESTS='test/epi-preflight-test.el'; SELECTOR='^epi-preflight-'; \
	export TESTS SELECTOR; \
	$(EPI_BUILD_PREFLIGHT_ARGV); \
	set -- "$$@" -l test/run-tests.el; \
	"$$@"
	@$(EPI_BUILD_PREFLIGHT_ARGV); \
	set -- "$$@" -l test/epi-test-helper.el \
		--eval '(progn (epi-test-preflight-validate) (princ "Validated frozen Epi dependencies\n"))'; \
	"$$@"

jcs-goldens: preflight
	@if ! command -v node >/dev/null 2>&1; then \
		echo "Node is required only to regenerate JCS goldens" >&2; \
		exit 2; \
	fi
	@verification=$$(node "$$JCS_ORACLE_ROOT/node-es6/verify-canonicalization.js"); \
	status=$$?; printf '%s\n' "$$verification"; \
	if [ $$status -ne 0 ] || \
	   ! printf '%s\n' "$$verification" | grep -Fqx 'All tests succeeded!' || \
	   printf '%s\n' "$$verification" | grep -Eq 'THE TEST ABOVE FAILED|\*\*\*\*\*\* ERRORS:'; then \
		echo "Pinned JCS shipped-vector verification failed" >&2; \
		exit 2; \
	fi
	@$(EPI_BUILD_PREFLIGHT_ARGV); \
	set -- "$$@" -l test/generate-jcs-goldens.el; \
	"$$@"

test-one: override export TESTS := $(TEST)
test-one: require-runtime-inputs
	@if [ -z "$$TESTS" ]; then \
		echo "TEST is required, for example TEST=test/epi-package-test.el" >&2; \
		exit 2; \
	fi
	@$(EPI_BUILD_EMACS_ARGV); \
	set -- "$$@" -l test/run-tests.el; \
	"$$@"

test: override export EPI_OFFLINE_TESTS := $(OFFLINE_TESTS)
test: require-preflight-inputs
	@if [ -z "$$EPI_OFFLINE_TESTS" ]; then \
		echo "No offline ERT test files were found" >&2; \
		exit 2; \
	fi
	@set -efu; \
	for test_file in $$EPI_OFFLINE_TESTS; do \
		printf '%s\n' "Running $$test_file in a fresh Emacs process"; \
		TESTS="$$test_file"; SELECTOR=; export TESTS SELECTOR; \
		$(EPI_BUILD_EMACS_ARGV); \
		set -- "$$@" -l test/run-tests.el; \
		"$$@" || exit $$?; \
	done

compile: override export EPI_COMPILE_FILES := $(PRODUCTION_FILES)
compile: override export EPI_BUILD_DIRECTORY := $(abspath $(ELC_DIRECTORY))
compile: require-runtime-inputs
	@if [ -z "$$EPI_COMPILE_FILES" ]; then \
		echo "No Epi production files were found" >&2; \
		exit 2; \
	fi
	@rm -rf -- "$(ELC_DIRECTORY)"
	@mkdir -p "$(ELC_DIRECTORY)"
	@$(EPI_BUILD_EMACS_ARGV); \
	set -- "$$@" -L "$$EPI_BUILD_DIRECTORY" --eval '(progn (require (quote bytecomp)) (setq byte-compile-error-on-warn t byte-compile-dest-file-function (lambda (source) (expand-file-name (file-name-nondirectory (concat (file-name-sans-extension source) ".elc")) (getenv "EPI_BUILD_DIRECTORY")))) (dolist (file (split-string (getenv "EPI_COMPILE_FILES") nil t)) (unless (byte-compile-file file) (error "Byte compilation failed: %s" file))))'; \
	"$$@"
	@stray=$$(find . -type f -name '*.elc' ! -path './.build/*' -print -quit); \
	if [ -n "$$stray" ]; then \
		echo "Byte compilation wrote outside $(ELC_DIRECTORY): $$stray" >&2; \
		exit 2; \
	fi

checkdoc: override export EPI_CHECKDOC_FILES := $(PRODUCTION_FILES)
checkdoc: require-emacs
	@if [ -z "$$EPI_CHECKDOC_FILES" ]; then \
		echo "No Epi production files were found" >&2; \
		exit 2; \
	fi
	@"$$EPI_EMACS" --batch -Q -l checkdoc -L . -L test -l test/checkdoc.el

clean:
	@rm -rf -- "$(BUILD_DIRECTORY)"
