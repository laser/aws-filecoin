lint:
	find . -type f -name '*.sh' | xargs shellcheck
.PHONY: lint

deploy:
	./infrastructure/cloud-formation/scripts/deploy.sh $(REGION) $(STACK_NAME) $(KEY_NAME)
.PHONY: deploy

destroy:
	./infrastructure/cloud-formation/scripts/destroy.sh $(REGION) $(STACK_NAME)
.PHONY: destroy
