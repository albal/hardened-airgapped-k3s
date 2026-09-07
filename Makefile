# hardened-airgapped-k3s
#
# Stage 1 and 2 run on an internet-connected build host.
# The resulting dist/k3s-airgap-installer.run is the only thing that crosses the airgap.

SHELL := /bin/bash
.DEFAULT_GOAL := help

IMAGE := $(shell sed -n 's/^INSTALLER_IMAGE="\(.*\)"/\1/p' config/versions.env)
TAG   := $(shell sed -n 's/^INSTALLER_TAG="\(.*\)"/\1/p' config/versions.env)

.PHONY: help download build all clean distclean lint submodule shell \
        test test-ansible test-terraform test-integration

help: ## Show this help
	@awk 'BEGIN { FS = ":.*##" } \
	     /^[a-zA-Z_-]+:.*##/ { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
	@echo "  Typical run:  make all   then copy dist/*.run to the airgapped side"

submodule: ## Fetch the k3s-ansible submodule
	git submodule update --init --recursive

download: submodule ## Stage 1: download every artifact (needs internet + docker)
	./scripts/01-download-artifacts.sh

build: ## Stage 2: build the self-executing installer into dist/
	./scripts/02-build-installer.sh

all: download build ## Stage 1 + stage 2

lint: ## Syntax-check the shell, YAML and Ansible content
	@set -e; \
	for f in scripts/*.sh scripts/lib/*.sh installer/*.sh installer/lib/*.sh docker/*.sh terraform/*.sh; do \
	  bash -n "$$f" && echo "  bash -n  $$f"; \
	done; \
	sh -n demo/nginx/20-render-node-page.sh && echo "  sh -n    demo/nginx/20-render-node-page.sh"; \
	python3 -c 'import sys,yaml,re; [list(yaml.safe_load_all(re.sub(r"\$$\{[A-Z_]+\}","x",open(f).read()))) for f in sys.argv[1:]]' \
	  ansible/playbooks/*.yml harbor/values-base.yaml longhorn/values-base.yaml demo/manifests/*.yaml; \
	echo "  yaml     ansible/, harbor/, longhorn/, demo/manifests/"
	@if command -v terraform >/dev/null 2>&1 && [ -d terraform/.terraform ]; then \
	  terraform -chdir=terraform fmt -check >/dev/null && echo "  tf fmt   terraform/"; \
	  terraform -chdir=terraform validate >/dev/null && echo "  tf valid terraform/"; \
	else echo "  terraform skipped - run 'terraform -chdir=terraform init' first"; fi
	@if docker image inspect $(IMAGE):$(TAG) >/dev/null 2>&1; then \
	  docker run --rm --entrypoint ansible-playbook $(IMAGE):$(TAG) \
	    --syntax-check -i /dev/null /opt/ansible/playbooks/00-preflight.yml \
	    /opt/ansible/playbooks/10-offline-packages.yml \
	    /opt/ansible/playbooks/20-longhorn-node-prep.yml \
	    /opt/ansible/playbooks/30-post-install.yml \
	    /opt/k3s-ansible/playbooks/site.yml >/dev/null \
	  && echo "  ansible  --syntax-check (in $(IMAGE):$(TAG))"; \
	else echo "  ansible  skipped - build the installer image first (make build)"; fi

test: test-terraform test-ansible ## Run every test that does not need a cluster

test-terraform: ## Terraform plan tests against a mocked Proxmox provider
	@terraform -chdir=terraform init -backend=false -input=false >/dev/null
	@terraform -chdir=terraform test

test-ansible: ## Ansible unit tests, syntax check and lint
	@./tests/ansible/unit/test-detect-longhorn-disk.sh
	@./tests/ansible/run-static.sh

test-integration: ## Run the playbooks against throwaway systemd containers (needs Docker)
	@./tests/ansible/run-integration.sh

shell: ## Open a shell inside the built installer image (debugging)
	docker run --rm -it --network host --entrypoint /bin/bash \
	  -v "$(PWD)/dist/output:/output" \
	  $(IMAGE):$(TAG)

clean: ## Remove the built bundle, keep the downloaded artifacts
	rm -rf dist

distclean: clean ## Also remove the downloaded artifacts
	rm -rf artifacts
