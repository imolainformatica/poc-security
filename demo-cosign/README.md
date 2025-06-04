# demo-cosign

## Installazione openbao

Da documentazione https://openbao.org/docs/platform/k8s/helm/

```sh
helm repo add openbao https://openbao.github.io/openbao-helm

helm install openbao openbao/openbao -n openbao --create-namespace

```

Una volta installato, si deve eseguire l'inizializzazione:

Recuperare i pod di openbao

```sh
$ kubectl get pods -l app.kubernetes.io/name=openbao -n openbao
NAME                                    READY   STATUS    RESTARTS   AGE
openbao-0                                 0/1     Running   0          1m49s
openbao-1                                 0/1     Running   0          1m49s
openbao-2                                 0/1     Running   0          1m49s
```

inizializzare e recuperare le chiavi e initial token

```sh
$ kubectl exec -n openbao -ti openbao-0 -- bao operator init
Unseal Key 1: MBFSDepD9E6whREc6Dj+k3pMaKJ6cCnCUWcySJQymObb
Unseal Key 2: zQj4v22k9ixegS+94HJwmIaWLBL3nZHe1i+b/wHz25fr
Unseal Key 3: 7dbPPeeGGW3SmeBFFo04peCKkXFuuyKc8b2DuntA4VU5
Unseal Key 4: tLt+ME7Z7hYUATfWnuQdfCEgnKA2L173dptAwfmenCdf
Unseal Key 5: vYt9bxLr0+OzJ8m7c7cNMFj7nvdLljj0xWRbpLezFAI9

Initial Root Token: s.zJNwZlRrqISjyBHFMiEca6GF
##...
```
Salvarsi le chiavi.

Unseal openbao:

```sh
## Unseal the first openbao server until it reaches the key threshold
$ kubectl exec -n openbao -ti openbao-0 -- bao operator unseal # ... Unseal Key 1
$ kubectl exec -n openbao -ti openbao-0 -- bao operator unseal # ... Unseal Key 2
$ kubectl exec -n openbao -ti openbao-0 -- bao operator unseal # ... Unseal Key 3
````

Esposizione UI

```sh
kubectl port-forward -n openbao openbao-0 8200:8200
```

## Installazione cli 

Installare la cli di opnebao. 

Per mac:

```sh
brew install openbao
```

Avendo installato opnebao in http, disabilitare la verifica tls e impostare il vaul address

```sh
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true
```

Eseguire la login con il token recuperato dall'unseal

```sh
bao login
````
al prompt inserire il token

```sh
bao login                              
Token (will be hidden): 
Success! You are now authenticated. The token information displayed below is
already stored in the token helper. You do NOT need to run "bao login" again.
Future OpenBao requests will automatically use this token.

Key                  Value
---                  -----
token                s.QG5meenqKy6HUv88SxG8mIiY
token_accessor       UgQ9Xn1xKRcCp5SvJizopEWe
token_duration       ∞
token_renewable      false
token_policies       ["root"]
identity_policies    []
policies             ["root"]
```

Installare Cosign. Per Mac

```sh
brew install cosign
```

## Predisposizione Openbao

### Impostazione secrets

Abilitiamo il secret engine di tipo KV in versione v2. Lo impostiamo nel path /secret

```sh
bao secrets enable -path=secret kv-v2
```

Generazione chiavi con Cosign:

```sh
cosign generate-key-pair
```

> Viene richiesta una password al prompt. Inserire una password e premere invio. Confermare la password e premere invio.

Vengono generati i file cosign.key e cosign.pub. Questi file e la password andranno salvati su Openbao. Li inseriamo nel path Cosign/Docker poichè l'idea è di utilizzare questa chiave solo per firmare artefatti Docker. Inseriremo altre chiavi per altri tipi. Per un utilizzo generico o diverso inserite il path che preferite.

```sh
bao kv put secret/Cosign/Docker \
    cosign.key="$(cat cosign.key)" \
    cosign.pub="$(cat cosign.pub)" \
    password="tua_password_cosign"
```

