#!/bin/bash
# Downloads Qwen2.5-7B-Instruct Q4_K_M GGUF to /data/models on your host.
# Run once before starting docker-compose.

set -e

MODEL_DIR="/data/models"
MODEL_FILE="qwen2.5-7b-instruct-q4_k_m.gguf"
HF_REPO="Qwen/Qwen2.5-7B-Instruct-GGUF"

echo "==> Creating model directory: $MODEL_DIR"
sudo mkdir -p $MODEL_DIR
sudo chown $USER:$USER $MODEL_DIR

echo "==> Installing huggingface-cli..."
pip install -q huggingface_hub hf_transfer

echo "==> Downloading $MODEL_FILE (~4.4GB)..."
HF_HUB_ENABLE_HF_TRANSFER=1 huggingface-cli download \
  $HF_REPO \
  --include "$MODEL_FILE" \
  --local-dir $MODEL_DIR

echo ""
echo "Done. Model saved to: $MODEL_DIR/$MODEL_FILE"
ls -lh $MODEL_DIR
