# Stage 1: build the virtualenv with pinned dependencies
FROM python:3.12-slim AS builder
WORKDIR /build
COPY requirements.txt .
RUN python -m venv /venv && /venv/bin/pip install --no-cache-dir -r requirements.txt

# Stage 2: minimal runtime image, non-root
FROM python:3.12-slim
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    PATH="/venv/bin:$PATH"
RUN useradd --uid 10001 --create-home appuser
COPY --from=builder /venv /venv
COPY main.py /app/main.py
WORKDIR /app
USER 10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz')"
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
