# Production deployment using Helm charts
The below scripts will help the adopters to deploy SunbirdRC services in kubernetes environment.

## Prerequisites
- Kubernetes Cluster with minimum 3 nodes
- [Helm](https://helm.sh/docs/intro/install/)
- kubectl
- Ingress
- Postgres DB
- Domain URL (domain url mapped to kubernetes cluster)

## Deployment steps

### Clone the repo
```bash
git clone https://github.com/Sunbird-RC/deployment.git
cd helm/v2
```

### Pre check
Make sure from the current directory you're able to run the below commands
```bash
kubectl cluster-info
kubectl get nodes
kubectl get ns
helm version
```

### Create namespace
```bash
kubectl create ns demo-registry
```
`Feel free to use a different name for the namespace. Use the same name in the reset of the commands.`


## Vault Deployment 
# (Chart version : 0.24.0 and vault image: hashicorp/vault:1.13.1) 

We use hashicorp vault as the keystore (for ore details you can refer here : https://developer.hashicorp.com/vault )

You can refer to this offical documentation for healm based deployment on a kubernetes cluster. This deployment guide covers the steps required to install and configure a single HashiCorp Vault cluster.(https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-raft-deployment-guide )


- Please follow the steps to deploy the vault service. _And use the same namespace that you have created in the previous step_.  
- Unsealing a Vault is a critical process that involves reconstructing the master key from multiple key shares. This process is designed to provide added security.

### Here are the basic steps to unseal a HashiCorp Vault:

- Initialization (First-time setup):
If you are initializing Vault for the first time, you'll need to run the following command to initialize the Vault and obtain unseal keys and the initial root token:

```bash
vault operator init
```
The output will provide unseal keys and an initial root token(<root_token>). Keep this information secure. (**Make sure to have a copy of these keys or store it in a key.txt file securley**)

make sure to use the <root_token> in the values.yaml.(VAULT_SECRET_TOKEN : base64 format of this <root_token>) 

Unsealing:
When Vault starts, it is sealed, and you need to unseal it using the unseal keys. You can unseal the Vault with the following command:

```bash
vault operator unseal
```

You will be prompted to enter an unseal key. Repeat this process with multiple unseal keys until the required threshold is reached.

Access Vault:
After unsealing, you can access Vault using the initial root token or other tokens with appropriate permissions.

```bash
vault login <root_token>
```
Replace <root_token> with the initial root token obtained during the initialization.

Remember that unsealing requires a specified threshold (generally 3 ) of key shares to be provided, typically set during initialization. It's a security measure to ensure that a single compromised key is not enough to unseal the Vault.

- Once you have the keys secured. You have to enable a KV engine 

## Enable KV Engine in vault :
Use the vault secrets enable command to enable a KV engine. In this example, we're enabling the KV version 2 engine. You can replace secret-v2 with any path you prefer.
```bash
vault secrets enable -path=kv kv-v2
```
This command enables the KV version 2 secrets engine at the specified path (kv). You can choose a different path based on your requirements. (But what ever name you provide here has to be use as the root_path: http://vault:8200/v1/kv in the values.yaml)


### Create secrets
Convert all the passwords/secrets into base64 format and update these values in `values.yaml` file
**Secrets**
- VAULT_SECRET_TOKEN: Initial Root Token that you get when you deploy vault service (ex : hvs.*************)
- DB_URL: Database Connection URL with username and password (Example: postgres://{{databse_usename}}:{{database_password}}@localhost:5432/{{database_name:sunbirdrc}})


`VAULT_SECRET_TOKEN and DB_URL are mandotry secrets to be set. Other secrets can be set to empty `

### Modify configuration values
Configuration values related to vault address, base url and rootpath etc should be modified in values.yaml file.


### Deploy helm charts
```bash
helm upgrade --install --namespace=demo-registry demo-registry helm_charts --create-namespace
```
**Output**
```
Release "demo-registry" does not exist. Installing it now.
NAME: demo-registry
LAST DEPLOYED: Thu May  4 17:02:08 2023
NAMESPACE: demo-registry
STATUS: deployed
REVISION: 1
```

**Check if all the pods are running**
```bash
kubectl get pods -n demo-registry
```


