#!/usr/bin/env bash
# Sets up TinyClick for the agent's `ground` tool: its own Python, and the
# model converted to MLX. Nothing goes into any other Python.
#
#   scripts/setup-vision.sh                  # the dev build's folder
#   scripts/setup-vision.sh --release        # the release build's folder
#   scripts/setup-vision.sh --model <dir>    # copy an MLX conversion from <dir>
#
# Puts, under ~/Library/Application Support/ParrotFlow Dev (or ParrotFlow):
#   vision-venv/               Python 3.11 with mlx, mlx-vlm, transformers, pillow
#   models/tinyclick-mlx/      the weights, and a README that says where they came from
#
# Without --model it converts Krystianz/TinyClick itself. That needs torch for
# the conversion only, in a throwaway venv that is deleted afterwards.
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/ParrotFlow Dev"
FROM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --release) SUPPORT="$HOME/Library/Application Support/ParrotFlow" ;;
        --model) FROM="$2"; shift ;;
        *) echo "usage: $0 [--release] [--model <converted dir>]" >&2; exit 2 ;;
    esac
    shift
done

VENV="$SUPPORT/vision-venv"
MODEL="$SUPPORT/models/tinyclick-mlx"
# mlx-vlm declares gradio, datasets, opencv and scipy. The Florence-2 path does
# not import them, so it goes in without its dependencies: 1.8 GB became the
# size printed below.
PACKAGES=(mlx==0.32.2 mlx-metal==0.32.2 mlx-lm==0.29.1 transformers==4.49.0 tokenizers==0.21.4
          huggingface-hub==0.36.2 safetensors pillow numpy requests pyyaml jinja2 protobuf)

command -v uv >/dev/null || { echo "needs uv: https://docs.astral.sh/uv/" >&2; exit 1; }

echo "Python:  $VENV"
uv venv --quiet --python 3.11 "$VENV"
uv pip install --quiet --python "$VENV/bin/python" "${PACKAGES[@]}"
uv pip install --quiet --python "$VENV/bin/python" --no-deps mlx-vlm==0.1.23

mkdir -p "$SUPPORT/models"
if [ -f "$MODEL/model.safetensors" ]; then
    echo "Model:   $MODEL (already there)"
elif [ -n "$FROM" ]; then
    echo "Model:   $MODEL (copied from $FROM)"
    rm -rf "$MODEL.partial"
    cp -R "$FROM" "$MODEL.partial"
    mv "$MODEL.partial" "$MODEL"
else
    echo "Model:   $MODEL (converting Krystianz/TinyClick)"
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    uv venv --quiet --python 3.11 "$WORK/venv"
    uv pip install --quiet --python "$WORK/venv/bin/python" "${PACKAGES[@]}" \
        mlx-vlm==0.1.23 torch torchvision timm einops
    HF_HOME="$WORK/hf" "$WORK/venv/bin/python" -m mlx_vlm.convert \
        --hf-path Krystianz/TinyClick --mlx-path "$MODEL.partial"
    mv "$MODEL.partial" "$MODEL"
fi

cat > "$MODEL/README.md" <<'EOF'
# TinyClick, converted to MLX

What the agent's `ground` tool runs (`built-in/recipes/ground_server.py`).

- Model: TinyClick, Florence-2-base fine-tuned to answer "click on <thing>"
  with a point. 0.27 B parameters. MIT licence.
- Source: https://huggingface.co/Krystianz/TinyClick, a mirror. The original,
  Samsung/TinyClick, answered 401 on 2026-09-23.
- Converted with mlx-vlm 0.1.23 (`python -m mlx_vlm.convert`), weights as
  converted (bf16), mlx 0.32.2.
- Made by `scripts/setup-vision.sh` in the ParrotFlow repository.
EOF

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARROTFLOW_GROUND_MODEL="$MODEL" "$VENV/bin/python" "$ROOT/built-in/recipes/ground_server.py" \
    --check < /dev/null

echo "Disk:    $(du -sh "$VENV" | cut -f1) Python, $(du -sh "$MODEL" | cut -f1) model"
