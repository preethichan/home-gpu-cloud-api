#!/bin/bash
# Provisions ECR repository and EKS cluster on AWS.
# Run once from any machine with AWS CLI + eksctl configured.
# Prerequisites:
#   aws cli:   https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html
#   eksctl:    https://eksctl.io/installation/
#   kubectl:   https://kubernetes.io/docs/tasks/tools/
#   docker:    installed and running

set -e

REGION="us-east-1"
CLUSTER_NAME="llm-api-cluster"
REPO_NAME="llm-api"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "==> AWS Account: $ACCOUNT_ID  Region: $REGION"

# ── ECR ───────────────────────────────────────────────────────────────────────
echo ""
echo "==> Creating ECR repository: $REPO_NAME"
aws ecr create-repository \
  --repository-name $REPO_NAME \
  --region $REGION \
  --image-scanning-configuration scanOnPush=true \
  2>/dev/null || echo "    (already exists, continuing)"

ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME"
echo "    ECR URI: $ECR_URI"

# ── EKS ───────────────────────────────────────────────────────────────────────
echo ""
echo "==> Creating EKS cluster: $CLUSTER_NAME (this takes ~15 minutes)"
eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --nodegroup-name api-nodes \
  --node-type t3.small \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 6 \
  --managed \
  --asg-access \
  2>/dev/null || echo "    (already exists, continuing)"

echo ""
echo "==> Configuring kubectl..."
aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME

# ── Update deployment image reference ─────────────────────────────────────────
echo ""
echo "==> Patching deployment.yaml with ECR URI..."
sed -i "s|ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com|$ECR_URI|g" \
  ../k8s/deployment.yaml

echo ""
echo "============================================"
echo "Done. Next: run deploy.sh to build and push."
echo "ECR URI: $ECR_URI"
echo "============================================"
