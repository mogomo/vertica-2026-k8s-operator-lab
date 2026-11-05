PASS|Identity provider Keycloak ready (realm vertica-lab, OpenID Connect)
PASS|Service svc_etl obtained a signed JWT from Keycloak with grant_type=client_credentials (no human user, no password)
PASS|Vertica accepted the JWT: session user=svc_etl, TLS=Server, authentication method=OAuth
PASS|svc_etl can read what it was granted (lab.sales: 5000000 rows)
PASS|svc_etl cannot write (INSERT denied)
PASS|svc_etl cannot drop tables (DROP denied)
PASS|Identity comes from the token: asking for 'dbadmin' still opens a svc_etl session (no privilege escalation)
PASS|JWT with a tampered signature is rejected
PASS|JWT with a forged payload (azp=dbadmin, original signature) is rejected
PASS|Valid JWT without the 'vertica' audience is rejected (svc_other, aud=null)
PASS|Short-lived JWT (15 s) works while valid
PASS|Expired JWT is rejected
PASS|Password login as svc_etl is impossible (the account has no password; only tokens work)
PASS|Audit: OAuth logins in v_monitor.user_sessions (6), rejected tokens in v_monitor.login_failures (3)
PASS|Signing-key rotation: a token signed with the NEW key (kid 1B7Ug1yX…) is accepted without any change in Vertica (keys fetched from JWKS)
