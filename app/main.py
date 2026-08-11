"""devops-lab demo API.

Deliberately tiny: the point is the platform around it (CI, K8s, GitOps,
monitoring), not the app. Every endpoint exists to demonstrate a probe,
a config source, or a metric.
"""

import os
import time

from fastapi import FastAPI, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

APP_VERSION = os.getenv("APP_VERSION", "dev")
GREETING = os.getenv("GREETING", "hello")

# Readiness is mutable at runtime so Kubernetes probe behavior can be
# demonstrated live: POST /toggle-ready and watch the pod leave the Service.
_state = {"ready": os.getenv("START_READY", "true").lower() == "true"}

REQUESTS = Counter("app_requests_total", "Total HTTP requests", ["path", "status"])
LATENCY = Histogram("app_request_seconds", "Request latency in seconds", ["path"])

app = FastAPI(title="devops-lab", version=APP_VERSION)


@app.middleware("http")
async def observe(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    path = request.url.path
    if path != "/metrics":
        REQUESTS.labels(path=path, status=str(response.status_code)).inc()
        LATENCY.labels(path=path).observe(time.perf_counter() - start)
    return response


@app.get("/")
def root():
    return {"message": GREETING, "version": APP_VERSION}


@app.get("/healthz")
def healthz():
    # Liveness: OK as long as the process can serve requests at all.
    return {"status": "ok"}


@app.get("/readyz")
def readyz(response: Response):
    # Readiness: whether this pod should receive traffic right now.
    if not _state["ready"]:
        response.status_code = 503
        return {"ready": False}
    return {"ready": True}


@app.post("/toggle-ready")
def toggle_ready():
    _state["ready"] = not _state["ready"]
    return {"ready": _state["ready"]}


@app.get("/metrics")
def metrics():
    # Exact-path route (a Starlette Mount would 307-redirect /metrics -> /metrics/)
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
