MAKEFLAGS=--warn-undefined-variables

APPLICATION_NAME=mbarney-backup
STACK_NAME ?= ${APPLICATION_NAME}-$(ENVIRONMENT_NAME)
AWS_REGION ?= us-east-2

node_modules: package-lock.json
	npm ci
	touch node_modules

artifacts/template.packaged.yml: template.yml $(shell find ./templates -name '*.yml')
	mkdir -p artifacts
	sam package \
		--s3-bucket "${ARTIFACT_BUCKET}" \
		--s3-prefix "${ARTIFACT_PREFIX}" \
		--output-template-file artifacts/template.packaged.yml
	touch artifacts/template.packaged.yml

.PHONY: dependencies lint package create-change-set deploy-change-set delete clean
dependencies: node_modules
	pip install -r requirements.txt

lint:
	cfn-lint

package: artifacts/template.packaged.yml

create-change-set: node_modules
	@echo "Deploying ${STACK_NAME} with changeset ${CHANGE_SET_NAME}"
	aws cloudformation create-change-set \
		--stack-name ${STACK_NAME} \
		--template-body file://artifacts/template.packaged.yml \
		--parameters \
			ParameterKey=ApplicationName,ParameterValue='"${APPLICATION_NAME}"' \
			ParameterKey=EnvironmentName,ParameterValue='"${ENVIRONMENT_NAME}"' \
		--tags \
			Key=ApplicationName,Value=${APPLICATION_NAME} \
			Key=EnvironmentName,Value=${ENVIRONMENT_NAME} \
			Key=workload,Value=${APPLICATION_NAME}-${ENVIRONMENT_NAME} \
		--capabilities CAPABILITY_AUTO_EXPAND CAPABILITY_NAMED_IAM CAPABILITY_IAM \
		--change-set-name ${CHANGE_SET_NAME} \
		--description "${CHANGE_SET_DESCRIPTION}" \
		--include-nested-stacks \
		--change-set-type $$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} &> /dev/null && echo "UPDATE" || echo "CREATE")
	@echo "Waiting for change set to be created..."
	@CHANGE_SET_STATUS=None; \
	while [[ "$$CHANGE_SET_STATUS" != "CREATE_COMPLETE" && "$$CHANGE_SET_STATUS" != "FAILED" ]]; do \
		CHANGE_SET_STATUS=$$(aws cloudformation describe-change-set --stack-name ${STACK_NAME} --change-set-name ${CHANGE_SET_NAME} --output text --query 'Status'); \
	done; \
	aws cloudformation describe-change-set --stack-name ${STACK_NAME} --change-set-name ${CHANGE_SET_NAME} > artifacts/${STACK_NAME}-${CHANGE_SET_NAME}.json; \
	if [[ "$$CHANGE_SET_STATUS" == "FAILED" ]]; then \
		CHANGE_SET_STATUS_REASON=$$(aws cloudformation describe-change-set --stack-name ${STACK_NAME} --change-set-name ${CHANGE_SET_NAME} --output text --query 'StatusReason'); \
		if [[ "$$CHANGE_SET_STATUS_REASON" == "The submitted information didn't contain changes. Submit different information to create a change set." ]]; then \
			echo "ChangeSet contains no changes."; \
		else \
			echo "Change set failed to create."; \
			echo "$$CHANGE_SET_STATUS_REASON"; \
			exit 1; \
		fi; \
	fi;
	@echo "Change set ${STACK_NAME} - ${CHANGE_SET_NAME} created."
	npx cfn-changeset-viewer --stack-name ${STACK_NAME} --change-set-name ${CHANGE_SET_NAME}

deploy-change-set: node_modules
	CHANGE_SET_STATUS=$$(aws cloudformation describe-change-set --stack-name ${STACK_NAME} --change-set-name ${CHANGE_SET_NAME} --output text --query 'Status'); \
	if [[ "$$CHANGE_SET_STATUS" == "FAILED" ]]; then \
		CHANGE_SET_STATUS_REASON=$$(aws cloudformation describe-change-set --stack-name ${STACK_NAME} --change-set-name ${CHANGE_SET_NAME} --output text --query 'StatusReason'); \
		echo "$$CHANGE_SET_STATUS_REASON"; \
		if [[ "$$CHANGE_SET_STATUS_REASON" == "The submitted information didn't contain changes. Submit different information to create a change set." ]]; then \
			echo "ChangeSet contains no changes."; \
		else \
			echo "Change set failed to create."; \
			exit 1; \
		fi; \
	else \
		aws cloudformation execute-change-set \
			--stack-name ${STACK_NAME} \
			--change-set-name ${CHANGE_SET_NAME}; \
	fi;
	npx cfn-event-tailer ${STACK_NAME}

delete:
	aws cloudformation delete-stack --stack-name ${STACK_NAME}

clean:
	rm -rf artifacts
