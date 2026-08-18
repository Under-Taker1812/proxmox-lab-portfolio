# Proxmox K8s Platform

A self-managed homelab that runs a 4-node Proxmox/Ceph cluster as the foundation for Rancher-provisioned Kubernetes clusters, with centralized observability for every cluster it creates.

This repo is the write-up of that build: what was decided, why, and every real failure encountered along the way — not a cleaned-up success story.

> 📖 **Best viewed in [Obsidian](https://obsidian.md).** The docs cross-link between pages and render Mermaid diagrams natively there; GitHub's renderer shows everything flat, which works but loses some of the navigation.

## What's actually here

| | |
|---|---|
| **Hardware** | 4× physical servers running Proxmox VE, clustered, sharing one Ceph pool |
| **Control plane** | Rancher (K3s single-node), pinned to one Proxmox node |
| **Workload clusters** | RKE2, provisioned and destroyed on demand through Rancher's API |
| **Storage** | Ceph RBD, exposed to Kubernetes through ceph-csi |
| **Observability** | One centralized hub (Elasticsearch + Kibana + Prometheus + Grafana) — every workload cluster ships logs and metrics out, none stores its own |
| **Automation** | Ansible — idempotent, re-runnable per-stage, 12 playbooks |

## Why this exists

Most homelab write-ups show the finished topology and skip the part that actually teaches something: what broke, why it broke, and how the fix was found. This repo keeps that part. The [`troubleshooting/`](docs/troubleshooting) folder alone documents more than a dozen real, reproducible bugs — race conditions in cluster bootstrap, a netfilter dual-dataplane conflict, an Elasticsearch mapping bug that silently dropped logs for four days — each with the debugging path, not just the fix.

## Repo layout

```
docs/                   — infrastructure design & operations (start at 01-architecture-overview.md)
ansible/                — the automation itself (playbooks, templates, vars)
```

The split is deliberate: `docs/` is *why the system looks like this*, `ansible/` is *the code that builds it*. Read `docs/` first if you're evaluating the design; go straight to `ansible/README.md` if you just want to run it.

## Start here

1. [**Architecture overview**](docs/01-architecture-overview.md) — the whole system in one diagram, and why it's shaped this way
2. [**Proxmox foundation**](docs/02-proxmox-foundation.md) — the 4 physical nodes, VM templating
3. [**Networking & VLAN design**](docs/03-networking-vlan-design.md)
4. [**Ceph storage**](docs/04-ceph-storage.md)
5. [**Rancher + RKE2 deployment**](docs/05-rancher-rke2-deployment.md)
6. [**Cluster operations**](docs/06-cluster-operations.md) — day-2 kubectl/Rancher workflows
7. [**RBAC & security**](docs/07-rbac-security.md)
8. [**Observability hub**](docs/08-observability-hub.md) — the centralized logging/metrics design
9. [**Troubleshooting**](docs/troubleshooting/) — every real bug, by topic
10. [**Ansible automation**](ansible/README.md) — the code

## Status

This is a personal lab, actively maintained, not a production reference architecture. Places where a lab-grade shortcut was taken on purpose are called out explicitly in the relevant doc — look for the **⚠️ lab-only** callouts.

## License

Documentation and code in this repo are provided as-is for reference. *(License to be finalized.)*
