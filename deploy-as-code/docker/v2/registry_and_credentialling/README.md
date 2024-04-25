## Registry and Credentialling 2.0


# Steps to setup registry 2.0 :

## System requirements

- 4 Cores
- 8 GB RAM
- Min 100 GB disk

## Prerequisites 

- This guide assumes a some familiarity with basic linux commands. If not, [here](https://ubuntu.com/tutorials/command-line-for-beginners#1-overview) is a great place to start.
- Don't copy-paste the $ signs, they indicate that what follows is a terminal command

## Terminal emulator
- Linux and MacOS will have a terminal installed already. For Windows, it is recommended that you use git-bash, which you can install from [here](https://git-scm.com/download/win).
- Type echo Hi in the terminal once it is installed. If installed correctly, you should see Hi appear when you hit enter.

## Docker

- Installation instructions for Docker can be found [here](https://docs.docker.com/engine/install/).
- Run docker -v in terminal to check if docker has been installed correctly:

```bash 
   docker -v
```

## Docker Compose
- Installation instructions can be found [here](https://docs.docker.com/compose/install/).
- Run docker compose version in the terminal to check if docker compose has been installed correctly:

```bash
docker compose version
```


## Installation

- We have already created a .env file for basic setup. This configuration will help your setup the basic verison of registry 2.0 for issuing credentials. If you want to customize any settings of the registry you can edit the .env file or else you can go ahead with this configuration

- We are using Hashicorp vault as the keystore manager. You can know more about it [here](https://www.vaultproject.io/)

- The first step will be to start the vault using the below command 

```bash
make compose-init

```

- This will start the vault service. If it fails to start the vault might already be up and running.

- Once the vault is up and running and unsealed, it will generate a set of 5 keys which can be user futher to unseal the vault and a root access token to access the vault as a default user. All these data is stored in the keys.txt. This will be generated run time.

- Create the schema files in the schemas directory. We have already provided example schemas (Official.json and Insurance.json)

### Steps to setup keycloak:

- Open the keycloak admin console `http://localhost:8080/auth/`
- Goto Clients -> admin-api -> Credentials
- Click on Regenerate Secret and copy the new value
- Set KEYCLOAK_SECRET with the copied value in .env file
- Add a DNS mapping in your /etc/hosts file

```bash 

cat /etc/hosts

nano /etc/hosts

```
- edit this file and add a new mapping ex : (127.0.0.1	keycloak)

- Start all the services:

```bash
docker-compose up -d

```

- Check if all the services are started using 

```bash
docker-compose ps

```

- Access the registry swagger json `http://localhost:8081/api/docs/swagger.json`

- We have added a postman collection for registry 2.0 in the postmanCollection/ directory.


- To start vault from scratch you can use this commands. Remove the existing volumes vault-data and db-data, and stop all the running docker containers 
- Use this commands only when you want to start the vault service from scratch. 

``` bash 

sudo docker compose down 

sudo rm -rf db-data/ vault-data/

```

## Postman_Collection 

https://api.postman.com/collections/13315057-7e45f3d2-7232-4787-8cb7-72708bb122c1?access_key=PMAT-01HS0FYYFHFKJRP6AX1A0ETYBZ
