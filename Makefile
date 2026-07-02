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
# Default comes from answers.env's CLOUD= line when present (env/CLI still wins).
CLOUD ?= $(strip $(shell sed -n 's/^CLOUD=\([a-zA-Z]*\).*$$/\1/p' $(HERE)answers.env 2>/dev/null))
ifeq ($(CLOUD),)
CLOUD := aws
endif
TF    := $(HERE)clouds/$(CLOUD)/terraform

.PHONY: help interview validate plan apply bootstrap verify upgrade region-bootstrap

help:
	@echo "mountOS init-hub (production):"
	@echo "  interview  scaffold answers.env from the sample"
	@echo "  validate   terraform fmt-check + validate (no cloud credentials needed)"
	@echo "  plan       terraform plan  (preview the substrate)"
	@echo "  apply      terraform apply (provision network/KMS/DB/compute/LBs; converges, never destroys)"
	@echo "  bootstrap  generate fresh keys -> seed the hub secret store (cloud-native or your byo Vault; run ONCE, operator-side)"
	@echo "  verify     read-only health gates against the running hub"
	@echo "  upgrade    set MOS_VERSION in answers.env, then 'make apply' to roll the ASG (no data touched)"
	@echo "  region-bootstrap  seed the region secret store (dataserv/gcserv/blockserv/hdfsserv/s3gatewayserv keys, unconditional) + fan out hub<->region verifiers"
	@echo ""
	@echo "  CLOUD=$(CLOUD) (default aws). Substrate: clouds/$(CLOUD)/terraform"
	@echo "  NO destroy target by design."

interview:
	@test -f "$(HERE)answers.env" || cp "$(HERE)answers.sample.env" "$(HERE)answers.env"
	@echo "edit $(HERE)answers.env, then: make plan"

# Schema-level gate, safe anywhere: no backend, no credentials, no state.
validate:
	@terraform -chdir="$(TF)" fmt -check -recursive
	@terraform -chdir="$(TF)" init -backend=false -input=false >/dev/null
	@terraform -chdir="$(TF)" validate

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
