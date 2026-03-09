#!/bin/bash
# Builds the FastAPI image, pushes to ECR, and deploys/updates K8s.
# Run this every time you change the API code.

set -e

REGION="us-east-1"
REPO_NAME="llm-api"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME"
IMAGE_TAG="${1:-latest}"    # pass a tag as arg, defaults to 'latest'

echo "==> Building image: $ECR_URI:$IMAGE_TAG"
cd "$(dirname "$0")/.."    # run from aws/ directory

docker build -f Dockerfile -t $REPO_NAME:$IMAGE_TAG .

echo ""
echo "==> Logging in to ECR..."
aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin \
    "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

echo ""
echo "==> Pushing image..."
docker tag $REPO_NAME:$IMAGE_TAG $ECR_URI:$IMAGE_TAG
docker push $ECR_URI:$IMAGE_TAG

echo ""
echo "==> Applying Kubernetes manifests..."
kubectl apply -f k8s/namespace.yaml

# Create secret if it doesn't exist yet
if ! kubectl get secret llm-secrets -n llm &>/dev/null; then
  echo ""
  echo "==> Secret 'llm-secrets' not found. Creating it now."
  echo -n "Enter your Cloudflare tunnel URL (e.g. https://llm.yourdomain.com): "
  read LLAMA_URL
  echo -n "Enter an API key for your gateway (any strong string): "
  read API_KEY

  kubectl create secret generic llm-secrets \
    --namespace llm \
    --from-literal=llama-url="$LLAMA_URL" \
    --from-literal=api-key="$API_KEY"
  echo "    Secret created."
fi

kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

echo ""
echo "==> Rolling out updated image..."
kubectl set image deployment/llm-api \
  api=$ECR_URI:$IMAGE_TAG \
  -n llm

kubectl rollout status deployment/llm-api -n llm

echo ""
echo "==> Getting LoadBalancer URL..."
kubectl get svc llm-api -n llm

echo ""
echo "============================================"
echo "Deployment complete."
echo "Test with:"
echo "  LB_URL=\$(kubectl get svc llm-api -n llm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo '  curl http://$LB_URL/health'
echo "============================================"
