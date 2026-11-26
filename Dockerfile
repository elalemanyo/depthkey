FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    TORCH_HOME=/models/torch \
    HF_HOME=/models/hf

WORKDIR /app

# CPU-only PyTorch (this machine has no GPU), then Depth Pro 2 pinned to a commit.
# torchvision must come from the same CPU index, or timm pulls a mismatched CUDA build.
RUN pip install --index-url https://download.pytorch.org/whl/cpu "torch>=2.7" torchvision \
 && pip install \
      "depth_pro_2 @ https://github.com/apple-aiml-research/ml-depth-pro-2/archive/aa389cbb0b74341664ed663a0966c859905cd6c0.tar.gz" \
      "fastapi>=0.115" "uvicorn[standard]>=0.32"

# Bake the weights into the image so the container starts offline.
ARG MODEL=depthpro2-s
ENV MODEL=${MODEL}
RUN python -c "import os; from depth_pro_2 import create_model_and_transforms as c; c(os.environ['MODEL'], device='cpu')"

COPY app/ /app/app/

EXPOSE 8000
CMD ["uvicorn", "app.server:app", "--host", "0.0.0.0", "--port", "8000"]
