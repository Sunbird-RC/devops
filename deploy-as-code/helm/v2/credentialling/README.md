# Sunbird RC Credentialling – How It Works (Helm v2)

This document explains how the credentialling services start, connect to each other, and get their configuration when deployed with these Helm charts. It mirrors `docker/v2/credentialling/docker-compose.yml` and `setup_vault.sh`.

---

## 0. Folder structure and deploy

Same layout as the Sunbird Spark installer:

```
deploy-as-code/helm/v2/credentialling/     ← umbrella chart + deploy files
├── Chart.yaml
├── values.yaml               ← chart defaults (no secrets)
├── charts/
│   ├── vault/                      vault + setup Job + auto-unseal
│   ├── db/                         postgres
│   ├── identity-service/           own ConfigMap + Secret
│   ├── credential-schema-service/  own ConfigMap + Secret
│   ├── credentials-service/        own ConfigMap + Secret
│   └── oid4vc-service/             own env
├── install.sh                ← deploy script (install / template / status / uninstall)
├── global-values.yaml        ← environment settings (host, DB, auth, vault, oid4vc)
├── images.yaml               ← every image + tag, mapped to each chart
├── global-resources.yaml     ← cpu / memory / volume size per chart
├── .helmignore               ← keeps the deploy files out of the chart package
└── README.md                 ← this document
```

Deploy (from `deploy-as-code/helm/v2/credentialling`):

```bash
export DB_PASSWORD='<strong-password>'   # kept out of git
./install.sh template    # dry run: lint + render to rendered.yaml
./install.sh install     # checks tools, cluster access, permissions, then deploys
./install.sh status      # pods, vault seal status, vault-keys secret
./install.sh uninstall   # removes the release, keeps data volumes and vault-keys
```

`install.sh` runs `helm upgrade --install rc . -f images.yaml -f global-resources.yaml -f global-values.yaml`. Later files override earlier ones, and all of them override the chart defaults in `values.yaml` and `charts/*/values.yaml`. `RELEASE`, `NAMESPACE`, `TIMEOUT` and `VALUES_FILE` can be overridden with environment variables.

---

## 1. The pieces

| Component | What it does | Talks to |
|---|---|---|
| **db** (postgres) | Stores data for identity, schema, and credential | – |
| **vault** | Stores the private keys of DIDs created by identity | – |
| **identity-service** | Creates DIDs and signs data | db, vault |
| **credential-schema-service** | Stores credential schemas and gets them signed by identity | db, identity |
| **credentials-service** | Issues and verifies credentials | db, identity, schema |
| **oid4vc-service** | Lets wallets receive and present credentials (OpenID4VC) | credential, identity, schema |

```
   oid4vc ──────► credential ──────► schema ──────► identity ──────► vault
                      │                 │               │
                      └────────────────►db◄─────────────┘
```

All services are **cluster-internal** (no ingress). The public domain belongs to Spark's `nginx-public-ingress`; add routes there if a service must be reachable from outside.

---

## 2. Where each service gets its settings

Each chart owns its own ConfigMap and Secret, with only the variables that service needs – the same list as its `environment:` block in docker compose. Shared values are written once in `global-values.yaml` (`global.*`) and each chart picks what it needs.

```
global-values.yaml (global.*)
        │
        ├──► identity-service   ConfigMap: VAULT_ADDR, VAULT_BASE_URL, VAULT_ROOT_PATH, VAULT_TIMEOUT,
        │                                  VAULT_PROXY, SIGNING_ALGORITHM, WEB_DID_BASE_URL,
        │                                  ENABLE_AUTH, JWKS_URI
        │                       Secret:    DATABASE_URL
        │                       + VAULT_TOKEN from Secret "vault-token" (created by the vault setup Job)
        │
        ├──► credential-schema  ConfigMap: IDENTITY_BASE_URL, ENABLE_AUTH, JWKS_URI
        │                       Secret:    DATABASE_URL
        │
        ├──► credentials        ConfigMap: IDENTITY_BASE_URL, SCHEMA_BASE_URL, CREDENTIAL_SERVICE_BASE_URL,
        │                                  ENABLE_AUTH, JWKS_URI, QR_TYPE
        │                       Secret:    DATABASE_URL
        │
        ├──► oid4vc             env:       service URLs, ENABLE_AUTH, JWKS_URI + oid4vc-service.env.*
        │
        └──► db                 Secret db-secret: POSTGRES_USER, POSTGRES_PASSWORD
```

`DATABASE_URL` is built automatically from `global.db` (`postgres://<user>:<password>@db:5432/<database>`), so the DB password is entered once – preferably as `DB_PASSWORD` for `install.sh`.

Secrets that are not managed by Helm (created at runtime by the vault setup Job):

