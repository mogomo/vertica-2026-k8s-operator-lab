# Test catalog

The 15 tests of `--test`, in the order they run, with the checks and results of the
published validation run ([logs/report/summary.txt](../logs/report/summary.txt)).
**Result: 15 PASS, 0 FAIL, 0 WARN.**

- **REAL**: real behaviour of the cluster.
- **SIM**: a failure that one workstation can only simulate (for example a frozen container instead of a dead server).
- Run one group: `sudo ./vertica-k8s-lab.sh --test --only <group>`; skip groups with `--skip`.
- Failure tests run a client application (1 query per second for 60 s) and cap every recovery wait at 300 s.

| # | Test | Group | Scope | Planned | Measured | Result |
|---|---|---|---|---|---|---|
| T01 | [Cluster health check](#t01) | `health` | REAL | ~10 s | 1 s | PASS |
| T02 | [SQL workload: build and verify a star schema](#t02) | `workload` | REAL | ~30 s | 2 s | PASS |
| T03 | [Query performance, concurrency and bulk load](#t03) | `perf` | REAL | ~1 min | 14 s | PASS |
| T04 | [Persistent storage (local volumes + S3 communal)](#t04) | `storage` | REAL | ~5 s | < 1 s | PASS |
| T05 | [Monitoring and metrics endpoints](#t05) | `monitoring` | REAL | ~15 s | 1 s | PASS |
| T06 | [Security controls (secrets, RBAC, TLS, network)](#t06) | `security` | REAL | ~40 s | 34 s | PASS |
| T07 | [Machine-to-machine database login (OAuth 2.0 / JWT)](#t07) | `m2m` | REAL | ~1 min | 25 s | PASS |
| T08 | [Workload isolation with resource pools](#t08) | `isolation` | REAL | ~1 min | 10 s | PASS |
| T09 | [Operator auto-repair of configuration drift](#t09) | `reconcile` | REAL | ~2-4 min | 67 s | PASS |
| T10 | [Self-healing: Vertica process crash](#t10) | `selfheal` | SIM | ~1-2 min | 60 s | PASS |
| T11 | [Self-healing: Vertica pod deleted](#t11) | `selfheal` | SIM | ~1-2 min | 60 s | PASS |
| T12 | [Node failure: a worker server freezes](#t12) | `nodefail` | SIM | ~2-3 min | 105 s | PASS |
| T13 | [Backup, restore and disaster recovery](#t13) | `backup` | REAL | ~5-10 min | 95 s | PASS |
| T14 | [Elastic scaling: add and remove compute online](#t14) | `scaling` | SIM | ~5-10 min | 120 s | PASS |
| T15 | [Final health and host-safety check](#t15) | `final` | REAL | ~15 s | 2 s | PASS |

<a id="t01"></a>
## T01 · Cluster health check

Group `health` · REAL · took 1 s in the published run

**What:** A quick check-up of every layer before any test changes anything.

**How:**

- Check the 4 Kubernetes nodes, the VerticaDB operator, its admission webhook and MinIO (S3 communal storage).
- Check the 3 Vertica pods and their volumes, the Vertica node states, K-safety and the license.

**Expected:** All green: 4/4 nodes Ready, 3/3 pods Ready, 3/3 Vertica nodes UP, K-safety 1.

**Checks in the published run:**

- ✅ PASS: Kubernetes: 4/4 nodes Ready
- ✅ PASS: VerticaDB operator Deployment available
- ✅ PASS: Admission webhook registered (invalid CR changes are rejected)
- ✅ PASS: Communal storage (MinIO) ready
- ✅ PASS: Identity provider (Keycloak) ready
- ✅ PASS: VerticaDB pods Ready: 3/3
- ✅ PASS: Persistent volume claims Bound: 3/3
- ✅ PASS: Vertica nodes UP: 3/3
- ✅ PASS: Database is K-safe (current fault tolerance 1)
- ✅ PASS: Eon communal storage location registered

<a id="t02"></a>
## T02 · SQL workload: build and verify a star schema

Group `workload` · REAL · took 2 s in the published run

**What:** Builds a realistic retail star schema inside Vertica and checks the data is correct and evenly spread.

**How:**

- Generate 10,000 customers, 1,000 products and 5,000,000 sales rows with set-based SQL (no files needed).
- Verify the row count and referential integrity (every sale has a customer).
- Show how the rows are distributed over the 3 nodes (segmentation).

**Expected:** Exact row count, 0 orphan rows, segmentation skew close to 1.00 (= perfectly even).

**Checks in the published run:**

- ✅ PASS: Row count verified: lab.sales = 5000000
- ✅ PASS: Referential integrity: 0 orphan sales rows

<a id="t03"></a>
## T03 · Query performance, concurrency and bulk load

Group `perf` · REAL · took 14 s in the published run

**What:** Measures how fast the cluster answers typical analytic questions and loads data.

**How:**

- Run 6 analytic queries 3 times each (joins, window functions, percentiles); timings come from Vertica itself.
- Eon depot effect: clear the local cache, run a query "cold" (reads S3) and then "warm" (local depot).
- Concurrency: 8 parallel sessions x 5 queries. Bulk load: COPY 500,000 CSV rows.

**Expected:** All queries succeed, a timing table is printed, 0 errors under concurrency, exactly 500,000 rows loaded.

**Checks in the published run:**

- ✅ PASS: Analytic query benchmark completed (results in perf.csv)
- ✅ PASS: Depot cold/warm comparison captured (cold 115 ms vs warm 102 ms)
- ✅ PASS: Concurrent workload: 40 queries, 0 errors
- ✅ PASS: COPY loaded 500,000 rows

<a id="t04"></a>
## T04 · Persistent storage (local volumes + S3 communal)

Group `storage` · REAL · took under 1 s in the published run

**What:** Shows where Vertica keeps its data and proves it is stored durably.

**How:**

- List the PersistentVolumeClaims (one local volume per pod for catalog + depot cache).
- Show Vertica's storage locations and count the data files in the S3 communal bucket (MinIO).

**Expected:** 3 Bound volumes, a COMMUNAL storage location, data objects present in S3.

**Checks in the published run:**

- ✅ PASS: Each Vertica pod has its own Bound PersistentVolume (catalog + depot)
- ✅ PASS: Local data volume mounted in pod: /dev/nvme0n1p5  232G  115G  105G  53% /home/dbadmin/local-data
- ✅ PASS: Communal storage holds 473 objects (data survives loss of every pod)

<a id="t05"></a>
## T05 · Monitoring and metrics endpoints

Group `monitoring` · REAL · took 1 s in the published run

**What:** Checks every monitoring channel an operations team would use.

**How:**

- kubectl top (metrics-server) for nodes and pods.
- Operator Prometheus /metrics with a JWT bearer token: the pod's Kubernetes service-account token (machine-to-machine).
- The same endpoint with no token, a tampered JWT, a JWT for another audience, and another service account's JWT.
- Vertica server Prometheus endpoint (HTTPS 8443), Vertica system tables (v_monitor), Kubernetes events.

**Expected:** Metrics with a valid JWT; no token, a tampered JWT or a JWT for another audience are REJECTED.

**Checks in the published run:**

- ✅ PASS: metrics-server: live resource metrics available
- ✅ PASS: Operator /metrics (HTTPS, RBAC-authorised token) exposes 46 vertica_* samples
- ✅ PASS: Anonymous scrape of operator metrics is rejected (HTTP 401)
- ✅ PASS: The service-account token is a signed JWT (machine-to-machine identity): alg=RS256, iss=https://kubernetes.default.svc.cluster.local, sub=system:serviceaccount:vertica-lab:vlab-client, aud=["https://kubernetes.default.svc.cluster.local"], lifetime 600 s
- ✅ PASS: JWT with a tampered signature is rejected (HTTP 500: Authentication failed )
- ✅ PASS: JWT issued for another audience is rejected (HTTP 500: Authentication failed )
- ✅ PASS: A valid JWT of another service account is accepted: the chart binds metrics-reader to system:authenticated (documented default)
- ✅ PASS: Vertica server Prometheus endpoint https://<pod>:8443/v1/metrics — 634 samples (TLS)
- ✅ PASS: System-table monitoring (v_monitor.*) queried successfully
- ✅ PASS: Operator emits Kubernetes events for the VerticaDB (43 events in the last hour)

<a id="t06"></a>
## T06 · Security controls (secrets, RBAC, TLS, network)

Group `security` · REAL · took 34 s in the published run

**What:** Verifies the security controls: secrets, least privilege, encryption and network isolation.

**How:**

- DB password lives only in a Kubernetes Secret; Vertica runs as non-root; a read-only service account is limited.
- Database users: a read-only user can SELECT but not INSERT; a failed login is audited.
- TLS: a TLS login is accepted and a plain-text login is REJECTED (TLS missing or not enforced = WARN, not FAIL).
- Inter-node TLS: data channel (data_channel TLS, VERIFY_CA) and control channel (Spread encryption) between the nodes.
- NetworkPolicy: an unlabelled "intruder" pod is blocked from the SQL port 5433.

**Expected:** Every control PASSes; the intruder can connect before the policy and is blocked after it.

**Checks in the published run:**

- ✅ PASS: Superuser password only referenced via Secret (not present in CR / StatefulSet specs)
- ✅ PASS: Vertica server container runs as non-root (uid 5000)
- ✅ PASS: RBAC: read-only SA can list pods
- ✅ PASS: RBAC: read-only SA is denied delete on VerticaDB
- ✅ PASS: RBAC: read-only SA is denied access to Secrets
- ✅ PASS: DB RBAC: lab_reader can SELECT (5000000 rows)
- ✅ PASS: DB RBAC: INSERT by read-only user is denied
- ✅ PASS: Failed login attempt recorded in v_monitor.login_failures (2)
- ✅ PASS: Client-server TLS: vsql -m require session ssl_state=Server
- ✅ PASS: Plain-text (non-TLS) remote logins are rejected (TLS enforced by the auth policy)
- ✅ PASS: Data channel between nodes uses TLS: mode VERIFY_CA, certificate data_channel_cert_0 from Kubernetes Secret vdb-internode-tls-f592x
- ✅ PASS: Control channel (Spread) between nodes is encrypted (EncryptSpreadComm=vertica)
- ✅ PASS: Operator reports all TLS configurations: clientServer=try_verify, interNode=verify_ca, httpsNMA=try_verify
- ✅ PASS: HTTPS service (8443) answers over TLS (HTTP 401)
- ✅ PASS: NetworkPolicy: labelled client pod still connects to 5433
- ✅ PASS: NetworkPolicy: unlabelled pod is blocked from 5433 (zero-trust ingress)

<a id="t07"></a>
## T07 · Machine-to-machine database login (OAuth 2.0 / JWT)

Group `m2m` · REAL · took 25 s in the published run

**What:** An ETL service logs into Vertica with a signed token (JWT) from Keycloak instead of a password.

**How:**

- The service gets a token with its client credentials (OAuth 2.0 client_credentials grant): no user, no password.
- Vertica validates the JWT itself: signature (keys from the JWKS URL), issuer, audience, scope and expiry.
- Negative tests: tampered signature, forged payload, wrong audience, expired token, password login.
- Least privilege and audit; then the identity provider rotates its signing key.

**Expected:** Valid token = session as svc_etl over TLS (method OAuth); every forged/expired/wrong token is REJECTED.

**Checks in the published run:**

- ✅ PASS: Identity provider Keycloak ready (realm vertica-lab, OpenID Connect)
- ✅ PASS: Service svc_etl obtained a signed JWT from Keycloak with grant_type=client_credentials (no human user, no password)
- ✅ PASS: Vertica accepted the JWT: session user=svc_etl, TLS=Server, authentication method=OAuth
- ✅ PASS: svc_etl can read what it was granted (lab.sales: 5000000 rows)
- ✅ PASS: svc_etl cannot write (INSERT denied)
- ✅ PASS: svc_etl cannot drop tables (DROP denied)
- ✅ PASS: Identity comes from the token: asking for 'dbadmin' still opens a svc_etl session (no privilege escalation)
- ✅ PASS: JWT with a tampered signature is rejected
- ✅ PASS: JWT with a forged payload (azp=dbadmin, original signature) is rejected
- ✅ PASS: Valid JWT without the 'vertica' audience is rejected (svc_other, aud=null)
- ✅ PASS: Short-lived JWT (15 s) works while valid
- ✅ PASS: Expired JWT is rejected
- ✅ PASS: Password login as svc_etl is impossible (the account has no password; only tokens work)
- ✅ PASS: Audit: OAuth logins in v_monitor.user_sessions (6), rejected tokens in v_monitor.login_failures (3)
- ✅ PASS: Signing-key rotation: a token signed with the NEW key (kid 1B7Ug1yX…) is accepted without any change in Vertica (keys fetched from JWKS)

<a id="t08"></a>
## T08 · Workload isolation with resource pools

Group `isolation` · REAL · took 10 s in the published run

**What:** Shows that heavy ETL jobs cannot starve interactive BI users.

**How:**

- Create 2 resource pools: lab_etl_pool (max 2 concurrent, low priority) and lab_bi_pool (high priority).
- Fire 12 heavy ETL queries at once while BI queries keep running.

**Expected:** ETL queries run in lab_etl_pool (extra ones queue), BI queries run in lab_bi_pool.

**Checks in the published run:**

- ✅ PASS: Resource pools lab_etl_pool (capped) and lab_bi_pool (high priority) created
- ✅ PASS: BI queries executed in lab_bi_pool
- ✅ PASS: ETL queries executed in lab_etl_pool

<a id="t09"></a>
## T09 · Operator auto-repair of configuration drift

Group `reconcile` · REAL · took 67 s in the published run

**What:** Proves the operator automatically repairs anything that drifts from the desired state (the VerticaDB CR).

**How:**

- Delete an operator-managed Service: the operator recreates it.
- Scale the StatefulSet from 3 to 2 by hand: the operator restores 3 and the Vertica node rejoins.
- Delete the operator pod itself: the database keeps running and the new operator resumes.
- Try invalid CR edits (server-side dry-run): the admission webhook rejects them.

**Expected:** Every drift is undone automatically and the database stays available.

**Checks in the published run:**

- ✅ PASS: Deleted Service recreated by the operator
- ✅ PASS: StatefulSet drift corrected to the CR's desired state
- ✅ PASS: All Vertica nodes UP after drift correction
- ✅ PASS: Database unaffected while the operator is down (3/3 UP)
- ✅ PASS: Operator Deployment self-healed
- ✅ PASS: Reconciliation resumed after operator restart
- ✅ PASS: Webhook rejects changing immutable shardCount
- ✅ PASS: Webhook rejects renaming the database
- ✅ PASS: Webhook rejects shrinking the K-safe primary subcluster below 3

<a id="t10"></a>
## T10 · Self-healing: Vertica process crash

Group `selfheal` · SIM · took 60 s in the published run

**What:** Simulates Vertica crashing on one node (like an out-of-memory kill) while an application keeps querying.

**How:**

- Start a client application: 1 query per second for 60s.
- SIGKILL the Vertica process of node 2 and watch the cluster mark it DOWN.
- Kubernetes restarts the container, the operator restarts Vertica and the node rejoins.

**Expected:** Database stays UP on 2 of 3 nodes (K-safety 1), node 2 is back UP, the application recovers by itself.

**Checks in the published run:**

- ✅ PASS: Database stayed UP with K-safety while a node was down (2/3 UP)
- ✅ PASS: Crashed Vertica process automatically restarted and rejoined
- ✅ PASS: Client application recovered automatically after the process crash: longest outage 46s, availability 23.3% over the 60s window

<a id="t11"></a>
## T11 · Self-healing: Vertica pod deleted

Group `selfheal` · SIM · took 60 s in the published run

**What:** Deletes a whole Vertica pod (like an eviction) and checks it comes back with its own data.

**How:**

- Record the row count and the pod's volume, then start the client application (1 query/s for 60s).
- kubectl delete pod: the StatefulSet recreates it, the operator restarts Vertica in it.
- Check the same PersistentVolume was re-attached and that no rows were lost.

**Expected:** Pod recreated, node rejoins, same volume, row count unchanged, the application recovers by itself.

**Checks in the published run:**

- ✅ PASS: Pod recreated by StatefulSet controller
- ✅ PASS: Deleted pod recovered and Vertica node rejoined automatically
- ✅ PASS: Same PersistentVolume re-attached (pvc-<uuid>) — catalog/depot persisted
- ✅ PASS: No data loss: lab.sales still 5000000 rows
- ✅ PASS: Client application recovered automatically after the pod deletion: longest outage 9s, availability 85.2% over the 60s window

<a id="t12"></a>
## T12 · Node failure: a worker server freezes

Group `nodefail` · SIM · took 105 s in the published run

**What:** Freezes an entire worker "server" (docker pause): kubelet, container runtime and Vertica all stop responding.

**How:**

- Start the client application, then freeze a worker that hosts one Vertica pod for 60s.
- While it is frozen: write and read data through the 2 surviving nodes.
- Unfreeze it: the node returns and the operator brings Vertica back to 3/3 UP.

**Expected:** Reads AND writes keep working with 1 node lost; full recovery and application recovery without manual action.

**Checks in the published run:**

- ✅ PASS: Reads AND writes succeed with 1 of 3 nodes failed (K-safety 1)
- ✅ PASS: Node failure fully recovered without manual intervention
- ✅ PASS: Client application recovered automatically after the node freeze: longest outage 45s, availability 53.8% over the 60s window

<a id="t13"></a>
## T13 · Backup, restore and disaster recovery

Group `backup` · REAL · took 95 s in the published run

**What:** A full backup and disaster-recovery drill driven by the operator.

**How:**

- Save a restore point (VerticaRestorePointsQuery), then simulate incidents: unwanted inserts and a DROP TABLE.
- Logical backup: export a table to Parquet in S3 and read it back (auto-skipped on the -minimal image, which has no Parquet export package).
- Restore only the dropped table from the restore point.
- DISASTER: delete the whole database deployment (pods + volumes) and revive it from S3 at the restore point.

**Expected:** Dropped table restored; after the revive the data matches the restore point exactly.

**Checks in the published run:**

- ✅ PASS: Restore point saved via VerticaRestorePointsQuery (SaveRestorePoint)
- ⏭ SKIP: Logical backup (EXPORT TO PARQUET) skipped: the ParquetExport package is not part of the '-minimal' Vertica image (use the full image to enable it)
- ✅ PASS: Object-level restore: dropped table recovered with 100 rows
- ✅ PASS: Database deployment destroyed: no pods, no local volumes — only communal storage remains
- ✅ PASS: Database revived from communal storage on brand-new pods/volumes
- ✅ PASS: Point-in-time restore: bk_orders = 10,000 (the 5,000 post-backup rows are gone)
- ✅ PASS: Fact table intact after DR: lab.sales = 5000000

<a id="t14"></a>
## T14 · Elastic scaling: add and remove compute online

Group `scaling` · SIM · took 120 s in the published run

**What:** Adds and removes compute online: a secondary "analytics" subcluster with its own service.

**How:**

- Add subcluster 'analytics' with 1 node, then grow it to 2 nodes.
- Route sessions through each subcluster's service and run heavy queries on analytics only.
- Scale analytics back 2 -> 1 and remove it.

**Expected:** Every scaling step completes online and sessions land on the right subcluster.

**Checks in the published run:**

- ✅ PASS: Scale-out: new subcluster added online
- ✅ PASS: Scale-out: analytics grew to 2 nodes
- ✅ PASS: Workload isolation: every session via service vdb-analytics lands on the analytics subcluster
- ✅ PASS: Workload isolation: sessions via vdb-primary stay on the primary subcluster
- ✅ PASS: Scale-in: node drained and removed from catalog
- ✅ PASS: Subcluster removed; database back to 3 node(s)

<a id="t15"></a>
## T15 · Final health and host-safety check

Group `final` · REAL · took 2 s in the published run

**What:** Confirms the lab is left healthy and the host is untouched.

**How:**

- Repeat the health check.
- Compare the host Vertica 26.3 (version, processes, ports, config) with the snapshot from the start.
- Check no kind node is left paused and none will auto-start after a reboot.

**Expected:** Healthy cluster, host Vertica identical, restart policy = no.

**Checks in the published run:**

- ✅ PASS: Kubernetes: 4/4 nodes Ready
- ✅ PASS: VerticaDB operator Deployment available
- ✅ PASS: Admission webhook registered (invalid CR changes are rejected)
- ✅ PASS: Communal storage (MinIO) ready
- ✅ PASS: Identity provider (Keycloak) ready
- ✅ PASS: VerticaDB pods Ready: 3/3
- ✅ PASS: Persistent volume claims Bound: 3/3
- ✅ PASS: Vertica nodes UP: 3/3
- ✅ PASS: Database is K-safe (current fault tolerance 1)
- ✅ PASS: Eon communal storage location registered
- ✅ PASS: Host Vertica untouched: version, processes, ports, config mtime, dbadmin and unit identical to run start
- ✅ PASS: All kind node containers running (none left paused/stopped)
- ✅ PASS: Reboot safety: kind node restart policy = no
- ✅ PASS: No temporary test objects left behind
