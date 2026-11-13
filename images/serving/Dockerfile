# syntax=docker/dockerfile:1
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    YOLO_CONFIG_DIR=/tmp

WORKDIR /app

# libgl1 + libglib2.0-0 are required by OpenCV (pulled in by ultralytics).
RUN apt-get update \
    && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# CPU-only PyTorch: ~1.5 GB image instead of ~6 GB. The predictor runs on CPU so
# the single GPU stays free for training.
RUN pip install torch==2.14.1 torchvision==0.29.1 \
    --index-url https://download.pytorch.org/whl/cpu

COPY requirements.txt .
# gcc is needed only to build `pyasn` (an sdist-only kserve>=0.18 dependency);
# it is removed in the same layer.
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libc6-dev \
    && pip install -r requirements.txt \
    && apt-get purge -y --auto-remove gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*

COPY server.py .

RUN useradd --uid 1000 --create-home app
USER 1000

EXPOSE 8080
ENTRYPOINT ["python", "server.py"]