| Secret | Contents |
|---|---|
| `vault-keys` | Unseal keys and root token (replaces `keys.txt`) |
| `vault-token` | `VAULT_TOKEN` for identity-service |

A pod restarts automatically when its ConfigMap or Secret changes (checksum annotations).

---

## 3. Startup flow

Kubernetes has no `depends_on`, so everything starts together. A service whose dependency is not ready fails and Kubernetes restarts it until the dependency is up. The system settles within a few minutes.

### Step 1 – db comes up
Postgres starts with its data on a persistent volume. identity, schema, and credential connect through `DATABASE_URL` (host `db`).

### Step 2 – vault comes up, locked
Vault starts **uninitialised and sealed**, exactly as in Docker. identity cannot store keys yet.

### Step 3 – the setup Job unlocks vault (replaces `setup_vault.sh`)

```
 vault-setup Job
 ───────────────
  a. wait for vault
  b. first time only: vault operator init ──► 5 unseal keys + root token
  c. save keys + token ─────────────────────► Secret "vault-keys"
     (later runs: read them back from "vault-keys")
  d. unseal vault with 3 keys
  e. enable kv secrets engine at "kv"
  f. write root token ──────────────────────► Secret "vault-token"
  g. restart identity-service
```

| Docker (`setup_vault.sh`) | Helm (`vault-setup` Job) |
|---|---|
| `vault operator init > keys.txt` | Init, then store the output in Secret `vault-keys` |
| `vault operator unseal` × 3 | Same |
| `vault secrets enable -path=kv kv-v2` | Same |
| `sed VAULT_TOKEN=... .env` | Write the token into Secret `vault-token` |
| `docker-compose up -d` (services start with the token) | Restart identity so it picks up the token |

### Step 4 – identity gets the token
A pod reads its settings only when it starts. identity starts before the Job (its `VAULT_TOKEN` reference is optional), so the Job restarts it. After the restart:

```
Secret vault-token / VAULT_TOKEN ──► identity ──► vault (http://vault:8200/v1/kv)
```

### Step 5 – everything else settles
schema reaches identity, credential reaches schema and identity, and oid4vc reaches credential. All services are now running.

---

## 4. What happens later

| Event | What happens |
|---|---|
| **vault restarts** | Vault comes back sealed. A sidecar container next to vault notices this and unseals it with the keys from `vault-keys`. In Docker this is a manual step. |
| **db restarts** | Data stays on the volume. The services reconnect. |
| **any service restarts** | It reads its own ConfigMap and Secret again and continues. |
| **`./install.sh install` again (upgrade)** | The setup Job runs again. Vault is already initialised, so the Job only unseals it if needed and checks the token. No data is lost. |
| **`./install.sh uninstall`** | The services are removed. The db and vault volumes and the `vault-keys` / `vault-token` Secrets stay, so a reinstall picks up the same data. |

---

## 5. API tests (Postman collection)

`postman-collection.json` is the Sunbird RC adopter Postman collection (identity, credential schema, credentials, OID4VC). `./install.sh test` runs it with Newman against `http://<global.host>`:

```bash
./install.sh test core      # identity + schema + credentials
./install.sh test oid4vc    # OID4VC issuance / presentation flows
./install.sh test           # everything
```

Other sets: `identity`, `schema`, `credentials`. Override the target with `BASE_URL=http://<host>`. Reports are written to `test-results/` (not committed). The file can also be imported into Postman; set the collection variables `identity_base`, `schema_base`, `credential_base`, `oid4vc_base` to `http://<host>/identity-service`, `http://<host>/credential-schema-service`, `http://<host>/credentials-service`, `http://<host>/oid4vc-service`.

Source: [Sunbird-RC/sunbird-rc-core](https://github.com/Sunbird-RC/sunbird-rc-core), branch `v2.1.1`, `services/adopter-testing.postman_collection.json`. That collection targets the `v2.1.1` branch, while the released images are `v2.1.0`, so three requests are adjusted:

| Request | Change | Reason (v2.1.0 behaviour) |
|---|---|---|
| List schemas | added `?tags=postman-crud` | listing without `tags` returns 500 |
| List credentials | added `?tags=postman-crud` | listing without `tags` returns 500 |
| Update schema | added `schema.schema.description` | `description` is a required field |

When the images move to a version that includes these fixes, replace the file with the upstream collection unchanged and remove this table.

---

## 6. Things to keep in mind

- **`vault-keys` is the master key.** Anyone who can read it can open vault. If it is lost while the vault volume still exists, vault can never be unsealed again. Back it up and restrict access to it.
- **The root token is used by identity**, the same as in Docker.
- **oid4vc keeps sessions in memory** (`SESSION_STORE=memory`), as in Docker. Sessions are lost when oid4vc restarts.
