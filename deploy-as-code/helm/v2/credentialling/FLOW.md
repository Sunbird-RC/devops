# Sunbird RC Credentialling – How It Works (Helm v2)

This document explains how the credentialling services start, connect to each other, and get their configuration when deployed with the Helm v2 charts. It mirrors `docker/v2/credentialling/docker-compose.yml` and `setup_vault.sh`.

---

## 0. Folder structure

Same layout as the Sunbird Spark installer:

```
deploy-as-code/helm/v2/credentialling/
├── README.md                 ← this document
├── install.sh                ← deploy script (install / template / status / uninstall)
├── global-values.yaml        ← environment settings (host, DB password, auth, vault, oid4vc)
├── images.yaml               ← every image + tag, mapped to each chart
├── global-resources.yaml     ← cpu / memory / volume size per chart
└── credentialling/           ← umbrella chart
    ├── Chart.yaml
    ├── values.yaml           ← chart defaults
    └── charts/
        ├── config/                     shared ConfigMap  <release>-config
        ├── secrets/                    shared Secret     rc-secret
        ├── vault/                      vault + setup Job + auto-unseal
        ├── db/                         postgres
        ├── identity-service/
        ├── credential-schema-service/
        ├── credentials-service/
        └── oid4vc-service/
```

Deploy (from `deploy-as-code/helm/v2/credentialling`):

```bash
export DB_PASSWORD='<strong-password>'   # kept out of git
./install.sh template    # dry run: lint + render to rendered.yaml
./install.sh install     # checks tools, cluster access, permissions, then deploys
./install.sh status      # pods, vault seal status, vault-keys secret
./install.sh uninstall   # removes the release, keeps data volumes and vault-keys
```

`install.sh` runs `helm upgrade --install rc credentialling -f images.yaml -f global-resources.yaml -f global-values.yaml`. Later files override earlier ones, and all of them override the chart defaults in `credentialling/values.yaml` and `charts/*/values.yaml`. `RELEASE`, `NAMESPACE`, `TIMEOUT` and `VALUES_FILE` can be overridden with environment variables.

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
                     wallets / users
                           │
                           ▼
   oid4vc ──────► credential ──────► schema ──────► identity ──────► vault
                      │                 │               │
                      └────────────────►db◄─────────────┘
```

---

## 2. Where each service gets its settings

Many settings are needed by more than one service, for example the identity URL or the vault address. They are kept in **one shared ConfigMap and one shared Secret** instead of being repeated in every chart:

```
 ConfigMap <release>-config  (config chart)          Secret rc-secret  (secrets chart)
   IDENTITY_BASE_URL, SCHEMA_BASE_URL,                 DATABASE_URL
   CREDENTIAL_SERVICE_BASE_URL,                        VAULT_SECRET_TOKEN
   VAULT_ADDR, VAULT_BASE_URL, VAULT_ROOT_PATH,
   ENABLE_AUTH, JWKS_URI, SIGNING_ALGORITHM, ...
              │                                               │
              ▼                                               ▼
   identity, schema, credential, oid4vc           identity (DB + vault token)
                                                  schema, credential (DB only)
```

Some resources belong to one component only, so its own chart creates them:

| Created by | Resource | Contents |
|---|---|---|
| vault chart | ConfigMap `vault-config` | `vault.json` (same file as Docker) |
| vault chart (setup Job) | Secret `vault-keys` | Unseal keys and root token (replaces `keys.txt`) |
| db chart | Secret `db-secret` | Postgres username and password |

This is the Kubernetes equivalent of Docker's single `.env` file. In Docker every service reads `${VAR}` from `.env`. In Helm every service reads from `<release>-config` and `rc-secret`.

---

## 3. Startup flow

Kubernetes has no `depends_on`, so everything starts together. A service whose dependency is not ready fails and Kubernetes restarts it until the dependency is up. The system settles within a few minutes.

### Step 1 – db comes up
Postgres starts with its data on a persistent volume. identity, schema, and credential connect to it through `DATABASE_URL` (host `db`).

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
  f. copy root token ───────────────────────► rc-secret / VAULT_SECRET_TOKEN
  g. restart identity-service
```

| Docker (`setup_vault.sh`) | Helm (`vault-setup` Job) |
|---|---|
| `vault operator init > keys.txt` | Init, then store the output in Secret `vault-keys` |
| `vault operator unseal` × 3 | Same |
| `vault secrets enable -path=kv kv-v2` | Same |
| `sed VAULT_TOKEN=... .env` | Write the token into `rc-secret` |
| `docker-compose up -d` (services start with the token) | Restart identity so it picks up the new token |

### Step 4 – identity gets the token
A pod reads its settings only when it starts. The identity pod from step 1 still has the placeholder token, so the Job restarts it. After the restart:

```
rc-secret / VAULT_SECRET_TOKEN ──► identity VAULT_TOKEN ──► vault (http://vault:8200/v1/kv)
```

### Step 5 – everything else settles
schema reaches identity, credential reaches schema and identity, and oid4vc reaches credential. All services are now running.

---

## 4. What happens later

| Event | What happens |
|---|---|
| **vault restarts** | Vault comes back sealed. A small sidecar container next to vault notices this and unseals it with the keys from `vault-keys`. In Docker this is a manual step. |
| **db restarts** | Data stays on the volume. The services reconnect. |
| **any service restarts** | It reads `<release>-config` and `rc-secret` again and continues. |
| **`helm upgrade`** | The setup Job runs again. Vault is already initialised, so the Job only unseals it if needed and checks that the token is still in `rc-secret`. No data is lost. |
| **`helm uninstall`** | The services are removed. The db and vault volumes and the `vault-keys` Secret stay, so a reinstall picks up the same data. |

---

## 5. Things to keep in mind

- **`vault-keys` is the master key.** Anyone who can read it can open vault. If it is lost while the vault volume still exists, vault can never be unsealed again. Back it up and restrict access to it.
- **The root token is used by identity**, the same as in Docker.
- **oid4vc keeps sessions in memory** (`SESSION_STORE=memory`), as in Docker. Sessions are lost when oid4vc restarts.
