# Run on teiwah-master from ~/teiwah-infra (kubectl targets).
# Build/push worker image from your Mac (needs docker + ghcr login).
#
#   make worker-publish                    — build nestwaileys for linux/amd64, push to GHCR
#   make worker-restart SESSION=id         — rollout restart one session (k3s)
#   make worker-restart-all                — restart every deployment using WORKER_IMAGE
#   make cleanup                   — delete all session worker k8s resources
#   make ghcr-secret                 — create/update GHCR pull secret (needs k8s/secrets/.env)
#   make traefik                     — helm upgrade k3s Traefik
#   make catchall                    — apply traefik 503 catchall
#   make pods                        — watch session pods
#   make logs SESSION=id             — follow worker logs for one session

NAMESPACE ?= default
SESSION ?=

# nestwaileys → GHCR (must match teiwah-control SESSION_WORKER_IMAGE)
NESTWAILEYS_DIR ?= ../nestwaileys
WORKER_IMAGE ?= ghcr.io/roman-sh/teiwah-worker
WORKER_TAG ?= amd64
WORKER_PLATFORM ?= linux/amd64

.PHONY: cleanup ghcr-secret traefik catchall pods logs sessions \
	worker-build worker-push worker-publish worker-restart worker-restart-all

cleanup:
	bash scripts/cleanup-sessions.sh

ghcr-secret:
	bash scripts/create-ghcr-pull-secret.sh

traefik:
	helm upgrade --install traefik traefik/traefik \
		-n kube-system \
		-f k8s/traefic/values.yaml

catchall:
	kubectl apply -f base/traefik-catchall.yaml

pods:
	kubectl get pods -n $(NAMESPACE) -w

sessions:
	kubectl get pods,ingress -n $(NAMESPACE)

logs:
ifndef SESSION
	$(error Set SESSION=your-session-id, e.g. make logs SESSION=theoretical-weasel-680a)
endif
	kubectl logs -f deployment/$(SESSION) -n $(NAMESPACE)

# --- Worker image (run from dev machine; requires: docker login ghcr.io) ---

worker-build:
	docker buildx build --platform $(WORKER_PLATFORM) \
		-t $(WORKER_IMAGE):$(WORKER_TAG) \
		-f $(NESTWAILEYS_DIR)/Dockerfile \
		$(NESTWAILEYS_DIR) \
		--load

worker-push:
	docker push $(WORKER_IMAGE):$(WORKER_TAG)

worker-publish:
	docker buildx build --platform $(WORKER_PLATFORM) \
		-t $(WORKER_IMAGE):$(WORKER_TAG) \
		-f $(NESTWAILEYS_DIR)/Dockerfile \
		$(NESTWAILEYS_DIR) \
		--push

worker-restart:
ifndef SESSION
	$(error Set SESSION=your-session-id, e.g. make worker-restart SESSION=cool-mink-b18d)
endif
	kubectl rollout restart deployment/$(SESSION) -n $(NAMESPACE)
	kubectl rollout status deployment/$(SESSION) -n $(NAMESPACE) --timeout=120s

worker-restart-all:
	WORKER_IMAGE=$(WORKER_IMAGE) NAMESPACE=$(NAMESPACE) bash scripts/worker-restart-all.sh
