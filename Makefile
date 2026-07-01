# mountOS init-hub (production) — client deploy package.
# Every target is IDEMPOTENT and NON-DESTRUCTIVE. There is intentionally NO
# destroy / down / DB-drop target: re-running apply/bootstrap only converges
# forward. Decommissioning a hub is a deliberate manual runbook, never a button.
SHELL := /usr/bin/env bash
HERE  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
# Cloud demarcation: each cloud's substrate lives under clouds/<cloud>/terraform.
# aws | gcp | azure. See release.yaml's clouds section for the verification
# level each one has (AWS is Floci-plan-verified; GCP/Azure are validate+tflint
# only — no local emulator equivalent exists for those).
CLOUD ?= aws
TF    := $(HERE)clouds/$(CLOUD)/terraform

.PHONY: help interview plan apply bootstrap verify upgrade region-bootstrap

help:
	@echo "mountOS init-hub (production):"
	@echo "  interview  scaffold answers.env from the sample"
	@echo "  plan       terraform plan  (preview the substrate)"
	@echo "  apply      terraform apply (provision network/KMS/DB/Vault/compute/LBs; converges, never destroys)"
	@echo "  bootstrap  generate fresh keys -> seed Vault -> create AppRole (run ONCE, operator-side)"
	@echo "  verify     read-only health gates against the running hub"
	@echo "  upgrade    set MOS_VERSION in answers.env, then 'make apply' to roll the ASG (no data touched)"
	@echo "  region-bootstrap  seed region Vault (dataserv/gcserv/blockserv/hdfsserv/s3gatewayserv keys, unconditional) + fan out hub<->region verifiers"
	@echo ""
	@echo "  CLOUD=$(CLOUD) (default aws). Substrate: clouds/$(CLOUD)/terraform"
	@echo "  NO destroy target by design."

interview:
	@test -f "$(HERE)answers.env" || cp "$(HERE)answers.sample.env" "$(HERE)answers.env"
	@echo "edit $(HERE)answers.env, then: make plan"

plan:
	@test -f "$(TF)/backend.tf" || { echo "ERROR: create $(TF)/backend.tf from backend.tf.sample — encrypted remote state is required for production"; exit 1; }
	@terraform -chdir="$(TF)" plan -var-file=terraform.tfvars

apply:
	@test -f "$(TF)/backend.tf" || { echo "ERROR: create $(TF)/backend.tf from backend.tf.sample — encrypted remote state is required for production"; exit 1; }
	@terraform -chdir="$(TF)" apply -var-file=terraform.tfvars

bootstrap:
	@bash "$(HERE)bootstrap/seed-vault.sh"

region-bootstrap:
	@bash "$(HERE)bootstrap/region-seed.sh"

verify:
	@bash "$(HERE)verify.sh"

upgrade:
	@echo "set MOS_VERSION in answers.env (+ tfvars), then: make apply  # rolling ASG refresh"
