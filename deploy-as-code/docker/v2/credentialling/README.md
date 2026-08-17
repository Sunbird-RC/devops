## Credentialling 2.0

Docker Compose setup for the credential-issuance stack: `vault`, `identity`, `schema`,
`credential`, and `db`.

## Installation

```bash
make compose-init
```

This starts Vault, waits for it to unseal, then brings up `identity`, `schema`, `credential`
and `db`.

Copy `.env.example` to `.env` and adjust values before running if you need non-default
credentials or URLs.

## OID4VC (optional)

`oid4vc-service` is an OpenID4VCI / OpenID4VP protocol facade in front of `credential`,
`identity` and `schema`. It's gated behind a compose profile, so the stack above is unaffected
unless you opt in.

- Start it after the base stack is up:

```bash
docker compose --profile oid4vc up -d oid4vc-service
```

- `OID4VC_PUBLIC_URL` (in `.env`) must be a host a wallet/phone can resolve — this stack has no
  gateway proxying the oid4vc routes, so the URL must include the port
  (`http://<host>:3400`), not just `localhost`. It feeds the QR deep link and the
  proof-of-possession `aud` claim, so a mismatch fails PoP.
- A credential schema is invisible to wallets until its `schema` record has
  `oid4vciConfig.oid4vciEnabled: true`.
- Wallet-compat flags: set `OID4VC_DRAFT13_COMPAT=true` for MOSIP Inji Wallet, and
  `OID4VP_LEGACY_CLIENT_ID_SCHEME=true` for walt.id.
- There is no `redis` service in this stack, so `OID4VC_SESSION_STORE` stays `memory` by
  default — fine for single-instance/dev use. Add a `redis` service and set it to `redis` for
  production.
- Health check: `curl -f http://localhost:3400/health`.
