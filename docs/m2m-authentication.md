# Machine-to-machine logins with OAuth 2.0 and JWT

ETL jobs, microservices and schedulers talk to the database without a person at the
keyboard. They still need an identity, and that identity should not be a password
stored in a config file. This lab shows the alternative: **the service proves who it is
to an identity provider, receives a short-lived signed token (a JWT), and Vertica
validates that token itself.**

```mermaid
sequenceDiagram
  autonumber
  participant ETL as ETL service (pod)
  participant KC as Keycloak (identity provider)
  participant V as Vertica
  ETL->>KC: POST /token  grant_type=client_credentials (client id + secret)
  KC-->>ETL: signed JWT (RS256): iss, azp=svc_etl, aud=vertica, scope=vertica, exp
  ETL->>V: TLS connection, vsql -M oauth -U svc_etl (token in VSQL_OAUTH_ACCESS_TOKEN)
  V->>KC: GET JWKS (public signing keys)
  V->>V: check signature, issuer, audience, scope, expiry; map azp -> database user
  V-->>ETL: session as svc_etl (authentication method OAuth, TLS Server)
```

## 1. The identity provider (Keycloak)

`--install` step 12 deploys Keycloak 26.7.5 in the namespace `vertica-lab-idp` and
configures the realm `vertica-lab` with the Keycloak admin CLI (`kcadm.sh`). Client
secrets travel on stdin only, never on a command line or in a log.

| Object | Setting | Why |
|---|---|---|
| Realm `vertica-lab` | access token lifetime 300 s | Tokens are short-lived passes |
| Client scope `vertica` | audience mapper that adds `vertica` to `aud`; the scope `vertica` appears in the token | Vertica accepts only tokens meant for it |
| Client `svc_etl` | confidential client, service account on, `client_credentials` only (no browser flow, no password grant), default scopes `basic`, `service_account`, `vertica` | The ETL service |
| Client `svc_other` | same, but **without** the `vertica` scope | Negative test: a valid token for another audience |
| Client `svc_short` | with the `vertica` scope, token lifetime 15 s | Negative test: expiry |

Every other default client scope is removed from the service clients, so the token
carries exactly one audience and only the claims a service needs. The published run's
token for `svc_etl`:

```
alg=RS256  iss=<keycloak>/realms/vertica-lab  azp=svc_etl  aud="vertica"  scope="vertica"  lifetime=300 s
```

The client secrets are stored in the Kubernetes Secret `vertica-lab/oauth-clients`, which
is the only credential the ETL job mounts.

## 2. The Vertica side

One authentication record, for TLS connections only, granted only to the service users:

```sql
CREATE AUTHENTICATION vlab_oauth_jwt METHOD 'oauth' HOST TLS '0.0.0.0/0';
ALTER AUTHENTICATION vlab_oauth_jwt SET
  validate_type              = 'JWT',
  jwt_issuer                 = '<keycloak>/realms/vertica-lab',
  jwt_jwks_url               = '<keycloak>/realms/vertica-lab/protocol/openid-connect/certs',
  jwt_user_mapping           = 'azp',
  jwt_accepted_audience_list = 'vertica',
  jwt_accepted_scope_list    = 'vertica';

CREATE USER svc_etl;                         -- no password: only a token can log in
GRANT AUTHENTICATION vlab_oauth_jwt TO svc_etl;
GRANT USAGE ON SCHEMA lab TO svc_etl;
GRANT SELECT ON lab.sales TO svc_etl;        -- least privilege
```

`<keycloak>` is `http://keycloak.vertica-lab-idp.svc.cluster.local:8080` inside the
cluster.

- `validate_type='JWT'`: Vertica validates the token itself, with the provider's public
  signing keys.
- `jwt_jwks_url`: where the keys come from. When the provider rotates its keys, Vertica
  picks up the new ones.
- `jwt_user_mapping='azp'`: the `azp` claim (the client id) becomes the database user.
- The record is **never granted to PUBLIC or dbadmin**, so it cannot shadow the
  operator's own TLS-certificate login.

The installed record, as Vertica shows it:

```
   auth_name    | auth_method | auth_host_type | is_auth_enabled | parameters
----------------+-------------+----------------+-----------------+------------------------------------------
 vlab_oauth_jwt | OAUTH       | HOSTSSL        | True            | validate_type=JWT, jwt_issuer=<keycloak>/realms/vertica-lab,
                |             |                |                 | jwt_user_mapping=azp, jwt_accepted_audience_list=vertica,
                |             |                |                 | jwt_accepted_scope_list=vertica, jwt_jwks_url=...
```

## 3. Logging in