risultato del tipo:

```sh
====== Secret Path ======
secret/data/Cosign/Docker

======= Metadata =======
Key                Value
---                -----
created_time       2025-03-21T11:07:50.224259835Z
custom_metadata    <nil>
deletion_time      n/a
destroyed          false
version            1
```

### Policy

In Openbao quando si creano oggetti, hanno tutti come default la policy "deny all". Bisogna creare policy specifiche per oggetti. Creiamo una policy di sola read per il secret. Per semplicità creiamo una policy generica per tutti i secret sotto il path Cosign.

La policy viene salvata in un file hcl e poi applicata. Creaimo il file `cosign-read-policy.hcl` del tipo

```json
path "secret/data/Cosign/*" {
  capabilities = ["read"]
}
```

e applichiamolo:

```sh
bao policy write cosign-read cosign-read-policy.hcl
```
Risultato del tipo:

```sh
Success! Uploaded policy: cosign-read
```

> È possibile verificare la policy col comando:
>  ```sh
>  bao policy read cosign-read
>  ```
>ottenendo qualcosa del tipo:
>```sh
>path "secret/data/Cosign/*" {
>capabilities = ["read"]
>}
>```

### Creazione application

Per poter operare creiamo due application con approle auth. Le due applicazioni saranno il CISERVER che firma gli artefatti, e KUBERNETES che li deve cerificare. 

Iniziamo con l'abilitare l'autenticazione approle

```sh
bao auth enable approle
```

con risultato simile a:
```sh
Success! Enabled approle auth method at: approle/
```

Creiamo il ruolo CISERVER a cui associamo la policy cosign-read:

```sh
bao write auth/approle/role/CISERVER policies="cosign-read"
```

con risultato del tipo:

```sh
Success! Data written to: auth/approle/role/CISERVER
```

Recuperiamo i dettagli del ruolo:

```sh
ROLE_ID=$(bao read auth/approle/role/CISERVER/role-id -format=json | jq -r .data.role_id)
SECRET_ID=$(bao write -f auth/approle/role/CISERVER/secret-id -format=json | jq -r .data.secret_id)

echo "CI_SERVER ROLE_ID: $ROLE_ID"
echo "CI_SERVER SECRET_ID: $SECRET_ID"
```

### Recupero informazioni

Per poter recuperare i token possiamo operare via api.  Recuperiamo il token associato al ruolo. Prendiamo ad esempio CISERVER:

```sh
TOKEN=$(curl -s --request POST \
    --data "{\"role_id\":\"$ROLE_ID\", \"secret_id\":\"$SECRET_ID\"}" \
    http://localhost:8200/v1/auth/approle/login | jq -r .auth.client_token)

echo "TOKEN: $TOKEN"
```

E con questo token possiamo provare a leggere i secret:

```sh
curl -H "X-Vault-Token: $TOKEN" \
     http://localhost:8200/v1/secret/data/Cosign/Docker
```

### Firma immagini

Firmare l'immagine con lo script sign-image.sh. lanciare lo script passando role id, secret id e nome dell'immagine. L'immagine deve essere su un registry "remoto".

Per usare un registry di test, avviare via docker:

```sh
docker run -d --restart=always -p "5005:5000" -e REGISTRY_STORAGE_DELETE_ENABLED=true --name "registry" registry:2
```

Impostare un cluster kind per utilizzare tale registry. Lanciare il comando:

```sh
kind create cluster --name "kind" --config "kind-cluster-registry.yaml"
```

## Installare Kyverno

Utilizzando helm:

```sh
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
```

Installiamo la policy:

```sh
kubectl apply -f kyverno-policy.yaml
```

Inseriamo nella parte publik key la nostra public key e nel namespace il namepsace su cui andare ad operare. In questo caso andiamo ad operare limitatamente al namespace `kyverno-app`

## Test deploy

Lanciare il comando helm

```sh
helm upgrade --install prova . -n kyverno-app 
```

Se si utilizza l'immagine firmata il deploy andrà a buon fine, altrimenti il deploy fallirà per la policy