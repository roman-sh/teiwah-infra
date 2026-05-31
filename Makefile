# Run on teiwah-master from ~/teiwah-infra
#
#   make cleanup          — delete all session worker k8s resources
#   make ghcr-secret      — create/update GHCR pull secret (needs k8s/secrets/.env)
#   make traefik          — helm upgrade k3s Traefik
#   make catchall         — apply traefik 503 catchall
#   make pods             — watch session pods
#   make logs SESSION=id  — follow worker logs for one session

NAMESPACE ?= default
SESSION ?=

.PHONY: cleanup ghcr-secret traefik catchall pods logs sessions

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
