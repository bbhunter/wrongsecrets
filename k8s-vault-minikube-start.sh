#!/bin/bash
# set -o errexit
# set -o pipefail
# set -o nounset

source scripts/check-available-commands.sh

checkCommandsAvailable cat docker grep helm jq kubectl minikube openssl sed vault

echo "This is only a script for demoing purposes. You can comment out line 22 and work with your own k8s setup"
echo "This script is based on the steps defined in https://learn.hashicorp.com/tutorials/vault/kubernetes-minikube . Vault is awesome!"
echo "This requires minikube-version: 1.36.0 or later"
minikube start --kubernetes-version=v1.33.0 --driver=docker

echo "Patching default ns with new PSA; we should run as restricted!"
kubectl apply -f k8s/workspace-psa.yml

kubectl get configmaps | grep 'secrets-file' &> /dev/null
if [ $? == 0 ]; then
  echo "secrets config is already installed"
else
  kubectl apply -f k8s/secrets-config.yml
fi
echo "Setting up the bitnami sealed secret controler"
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.28.0/controller.yaml
kubectl apply -f k8s/sealed-secret-controller.yaml
kubectl apply -f k8s/main.key
echo "Setting up challenge 53"
kubectl apply -f k8s/challenge53/secret-challenge53.yml
kubectl delete pod -n kube-system -l name=sealed-secrets-controller
kubectl create -f k8s/sealed-challenge48.json
echo "finishing up the sealed secret controler part"
echo "do you need to decrypt and/or handle things for the sealed secret use kubeseal"

kubectl get secrets | grep 'funnystuff' &> /dev/null
if [ $? == 0 ]; then
   echo "secrets secret is already installed"
else
  kubectl apply -f k8s/secrets-secret.yml
  kubectl apply -f k8s/challenge33.yml
fi

helm list | grep 'vault' &> /dev/null
if [ $? == 0 ]; then
   echo "Vault is already installed"
else
   helm repo add hashicorp https://helm.releases.hashicorp.com
fi
kubectl create ns vault
helm upgrade --install vault hashicorp/vault --version 0.30.0 --namespace vault --values k8s/helm-vault-values.yml

isvaultrunning=$(kubectl get pods -n vault --field-selector=status.phase=Running)
while [[ $isvaultrunning != *"vault-0"* ]]; do echo "waiting for Vault1" && sleep 2 && isvaultrunning=$(kubectl get pods -n vault --field-selector=status.phase=Running); done
while [[ $isvaultrunning != *"vault-1"* ]]; do echo "waiting for Vault2" && sleep 2 && isvaultrunning=$(kubectl get pods -n vault --field-selector=status.phase=Running); done
while [[ $isvaultrunning != *"vault-2"* ]]; do echo "waiting for Vault3" && sleep 2 && isvaultrunning=$(kubectl get pods -n vault --field-selector=status.phase=Running); done
echo "Setting up port forwarding"
kubectl port-forward vault-0 8200:8200 -n vault &
echo "Unsealing Vault"
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > cluster-keys.json
cat cluster-keys.json | jq -r ".unseal_keys_b64[]"
VAULT_UNSEAL_KEY=$(cat cluster-keys.json | jq -r ".unseal_keys_b64[]")

echo "⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰"
echo "PLEASE COPY PASTE THE FOLLOWING VALUE: ${VAULT_UNSEAL_KEY} , you will be asked for it 3 times to unseal the vaults"

echo "Unsealing Vault 0"
kubectl exec -it vault-0 -n vault  -- vault operator unseal $VAULT_UNSEAL_KEY

echo "Joining & unsealing Vault 1"
kubectl exec -it vault-1 -n vault -- vault operator raft join http://vault-0.vault-internal:8200
kubectl exec -it vault-1 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY

echo "Joining & unsealing Vault 2"
kubectl exec -it vault-2 -n vault -- vault operator raft join http://vault-0.vault-internal:8200
kubectl exec -it vault-2 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY

echo "Obtaining root token"
jq .root_token cluster-keys.json > commentedroottoken

sed "s/^\([\"']\)\(.*\)\1\$/\2/g" commentedroottoken > root_token
ROOTTOKEN=$(cat root_token)

echo "Logging in"
kubectl exec vault-0 -n vault -- vault login $ROOTTOKEN

echo "Enabling kv-v2 kubernetes"
kubectl exec vault-0 -n vault -- vault secrets enable -path=secret kv-v2

