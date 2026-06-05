# syntax=docker/dockerfile:1
FROM python:3.11-slim

WORKDIR /app

# libgl1 + libglib2.0-0 are required by OpenCV (pulled in by ultralytics)
RUN apt-get update \
    && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# CPU-only PyTorch first: keeps the image ~1.5 GB instead of ~6 GB.
# The serving container does not need CUDA at inference time.
RUN pip install --no-cache-dir \
    torch torchvision \
    --index-url https://download.pytorch.org/whl/cpu

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .

EXPOSE 8080
ENTRYPOINT ["python", "server.py"]
