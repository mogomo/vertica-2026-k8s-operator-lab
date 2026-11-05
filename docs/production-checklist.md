# For production, also test

The lab proves a lot on one workstation, but not everything. This checklist lists what to
test before production, in two parts:

- **a–p:** capabilities to test on your target platform. Each one is described in the
  Vertica 26.3 documentation for Vertica on Kubernetes.
- **P01–P13:** what the lab's own test report marks as "needs a real cluster", with the
  reason a single workstation cannot show it.

Use the Vertica documentation for your version as the reference.

## a–p: capabilities to test on your platform

| | Area | What to test |
|---|---|---|
| a | Supported platform | Run on a supported managed Kubernetes service (Amazon EKS, Google GKE, Azure AKS) or Red Hat OpenShift, with a highly available control plane. |
| b | Multi-AZ deployment | Place subclusters in different availability zones with affinity / anti-affinity (documented for Amazon EKS) and test the loss of a zone. |
| c | Durable communal storage | Use production object storage: AWS S3, Google Cloud Storage, Azure Blob Storage, HDFS, or a production S3-compatible store. |
| d | Volume expansion | Use a `local.storageClass` that allows volume expansion and verify that the operator grows the depot/catalog volume automatically. |
| e | Online upgrade | `upgradePolicy: Online` (from server 24.3.0-2 and higher) or `ReadOnlyOnline`. Requires more than one subcluster; with a single subcluster the operator upgrades offline. |
| f | Autoscaling | `VerticaAutoscaler` with a HorizontalPodAutoscaler or a KEDA ScaledObject, driven by Prometheus metrics. |
| g | Replication | `VerticaReplicator`: replicate a database to another database or to a sandbox. |
| h | Sandboxes | Subcluster sandboxes (`spec.sandboxes`) for isolated testing and upgrade rehearsals. |
| i | Restore points | `VerticaRestorePointsQuery`: save, list and restore restore points; manage archives. |
| j | Enterprise secret stores | Keep CR secrets in AWS Secrets Manager or Google Secret Manager. |
| k | Monitoring | Prometheus integration and Grafana dashboards (operator `/metrics` endpoint and Helm chart options). |
| l | External access | Expose subclusters through LoadBalancer services with real DNS names. |
| m | Diagnostics | `VerticaScrutinize`: collect a diagnostics bundle the way Vertica Support requests it. |
| n | Production performance | Benchmark your real workload on production-sized nodes; sandbox numbers are relative, not sizing guidance. |
| o | Workload identity (IRSA) | On Amazon EKS, let Vertica pods reach S3 with their service-account JWT (IAM roles for service accounts) instead of static access keys. |
| p | Corporate identity provider | OAuth 2.0 / JWT with Okta, OTDS or Keycloak in production mode: HTTPS endpoints, high availability, just-in-time user provisioning and role mapping. |

## P01–P13: what needs a real cluster

These appear at the end of every test report (`reports/test-*/summary.txt`) with the
status N/A.

| | Capability | Why the lab cannot show it |
|---|---|---|
| P01 | Permanent host loss, with the pod rescheduled onto another physical machine | Local-path volumes pin each Vertica pod to one node. Production needs network or replicated CSI storage (EBS, Ceph, Portworx, vSAN) so the StatefulSet pod can restart elsewhere with its volume. |
| P02 | Kubernetes control-plane high availability | kind has one control-plane node here; production uses 3 or more control-plane nodes, or managed Kubernetes with an etcd quorum. |
| P03 | Zone / rack fault domains | Needs real failure domains with topology spread constraints and zone labels; all "nodes" here share one workstation. |
| P04 | Real network partitions, NIC/switch failures and latency between hosts | Simulated only by freezing a node container; real heartbeat behaviour needs separate hosts. |
| P05 | Production performance and capacity benchmarks | All pods share the same CPU, RAM and SSD; numbers are relative, not sizing guidance. |
| P06 | Durable communal storage | A single MinIO pod on one disk is not durable; production uses S3 or an erasure-coded / replicated on-premises object store with TLS. |
| P07 | Off-site / cross-region disaster recovery | Requires a second cluster (VerticaReplicator or replicated object storage). |
| P08 | Metrics-driven autoscaling (VerticaAutoscaler with Prometheus / KEDA) and Kubernetes node autoscaling | Needs a cluster autoscaler and cloud capacity; here scaling is triggered by CR changes. |
| P09 | Online rolling upgrade between Vertica releases (`upgradePolicy: Online`) | Needs a second, newer image version and production-sized subclusters. |
| P10 | Enterprise identity and secrets (LDAP / Kerberos, AWS Secrets Manager / Google Secret Manager, CA-signed certificates, etcd encryption at rest) | Requires corporate infrastructure; the lab uses Kubernetes Secrets and operator self-signed certificates. |
| P11 | Load balancers / ingress with real external IPs and DNS | The lab exposes NodePorts on 127.0.0.1 only. |
| P12 | Workload identity for communal storage (IRSA on Amazon EKS) | Vertica pods use their service-account JWT, exchanged through the cluster's OIDC provider for temporary S3 credentials, so no static access keys are stored (Vertica docs: IRSA profile authentication). Needs Amazon EKS and AWS IAM. |
| P13 | Production identity provider for OAuth 2.0 / JWT (Okta, OTDS, or Keycloak in production mode) | The lab's Keycloak runs in development mode (in-memory database, HTTP inside the cluster). Production: HTTPS endpoints, a highly available identity provider, just-in-time user provisioning and role mapping from token claims. |

## What the lab already covers

For contrast, these were tested for real in the published run (see
[test-catalog.md](test-catalog.md)):

- Health of every layer, a 5-million-row star schema, query performance, concurrency and
  bulk load
- Persistent local volumes and S3 communal storage
- Monitoring: metrics-server, the operator's token-protected `/metrics`, the Vertica
  Prometheus endpoint, system tables, Kubernetes events
- Security: Secrets, non-root, Kubernetes and database RBAC, TLS client-server, HTTPS and
  **between the nodes**, plain-text logins rejected, NetworkPolicy
- Machine-to-machine logins with OAuth 2.0 / JWT, including forged and expired tokens and
  key rotation
- Workload isolation with resource pools
- Operator reconciliation and admission webhook
- Self-healing after a process crash, a pod deletion and a frozen worker
- Restore points, object restore and a full revive from communal storage
- Online scale-out and scale-in with a secondary subcluster