echo "Putting a secret in"
kubectl exec vault-0 -n vault -- vault kv put secret/secret-challenge vaultpassword.password="$(openssl rand -base64 16)"

echo "Putting a challenge key in"
kubectl exec vault-0 -n vault -- vault kv put secret/injected vaultinjected.value="$(openssl rand -base64 16)"

echo "Putting a challenge key in"
kubectl exec vault-0 -n vault -- vault kv put secret/codified challenge47secret.value="debugvalue"

echo "Putting a subkey issue in"
kubectl exec vault-0 -n vault -- vault kv put secret/wrongsecret aaaauser."$(openssl rand -base64 8)"="$(openssl rand -base64 16)"

echo "Oepsi metadata"
kubectl exec vault-0 -n vault -- vault kv metadata put -mount=secret -custom-metadata=secret="$(openssl rand -base64 16)" wrongsecret

echo "Enable k8s auth"
kubectl exec vault-0 -n vault -- vault auth enable kubernetes

echo "Writing k8s auth config"
kubectl exec vault-0 -n vault -- /bin/sh -c 'vault write auth/kubernetes/config \
        token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
        kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
        kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'

kubectl exec vault-0 -n vault -- vault audit enable file file_path=stdout

echo "Writing policy for secret-challenge"
kubectl exec vault-0 -n vault -- /bin/sh -c 'vault policy write secret-challenge - <<EOF
path "secret/data/secret-challenge" {
  capabilities = ["read"]
}
path "secret/metadata/wrongsecret" {
  capabilities = ["read", "list" ]
}
path "secret/subkeys/wrongsecret" {
  capabilities = ["read", "list" ]
}
path "secret/data/wrongsecret" {
  capabilities = ["read", "list" ]
}
path "secret/data/application" {
  capabilities = ["read"]
}
path "secret/data/injected" {
  capabilities = ["read"]
}
path "secret/data/codified" {
  capabilities = ["read"]
}
EOF'

kubectl exec vault-0 -n vault -- /bin/sh -c 'vault policy write standard_sre - <<EOF
path "secret/data/secret-challenge" {
  capabilities = ["list"]
}
path "secret/" {
  capabilities = ["list"]
}
path "secret/*" {
  capabilities = ["list"]
}
path "secret/*/subkeys/"{
capabilities = ["list", "read"]
}
path "secret/*/subkeys/*"{
capabilities = ["list", "read"]
}
path "secret/metadata/*"{
capabilities = ["list", "read"]
}
EOF'

kubectl exec vault-0 -n vault -- vault auth enable userpass
kubectl exec vault-0 -n vault -- vault write auth/userpass/users/helper password=foo policies=standard_sre

echo "Write secrets for secret-challenge"
kubectl exec vault-0 -n vault -- vault write auth/kubernetes/role/secret-challenge \
        bound_service_account_names=vault \
        bound_service_account_namespaces=default \
        policies=secret-challenge \
        ttl=24h \
 && vault kv put secret/secret-challenge vaultpassword.password="$(openssl rand -base64 16)" \
 && vault kv put secret/application vaultpassword.password="$(openssl rand -base64 16)" \

kubectl create serviceaccount vault
echo "Deploy secret challenge app"
kubectl apply -f k8s/secret-challenge-vault-deployment.yml
golivecounter=0
while [[ $(kubectl get pods -l app=secret-challenge -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]];
do
  echo "waiting for secret-challenge" && sleep 2;
  ((golivecounter+=1))
  if [ $((golivecounter % 10)) -eq 0 ]; then
    kubectl describe deployment secret-challenge
  else
    echo "waiting for secret-challenge, step $golivecounter"s
  fi
  if [ $((golivecounter % 15)) -eq 0 ]; then
    kubectl describe pod -l app=secret-challenge
  else
    echo "waiting for secret-challenge, step $golivecounter"
  fi
done
kubectl logs -l app=secret-challenge -f >> pod.log &
kubectl expose deployment secret-challenge --type=LoadBalancer --port=8080
kubectl port-forward \
    $(kubectl get pod -l app=secret-challenge -o jsonpath="{.items[0].metadata.name}") \
    8080:8080 \
    &
echo "Do minikube delete to stop minikube from running and cleanup to start fresh again"
echo "wait 20 seconds so we can check if vault-k8s-container works"
sleep 20
curl http://localhost:8080/spoil/challenge-7
echo "logs from pod to make sure:"
cat pod.log
