# API tests

`adopter-testing.postman_collection.json` is the Sunbird RC adopter test suite (identity, credential schema, credentials, OID4VC), adjusted for the deployed image version.

## Run

From `deploy-as-code/helm/v2/credentialling`:

```bash
./install.sh test core      # identity + schema + credentials
./install.sh test oid4vc    # OID4VC issuance / presentation flows
./install.sh test           # everything
```

Other sets: `identity`, `schema`, `credentials`. The base URL is taken from `global.host` in `global-values.yaml`; override with `BASE_URL=http://<host>`. Reports are written to `test-results/` (not committed).

The collection can also be imported into Postman. Set the collection variables `identity_base`, `schema_base`, `credential_base`, `oid4vc_base` to `http://<host>/identity-service`, `http://<host>/credential-schema-service`, `http://<host>/credentials-service`, `http://<host>/oid4vc-service`.

## Source and changes

- Source: [Sunbird-RC/sunbird-rc-core](https://github.com/Sunbird-RC/sunbird-rc-core), branch `v2.1.1`, `services/adopter-testing.postman_collection.json`.
- The source collection is written for the `v2.1.1` branch. The released images are `v2.1.0`, so three requests are adjusted:

| Request | Change | Reason (v2.1.0 behaviour) |
|---|---|---|
| List schemas | added `?tags=postman-crud` | listing without `tags` returns 500 |
| List credentials | added `?tags=postman-crud` | listing without `tags` returns 500 |
| Update schema | added `schema.schema.description` | `description` is a required field |

The changes are also recorded in the collection's own description.

## Updating

When the images move to a version that includes these fixes (v2.1.1 or later), replace the file with the upstream collection for that version unchanged, and update this README.
