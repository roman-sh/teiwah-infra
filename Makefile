# Run on teiwah-master from ~/teiwah-infra (kubectl targets).
# Build/push worker image from your Mac (needs docker + ghcr login).
#
#   make worker-publish                    — build nestwaileys for linux/amd64, push to GHCR
#   make worker-restart SESSION=id         — rollout restart one session (k3s)
#   make worker-restart-all                — restart every deployment using WORKER_IMAGE
#   make cleanup                   — delete session worker k8s resources in sandbox (dev)
#   make cleanup NS=default        — same, but target the prod namespace
#   make cleanup-list-refresh NS=sandbox
#   make cleanup-selected-hard NS=sandbox SESSIONS=sandbox:session-1,sandbox:session-2
#   make sandbox-setup             — create the sandbox (dev) namespace + its GHCR pull secret
#   make ghcr-secret                 — create/update GHCR pull secret (needs k8s/secrets/.env)
#   make traefik                     — helm upgrade k3s Traefik
#   make catchall                    — apply traefik 503 catchall
#   make monitoring                  — install/upgrade kube-prometheus-stack (agent → Grafana Cloud)
#   make monitoring-status           — monitoring pods + agent log tail
#   make pods                        — list pods now (wide)
#   make pods-watch                  — kubectl -w (updates only on events)
#   make pods-live                   — refresh every 2s (needs `watch` on PATH)
#   make logs SESSION=id             — follow worker logs for one session

NAMESPACE ?= default
NS ?=
SESSION ?=
SESSIONS ?=

# nestwaileys → GHCR (must match teiwah-control SESSION_WORKER_IMAGE)
NESTWAILEYS_DIR ?= ../nestwaileys
WORKER_IMAGE ?= ghcr.io/roman-sh/teiwah-worker
WORKER_TAG ?= amd64
WORKER_PLATFORM ?= linux/amd64

.PHONY: cleanup cleanup-list-refresh cleanup-selected-hard \
	sandbox-setup ghcr-secret traefik catchall monitoring monitoring-status \
	pods pods-watch pods-live logs sessions \
	worker-build worker-push worker-publish worker-restart worker-restart-all

# Defaults to sandbox (dev). `make cleanup NS=default` targets prod.
cleanup:
	bash scripts/cleanup-sessions.sh $(NS)

cleanup-list-refresh:
	bash scripts/write-session-cleanup-entities.sh $(NS)

cleanup-selected-hard:
	bash scripts/cleanup-selected-sessions-hard.sh $(NS) "$(SESSIONS)" --yes

# Create the dev namespace and its GHCR pull secret in one shot.
sandbox-setup:
	kubectl apply -f k8s/sandbox/namespace.yaml
	K8S_NAMESPACE=sandbox bash scripts/create-ghcr-pull-secret.sh

ghcr-secret:
	bash scripts/create-ghcr-pull-secret.sh

traefik:
	helm upgrade --install traefik traefik/traefik \
		-n kube-system \
		-f k8s/traefic/values.yaml

catchall:
	kubectl apply -f base/traefik-catchall.yaml

monitoring:
	bash k8s/monitoring/apply.sh

monitoring-status:
	kubectl -n monitoring get pods -o wide
	kubectl -n monitoring logs --tail=30 -l app.kubernetes.io/name=prometheus-agent || \
		kubectl -n monitoring logs --tail=30 -l app.kubernetes.io/name=prometheus || true

pods:
	kubectl get pods -n $(NAMESPACE) -o wide

pods-watch:
	kubectl get pods -n $(NAMESPACE) -o wide -w

pods-live:
	watch -n 2 kubectl get pods -n $(NAMESPACE) -o wide

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
