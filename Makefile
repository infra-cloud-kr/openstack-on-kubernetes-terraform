TF      := terraform -chdir=terraform
REGION  := $(shell $(TF) output -raw 2>/dev/null | true)

.PHONY: help init plan up ssm logs status outputs down fmt validate osh-deploy osh-vm pause resume

help:
	@echo "Targets:"
	@echo "  make init       - terraform init"
	@echo "  make plan       - terraform plan"
	@echo "  make up         - terraform apply -auto-approve (creates the EC2 node)"
	@echo "  make ssm        - start an SSM Session Manager shell on the node"
	@echo "  make logs       - tail the cloud-init bootstrap log on the node"
	@echo "  make ready      - quick check: did user_data finish? (K8S_READY / K8S_STILL_BOOTSTRAPPING)"
	@echo "  make status     - kubectl get nodes/pods on the node"
	@echo "  make outputs    - show terraform outputs"
	@echo "  make pause      - stop the EC2 node (keeps EBS, ~\$$8/mo; resume in ~1min)"
	@echo "  make resume     - start the stopped node back up"
	@echo "  make down       - terraform destroy -auto-approve"
	@echo "  make fmt        - terraform fmt"
	@echo "  make validate   - terraform validate"
	@echo
	@echo "OpenStack-Helm targets (run after 'make up' + node Ready):"
	@echo "  make osh-deploy - install OSH 2024.2.0 compute-core stack (~30 min)"
	@echo "  make osh-vm     - validate by booting a CirrOS VM (~3 min)"

init:
	$(TF) init

plan:
	$(TF) plan

up:
	$(TF) apply -auto-approve
	@echo
	@echo "Node is up. Bootstrap (K8s + OSH clone) takes ~5-8 min."
	@echo "Tail the bootstrap log:  make logs"
	@echo "Open a shell:            make ssm"

outputs:
	$(TF) output

ssm:
	@INSTANCE_ID=$$($(TF) output -raw instance_id) ; \
	REGION=$$($(TF) output -raw region 2>/dev/null || echo ap-northeast-2) ; \
	echo "Connecting to $$INSTANCE_ID in $$REGION..." ; \
	aws ssm start-session --target $$INSTANCE_ID --region $$REGION

logs:
	@INSTANCE_ID=$$($(TF) output -raw instance_id) ; \
	REGION=$$($(TF) output -raw region 2>/dev/null || echo ap-northeast-2) ; \
	aws ssm start-session --target $$INSTANCE_ID --region $$REGION \
	  --document-name AWS-StartInteractiveCommand \
	  --parameters command="sudo tail -f /var/log/user-data.log"

status:
	@INSTANCE_ID=$$($(TF) output -raw instance_id) ; \
	REGION=$$($(TF) output -raw region 2>/dev/null || echo ap-northeast-2) ; \
	aws ssm start-session --target $$INSTANCE_ID --region $$REGION \
	  --document-name AWS-StartInteractiveCommand \
	  --parameters command="sudo -u ubuntu kubectl get nodes -o wide; echo ---; sudo -u ubuntu kubectl get pods -A"

ready:
	@INSTANCE_ID=$$($(TF) output -raw instance_id) ; \
	REGION=$$($(TF) output -raw region 2>/dev/null || echo ap-northeast-2) ; \
	echo "Checking /var/log/user-data-complete on the node..." ; \
	aws ssm start-session --target $$INSTANCE_ID --region $$REGION \
	  --document-name AWS-StartInteractiveCommand \
	  --parameters command="if [ -f /var/log/user-data-complete ]; then echo K8S_READY; else echo K8S_STILL_BOOTSTRAPPING; tail -n 20 /var/log/user-data.log; fi"

pause:
	@INSTANCE_ID=$$($(TF) output -raw instance_id) ; \
	REGION=$$($(TF) output -raw region 2>/dev/null || echo ap-northeast-2) ; \
	echo "Stopping $$INSTANCE_ID..." ; \
	aws ec2 stop-instances --instance-ids $$INSTANCE_ID --region $$REGION >/dev/null ; \
	aws ec2 wait instance-stopped --instance-ids $$INSTANCE_ID --region $$REGION ; \
	echo "Stopped. EBS only (~\$$8/mo). Resume with: make resume"

resume:
	@INSTANCE_ID=$$($(TF) output -raw instance_id) ; \
	REGION=$$($(TF) output -raw region 2>/dev/null || echo ap-northeast-2) ; \
	echo "Starting $$INSTANCE_ID..." ; \
	aws ec2 start-instances --instance-ids $$INSTANCE_ID --region $$REGION >/dev/null ; \
	aws ec2 wait instance-running --instance-ids $$INSTANCE_ID --region $$REGION ; \
	echo "Running. K8s/OSH usually back in ~30-60s. Check: make status"

down:
	$(TF) destroy -auto-approve

fmt:
	$(TF) fmt -recursive

validate:
	$(TF) validate

# Run an OSH script on the node via SSM and poll until completion.
# Usage:  $(call run_osh_script,osh/deploy.sh,3600)
define run_osh_script
	@SCRIPT='$(1)' ; TIMEOUT_S='$(2)' ; \
	INSTANCE_ID=$$($(TF) output -raw instance_id) ; \
	REGION=$$($(TF) output -raw region 2>/dev/null || echo ap-northeast-2) ; \
	B64=$$(base64 < $$SCRIPT | tr -d '\n') ; \
	echo "Dispatching $$SCRIPT to $$INSTANCE_ID in $$REGION (timeout=$${TIMEOUT_S}s)..." ; \
	CMD_ID=$$(aws ssm send-command --instance-ids $$INSTANCE_ID --region $$REGION \
	  --document-name AWS-RunShellScript --timeout-seconds $$TIMEOUT_S \
	  --parameters "commands=[\"echo $$B64 | base64 -d | bash\"]" \
	  --query 'Command.CommandId' --output text) ; \
	echo "CMD_ID=$$CMD_ID" ; \
	while true; do \
	  ST=$$(aws ssm get-command-invocation --command-id $$CMD_ID --instance-id $$INSTANCE_ID --region $$REGION --query 'Status' --output text 2>/dev/null || echo Pending) ; \
	  echo "  status=$$ST" ; \
	  case "$$ST" in Success|Failed|Cancelled|TimedOut) break;; esac ; \
	  sleep 30 ; \
	done ; \
	echo "===== STDOUT (tail) =====" ; \
	aws ssm get-command-invocation --command-id $$CMD_ID --instance-id $$INSTANCE_ID --region $$REGION --query 'StandardOutputContent' --output text | tail -50 ; \
	[ "$$ST" = Success ]
endef

osh-deploy:
	$(call run_osh_script,osh/deploy.sh,3600)

osh-vm:
	$(call run_osh_script,osh/cirros-boot.sh,900)
