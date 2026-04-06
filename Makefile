.PHONY: lint test

lint:
	@bash -n skills/todo-task/*.sh
	@echo "All scripts pass syntax check"

test:
	@echo "No tests configured"
