.PHONY: check run

check:
	python3 -m py_compile src/controller.py src/task_controller.py fixture/run.py scripts/summarize-task-run.py scripts/aggregate-results.py
	bash -n scripts/run-canary.sh scripts/run-task-matrix.sh scripts/cleanup-runtime.sh

run:
	./scripts/run-canary.sh
