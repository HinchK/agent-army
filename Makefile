.PHONY: check lint test

SHELL := /bin/bash

check: lint test

lint:
	@set -euo pipefail; \
	sh_files=(); \
	for f in lib/*.sh tests/test_*.sh; do \
		if [ -f "$$f" ]; then sh_files+=("$$f"); fi; \
	done; \
	if [ -f bin/army ] && head -n 1 bin/army | grep -q 'sh$$'; then \
		sh_files+=("bin/army"); \
	fi; \
	if [ "$${#sh_files[@]}" -gt 0 ]; then \
		echo "Running shellcheck on $${sh_files[*]}..."; \
		shellcheck -x "$${sh_files[@]}"; \
	fi; \
	source lib/pyenv.sh && resolve_python; \
	py_files=(); \
	for f in lib/*.py tests/test_*.py; do \
		if [ -f "$$f" ]; then py_files+=("$$f"); fi; \
	done; \
	if [ "$${#py_files[@]}" -gt 0 ]; then \
		echo "Syntax-checking Python files $${py_files[*]}..."; \
		"$$PYTHON_BIN" -m py_compile "$${py_files[@]}"; \
	fi

test:
	@set -euo pipefail; \
	for t in tests/test_*.sh; do \
		if [ -f "$$t" ]; then \
			echo "Running $$t..."; \
			/bin/bash "$$t"; \
		fi; \
	done; \
	source lib/pyenv.sh && resolve_python; \
	for t in tests/test_*.py; do \
		if [ -f "$$t" ]; then \
			echo "Running $$t..."; \
			"$$PYTHON_BIN" -m unittest "$$t"; \
		fi; \
	done
