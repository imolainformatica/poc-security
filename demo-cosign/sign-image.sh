#!/bin/bash

# Controlla che siano stati passati i parametri
if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <role_id> <secret_id> <docker_image>"
  exit 1
fi

ROLE_ID=$1
SECRET_ID=$2
DOCKER_IMAGE=$3

export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true

echo "ROLE_ID $ROLE_ID"
echo "SECRET_ID $SECRET_ID"

# Step 1: Autenticazione tramite AppRole
echo "Autenticazione con OpenBao utilizzando AppRole..."
VAULT_TOKEN=$( bao write -field=token auth/approle/login role_id=$ROLE_ID secret_id=$SECRET_ID )

if [ -z "$VAULT_TOKEN" ]; then
  echo "Errore nell'autenticazione. Verifica il ruolo ID e Secret ID."
  exit 1
fi

echo "Autenticazione riuscita."

export VAULT_TOKEN=$VAULT_TOKEN
# Step 2: Recupera i segreti (private key e password) da OpenBao
echo "Recuperando la private key e la password..."
PRIVATE_KEY=$(bao kv get -mount=secret -field=cosign.key Cosign/Docker)
PASSWORD=$(bao kv get -mount=secret -field=password Cosign/Docker)

if [ -z "$PRIVATE_KEY" ] || [ -z "$PASSWORD" ]; then
  echo "Errore nel recupero della private key o della password."
  exit 1
fi

echo "Private key e password recuperate con successo."

export COSIGN_PASSWORD="$PASSWORD"
export PRIVATE_KEY="$PRIVATE_KEY"

docker login

# Step 3: Firma dell'immagine Docker utilizzando Cosign
echo "Firmando l'immagine Docker '$DOCKER_IMAGE'..."
cosign sign --verbose --allow-insecure-registry --recursive=true -y --key env://PRIVATE_KEY $DOCKER_IMAGE 

if [ $? -eq 0 ]; then
  echo "Immagine Docker '$DOCKER_IMAGE' firmata con successo."
else
  echo "Errore durante la firma dell'immagine Docker."
  exit 1
fi