```bash
# 1. get a token (inside the cluster)
TOKEN=$(curl -s -u "svc_etl:$CLIENT_SECRET" -d grant_type=client_credentials \
  http://keycloak.vertica-lab-idp.svc.cluster.local:8080/realms/vertica-lab/protocol/openid-connect/token \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

# 2. log in with it, over TLS
export VSQL_OAUTH_ACCESS_TOKEN="$TOKEN"
vsql -m require -h vdb-primary -d labdb -M oauth -U svc_etl \
  -c "SELECT user_name, authentication_method, ssl_state FROM sessions WHERE session_id = current_session();"
```

Tips:

- Pass the token in the environment variable `VSQL_OAUTH_ACCESS_TOKEN` (or the driver's
  OAuth access-token property), never on the command line.
- Name the database user on every OAuth login (`-U svc_etl`). The session identity still
  comes from the signed token.
- Treat tokens like passwords while they are valid: don't print or log them. The lab
  masks every token it handles.

## 4. The demo: a Kubernetes Job that logs in with a JWT

`--demo` step 8 runs the Job `vlab-etl-job`. Its only credential is the client secret,
from the Secret `oauth-clients`; it never sees a database password. Output of the
published run:

```
1) requesting a token from the identity provider (grant_type=client_credentials)
   token received (933 characters, signed JWT; not printed)
2) logging into Vertica with the token over TLS
 db_user | auth  |  tls   |  country  | readings | avg_c
---------+-------+--------+-----------+----------+-------
 svc_etl | OAuth | Server | Israel    |        4 |  22.9
 svc_etl | OAuth | Server | Australia |        1 |  21.7
 svc_etl | OAuth | Server | Japan     |        2 |  17.6
 svc_etl | OAuth | Server | UK        |        2 |  12.1
 svc_etl | OAuth | Server | USA       |        1 |   9.8
(5 rows)
```

## 5. What T07 proves

`sudo ./vertica-k8s-lab.sh --test --only m2m` runs these 15 checks. All passed in the
published run:

| # | Check | How |
|---|---|---|
| 1 | Identity provider ready | Keycloak Deployment ready |
| 2 | Token issued | `client_credentials` grant for `svc_etl` (112 ms) |
| 3 | Login accepted | session user `svc_etl`, TLS `Server`, method `OAuth` (132 ms) |
| 4 | Read what was granted | `SELECT COUNT(*) FROM lab.sales` = 5,000,000 |
| 5 | Cannot write | INSERT: permission denied |
| 6 | Cannot drop | DROP TABLE: insufficient privileges |
| 7 | Identity from the token | the same token with `-U dbadmin` still opens an `svc_etl` session |
| 8 | Tampered signature rejected | one character of the signature changed |
| 9 | Forged payload rejected | payload changed to `azp=dbadmin`, original signature kept |
| 10 | Wrong audience rejected | a valid token of `svc_other`, which has no `vertica` audience |
| 11 | Short token works | `svc_short`'s 15-second token logs in |
| 12 | Expired token rejected | the same token 20 s later |
| 13 | No password path | password login as `svc_etl` fails: the account has no password |
| 14 | Audit | logins in `v_monitor.user_sessions`, rejected tokens in `v_monitor.login_failures` |
| 15 | Key rotation | Keycloak gets a new active RS256 key; a token signed with it is accepted with **no change in Vertica** |

The audit view at the end of T07:

```
 user_name |       authentication_method       | sessions
-----------+-----------------------------------+----------
 svc_etl   | OAuth                             |        7
 svc_etl   | rejected: reject                  |        1
 svc_etl   | rejected: token validation failed |        1
 svc_other | rejected: token validation failed |        1
 svc_short | OAuth                             |        1
 svc_short | rejected: token validation failed |        1
```

## 6. JWTs on the Kubernetes side (T05)

Kubernetes uses the same idea for its own machine identities. T05 calls the operator's
Prometheus `/metrics` endpoint (HTTPS) with the client pod's service-account token, an
RS256 JWT issued by the cluster:

- With a valid token of an authorised service account: 46 `vertica_*` metric samples.
- Without a token: rejected (HTTP 401).
- With a tampered token, or a token issued for another audience: rejected ("Authentication
  failed"; the operator logs "invalid bearer token").
- A valid token of another service account is accepted, because the operator's Helm
  chart binds the metrics-reader role to all authenticated identities. That is the
  documented default; in production, bind it only to your Prometheus service account.

## 7. Production notes

- Run the identity provider in production mode: HTTPS endpoints, high availability, a
  durable database, or use your corporate provider (Okta, OTDS, Keycloak).
- Use an HTTPS JWKS URL and issuer.
- Keep token lifetimes short and let services request new tokens.
- Grant OAuth records to specific users or roles only.
- Use one audience per token and a dedicated scope for the database.
- Map identities with the claim that fits your provider (`azp`, `sub`, or a custom
  claim), and create the database users ahead of time or with just-in-time provisioning.
