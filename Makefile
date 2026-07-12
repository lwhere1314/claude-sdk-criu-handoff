.PHONY: check run

check:
	python3 -m py_compile src/controller.py fixture/run.py
	bash -n scripts/run-canary.sh scripts/cleanup-runtime.sh

run:
	./scripts/run-canary.sh
