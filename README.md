# LLM Stack — Qwen2.5-7B on Home M40, API on AWS EKS

## Architecture

```
Internet
    │
    ▼
AWS EKS (t3.small, no GPU, ~$122/mo)
FastAPI pods (2 replicas, auto-scales to 6)
    │
    │ HTTPS via Cloudflare Tunnel (free)
    ▼
Your Ubuntu PC
llama-server (M40 GPU, sm_52)
Qwen2.5-7B-Instruct Q4_K_M
--parallel 8 (8 concurrent slots)
```

---

## Prerequisites

### On your Ubuntu PC
- Docker + docker-compose installed
- NVIDIA driver 535, CUDA 12.2 (confirmed)
- NVIDIA Container Toolkit installed
- A domain managed by Cloudflare (free account works)

### On any machine for AWS deployment
- AWS CLI configured (`aws configure`)
- eksctl installed
- kubectl installed
- Docker installed

---

## Step 1 — Home PC: Download the Model

```bash
cd home/
chmod +x download-model.sh
./download-model.sh
```

Downloads `qwen2.5-7b-instruct-q4_k_m.gguf` (~4.4GB) to `/data/models/`.

---

## Step 2 — Home PC: Set Up Cloudflare Tunnel

You need a domain on Cloudflare. Free account at cloudflare.com works.

```bash
cd home/
chmod +x setup-tunnel.sh

# Edit setup-tunnel.sh first — change DOMAIN to your actual domain
nano setup-tunnel.sh

./setup-tunnel.sh
```

This will:
1. Install cloudflared
2. Open browser to authorize Cloudflare
3. Create tunnel named `llama-tunnel`
4. Update `cloudflared/config.yml` with your tunnel ID
5. Create DNS record `llm.yourdomain.com` pointing to the tunnel

---

## Step 3 — Home PC: Start llama-server + Tunnel

```bash
cd home/
docker-compose up -d

# Watch logs — wait for "model loaded" message
docker-compose logs -f llama-server

# Confirm tunnel is connected
docker-compose logs cloudflared
# Should show: "Registered tunnel connection"

# Test locally
curl http://localhost:8080/health
# Should return: {"status":"ok"}

# Test via Cloudflare tunnel
curl https://llm.yourdomain.com/health
# Should return the same
```

---

## Step 4 — AWS: Provision Infrastructure (once)

```bash
cd aws/ecr/
chmod +x provision.sh deploy.sh

# Configure AWS CLI if not done
aws configure

./provision.sh
# Takes ~15 minutes for EKS cluster creation
```

---

## Step 5 — AWS: Build and Deploy API

```bash
cd aws/ecr/
./deploy.sh

# It will prompt for:
#   - Cloudflare tunnel URL: https://llm.yourdomain.com
#   - API key: (choose any strong string, e.g. run: openssl rand -hex 32)
```

---

## Step 6 — Test the Full Stack

```bash
# Get the LoadBalancer DNS name
LB_URL=$(kubectl get svc llm-api -n llm \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "API endpoint: http://$LB_URL"

# Health check
curl http://$LB_URL/health

# Chat request (replace YOUR_API_KEY)
curl http://$LB_URL/v1/chat/completions \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-7b-instruct",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user",   "content": "Hello, what can you do?"}
    ],
    "max_tokens": 256
  }'

# Streaming request
curl http://$LB_URL/v1/chat/completions \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Count to 10"}],
    "stream": true
  }'
```

---

## Updating the API

After changing `aws/api/main.py`:

```bash
cd aws/ecr/
./deploy.sh v2    # pass any tag
```

Zero-downtime rolling update. Old pods stay alive until new ones pass readiness probe.

---

## Monitoring

```bash
# Pod status
kubectl get pods -n llm

# Pod logs
kubectl logs -n llm -l app=llm-api --tail=100 -f

# HPA status (autoscaler)
kubectl get hpa -n llm

# If your PC goes offline:
# readinessProbe fails → pods removed from LB → clients get 503
# When PC comes back → health passes → pods re-added automatically
```

---

## Cost

| Component         | Monthly   |
|-------------------|-----------|
| EKS control plane | ~$73      |
| 2x t3.small nodes | ~$30      |
| Network LB        | ~$18      |
| ECR storage       | ~$1       |
| Cloudflare Tunnel | $0        |
| **Total**         | **~$122** |
| Your PC (GPU)     | electricity only |

### To reduce cost further
- Use `t3.micro` nodes if traffic is very low (~$15 instead of $30)
- Shut down EKS when not needed: `eksctl scale nodegroup --nodes=0`
- Add a 1-year Savings Plan for ~40% discount on EC2

---

## Project Structure

```
llm-stack/
├── home/
│   ├── Dockerfile.llama        # llama-server, built for sm_52
│   ├── docker-compose.yml      # runs llama-server + cloudflared
│   ├── download-model.sh       # downloads Qwen2.5-7B GGUF
│   ├── setup-tunnel.sh         # one-time Cloudflare tunnel setup
│   └── cloudflared/
│       └── config.yml          # tunnel config (fill in TUNNEL_ID)
└── aws/
    ├── Dockerfile              # FastAPI image (no GPU)
    ├── api/
    │   ├── main.py             # FastAPI app
    │   └── requirements.txt
    ├── k8s/
    │   ├── namespace.yaml
    │   ├── deployment.yaml     # 2 replicas, HPA, topology spread
    │   └── service.yaml        # NLB LoadBalancer
    └── ecr/
        ├── provision.sh        # creates ECR + EKS (run once)
        └── deploy.sh           # build → push → rollout
```
