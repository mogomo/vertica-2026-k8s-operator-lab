PASS|metrics-server: live resource metrics available
PASS|Operator /metrics (HTTPS, RBAC-authorised token) exposes 46 vertica_* samples
PASS|Anonymous scrape of operator metrics is rejected (HTTP 401)
PASS|The service-account token is a signed JWT (machine-to-machine identity): alg=RS256, iss=https://kubernetes.default.svc.cluster.local, sub=system:serviceaccount:vertica-lab:vlab-client, aud=["https://kubernetes.default.svc.cluster.local"], lifetime 600 s
PASS|JWT with a tampered signature is rejected (HTTP 500: Authentication failed )
PASS|JWT issued for another audience is rejected (HTTP 500: Authentication failed )
PASS|A valid JWT of another service account is accepted: the chart binds metrics-reader to system:authenticated (documented default)
PASS|Vertica server Prometheus endpoint https://<pod>:8443/v1/metrics — 634 samples (TLS)
PASS|System-table monitoring (v_monitor.*) queried successfully
PASS|Operator emits Kubernetes events for the VerticaDB (43 events in the last hour)
