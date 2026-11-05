PASS|Superuser password only referenced via Secret (not present in CR / StatefulSet specs)
PASS|Vertica server container runs as non-root (uid 5000)
PASS|RBAC: read-only SA can list pods
PASS|RBAC: read-only SA is denied delete on VerticaDB
PASS|RBAC: read-only SA is denied access to Secrets
PASS|DB RBAC: lab_reader can SELECT (5000000 rows)
PASS|DB RBAC: INSERT by read-only user is denied
PASS|Failed login attempt recorded in v_monitor.login_failures (2)
PASS|Client-server TLS: vsql -m require session ssl_state=Server
PASS|Plain-text (non-TLS) remote logins are rejected (TLS enforced by the auth policy)
PASS|Data channel between nodes uses TLS: mode VERIFY_CA, certificate data_channel_cert_0 from Kubernetes Secret vdb-internode-tls-f592x
PASS|Control channel (Spread) between nodes is encrypted (EncryptSpreadComm=vertica)
PASS|Operator reports all TLS configurations: clientServer=try_verify, interNode=verify_ca, httpsNMA=try_verify
PASS|HTTPS service (8443) answers over TLS (HTTP 401)
PASS|NetworkPolicy: labelled client pod still connects to 5433
PASS|NetworkPolicy: unlabelled pod is blocked from 5433 (zero-trust ingress)
