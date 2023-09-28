#!/bin/bash
set -e

# Add repos to helm and update
echo "Adding repos and updating helm repos..."
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add coder-v2 https://helm.coder.com/v2
helm repo update

# Create kind cluster and wait for condition ready
kind create cluster
echo "Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s

# Install PostgresSQL
echo "Deploying Database..."
kubectl create namespace coder
kubectl create namespace coder-workspaces
kubectl create secret generic coder-db-url -n coder \
   --from-literal=url="postgres://coder:coder@coder-db-postgresql.coder.svc.cluster.local:5432/coder?sslmode=disable"
helm install coder-db bitnami/postgresql \
    --namespace coder \
    --set auth.username=coder \
    --set auth.password=coder \
    --set auth.database=coder

# Install Coder
echo "Deploying Coder..."
helm install coder coder-v2/coder \
    --namespace coder \
    --values values.yaml


