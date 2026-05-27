# Teiwah Infrastructure

This repository contains the standalone GitOps/Infrastructure-as-Code configuration for the Teiwah project.

## Overview

The Teiwah architecture consists of a Next.js frontend, a NestJS Control App, and dynamic WhatsApp Session Workers. Because the Control App dynamically provisions Kubernetes resources for the Session Workers, there is a small delay before Traefik routes are mapped. 

This repository sets up a static, cluster-wide "safety net" that intercepts unmatched routes (e.g., `/sessions/`) and returns a `503 Service Unavailable` with valid CORS headers. This allows the Frontend's `@microsoft/fetch-event-source` client to automatically retry connecting until the dynamic routes are fully propagated, preventing CORS errors from breaking the retry mechanism.

## Structure

This project uses Kustomize for configuration management:
- `base/`: Contains the core, environment-agnostic resources (like the Traefik catchall route and CORS middleware).
- `overlays/`: Contains environment-specific configurations (e.g., `local-k3d` for local development).

## Usage

To apply the configuration locally using `k3d`:

```bash
kubectl apply -k overlays/local-k3d
```
