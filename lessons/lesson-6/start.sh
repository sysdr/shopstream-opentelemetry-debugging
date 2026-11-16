#!/usr/bin/env bash
# ShopStream observability — Day 6: Write the postmortem
# Writes the project into ./shopstream-otel, builds it and starts it with Docker Compose,
# runs the unit tests, writes verify.sh, verifies, then runs the demo. Stop with: bash stop.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$ROOT/shopstream-otel"
export COMPOSE_PROJECT_NAME=shopstream-otel
cd "$ROOT"
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
command -v docker >/dev/null || { echo "[ERROR] docker not found. Install Docker Desktop (Windows/macOS) or Docker Engine (Linux)."; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "[ERROR] 'docker compose' not available. Update Docker."; exit 1; }
docker info >/dev/null 2>&1 || { echo "[ERROR] the Docker engine is not running. Start Docker Desktop and try again."; exit 1; }

say "Writing the project into ./shopstream-otel"
rm -rf "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/."
cat > "$PROJECT_DIR/Dockerfile" <<'SHOPSTREAM_EOF'
FROM python:3.12-slim
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ app/
COPY tools/ tools/
COPY tests/ tests/
ENV PYTHONUNBUFFERED=1
# Large blocks come straight from the OS and go back when freed, so a cleared leak really releases memory.
ENV MALLOC_MMAP_THRESHOLD_=131072
CMD ["gunicorn", "-b", "0.0.0.0:8000", "-w", "1", "--threads", "16", "--timeout", "120", "app.main:app"]
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/."
cat > "$PROJECT_DIR/compose.yaml" <<'SHOPSTREAM_EOF'
# ShopStream: three Python services, Jaeger, Prometheus and Grafana. No bind mounts: everything is built into the image.
x-app: &app
  build: .
  image: shopstream-otel-app:latest
  restart: unless-stopped
  depends_on: [jaeger]

services:
  jaeger:
    image: jaegertracing/all-in-one:1.62.0
    environment:
      COLLECTOR_OTLP_ENABLED: "true"
    ports: ["16686:16686"]
  prometheus:
    build: ./prometheus
    image: shopstream-otel-prometheus:latest
    ports: ["9090:9090"]
  grafana:
    build: ./grafana
    image: shopstream-otel-grafana:latest
    ports: ["3000:3000"]
    depends_on: [prometheus]
  checkout:
    <<: *app
    environment: {SERVICE: checkout}
    ports: ["8101:8000"]
  inventory:
    <<: *app
    environment: {SERVICE: inventory}
    ports: ["8102:8000"]
  payments:
    <<: *app
    environment: {SERVICE: payments}
    ports: ["8103:8000"]
  tools:
    <<: *app
    restart: "no"
    profiles: ["tools"]
    command: ["python", "-c", "print('tools')"]
    working_dir: /srv/tools
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/."
cat > "$PROJECT_DIR/requirements.txt" <<'SHOPSTREAM_EOF'
flask==3.1.0
gunicorn==23.0.0
requests==2.32.3
prometheus-client==0.21.1
opentelemetry-api==1.29.0
opentelemetry-sdk==1.29.0
opentelemetry-exporter-otlp-proto-http==1.29.0
opentelemetry-instrumentation-flask==0.50b0
opentelemetry-instrumentation-requests==0.50b0
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/app"
cat > "$PROJECT_DIR/app/__init__.py" <<'SHOPSTREAM_EOF'

SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/app"
cat > "$PROJECT_DIR/app/main.py" <<'SHOPSTREAM_EOF'
"""ShopStream services: one image, three roles chosen by SERVICE (checkout, inventory, payments)."""
import ctypes
import gc
import os
import random
import threading
import time
import uuid

import requests
from flask import Flask, Response, g, jsonify, request
from opentelemetry import trace
from prometheus_client import CONTENT_TYPE_LATEST, Gauge, Histogram, generate_latest

from app import telemetry
from app.resilience import CircuitBreaker, backoff

SERVICE = telemetry.SERVICE
INVENTORY_URL = os.environ.get("INVENTORY_URL", "http://inventory:8000")
PAYMENTS_URL = os.environ.get("PAYMENTS_URL", "http://payments:8000")

app = Flask(__name__)
log = telemetry.setup(app)
tracer = trace.get_tracer("shopstream")
http = requests.Session()

STOCK = {f"SKU-{i}": 10**9 for i in range(20)}
# Day 2: fault injection, changed at runtime with POST /admin/fault {"delay_ms": 300, "error_rate": 0}
FAULT = {"delay_ms": 0, "error_rate": 0.0, "leak_kb": 0, "pool_leak_rate": 0.0}

# Day 4: inventory's database connection pool (a semaphore standing in for real connections),
# and a list that grows when the memory-leak fault is on.
POOL_SIZE = int(os.environ.get("POOL_SIZE", "5"))
pool = threading.BoundedSemaphore(POOL_SIZE)
pool_state = {"in_use": 0}
pool_lock = threading.Lock()
LEAK = []
POOL_IN_USE = Gauge("db_pool_in_use", "Connections checked out", ["service"])
POOL_SIZE_G = Gauge("db_pool_size", "Connections in the pool", ["service"])
POOL_WAIT = Histogram("db_pool_wait_seconds", "Time waiting for a connection", ["service"],
                      buckets=(0.001, 0.01, 0.05, 0.1, 0.25, 0.5, 1, 2))
POOL_SIZE_G.labels(SERVICE).set(POOL_SIZE)
POOL_IN_USE.labels(SERVICE).set(0)
stock_lock = threading.Lock()


@app.before_request
def _start():
    g.t0 = time.perf_counter()
    if request.path.startswith("/admin") or request.path in ("/metrics", "/health", "/catalog"):
        return None
    if FAULT["delay_ms"]:
        with tracer.start_as_current_span("injected_delay") as span:
            span.set_attribute("fault.delay_ms", FAULT["delay_ms"])
            time.sleep(FAULT["delay_ms"] / 1000)
    if FAULT["error_rate"] and random.random() < FAULT["error_rate"]:
        return jsonify(error="injected failure", service=SERVICE), 500
    return None


def release_memory():
    """What a restart does for memory: drop the leaked objects and hand free pages back to the OS."""
    gc.collect()
    try:
        ctypes.CDLL("libc.so.6").malloc_trim(0)
    except OSError:
        pass


@app.post("/admin/fault")
def set_fault():
    body = request.get_json(force=True, silent=True) or {}
    FAULT["delay_ms"] = int(body.get("delay_ms", 0))
    FAULT["error_rate"] = float(body.get("error_rate", 0))
    FAULT["leak_kb"] = int(body.get("leak_kb", 0))
    FAULT["pool_leak_rate"] = float(body.get("pool_leak_rate", 0))
    if body.get("reset"):
        reset_pool()
        LEAK.clear()
        release_memory()
    log.warning("fault injection changed", extra={"fields": dict(FAULT)})
    return jsonify(service=SERVICE, **FAULT)


@app.after_request
def _record(resp):
    if request.path not in ("/metrics", "/health"):
        route = request.url_rule.rule if request.url_rule else "unknown"
        telemetry.REQUESTS.labels(SERVICE, route, str(resp.status_code)).inc()
        telemetry.DURATION.labels(SERVICE, route).observe(time.perf_counter() - g.t0)
    return resp


@app.get("/health")
def health():
    return {"status": "ok", "service": SERVICE}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


def reset_pool():
    """What a restart does: every connection back in the pool."""
    global pool
    with pool_lock:
        pool = threading.BoundedSemaphore(POOL_SIZE)
        pool_state["in_use"] = 0
        POOL_IN_USE.labels(SERVICE).set(0)


# Day 5: how checkout calls payments. Switch at runtime: POST /admin/resilience {"mode": "..."}
#   naive        no timeout, no retry: a hung payments service hangs checkout's threads
#   retry_storm  1 s timeout, 3 immediate retries: every failure becomes 4 calls to a sick service
#   resilient    300 ms timeout, 2 attempts with jittered backoff, circuit breaker
RESILIENCE = {"mode": os.environ.get("RESILIENCE", "naive")}
breaker = CircuitBreaker(failure_threshold=5, reset_timeout=5.0)
CIRCUIT = Gauge("circuit_open", "1 when the payments circuit is open", ["service"])


class PaymentsUnavailable(Exception):
    pass


def call_payments(payload):
    mode = RESILIENCE["mode"]
    if mode == "naive":
        return http.post(f"{PAYMENTS_URL}/charge", json=payload)
    if mode == "retry_storm":
        for attempt in range(4):
            try:
                return http.post(f"{PAYMENTS_URL}/charge", json=payload, timeout=1.0)
            except requests.RequestException:
                continue
        raise PaymentsUnavailable("payments timed out 4 times")
    # resilient
    if not breaker.allow():
        CIRCUIT.labels(SERVICE).set(1)
        raise PaymentsUnavailable("circuit open")
    for attempt in range(2):
        try:
            r = http.post(f"{PAYMENTS_URL}/charge", json=payload, timeout=0.3)
            if r.status_code < 500:
                breaker.record_success()
                CIRCUIT.labels(SERVICE).set(0)
                return r
        except requests.RequestException:
            pass
        if attempt == 0:
            time.sleep(backoff(attempt))
    breaker.record_failure()
    CIRCUIT.labels(SERVICE).set(1 if breaker.state == "open" else 0)
    raise PaymentsUnavailable("payments failed twice")


@app.post("/admin/resilience")
def set_resilience():
    body = request.get_json(force=True, silent=True) or {}
    if body.get("mode") in ("naive", "retry_storm", "resilient"):
        RESILIENCE["mode"] = body["mode"]
        breaker.record_success()
        breaker.opens = 0
    return jsonify(mode=RESILIENCE["mode"], circuit=breaker.state, opens=breaker.opens)


@app.get("/admin/resilience")
def get_resilience():
    return jsonify(mode=RESILIENCE["mode"], circuit=breaker.state, opens=breaker.opens)


@app.get("/catalog")
def catalog():
    """Needs no other service: it should stay fast whatever payments does."""
    time.sleep(0.002)
    return jsonify(products=sorted(STOCK)[:5])


# ---------------------------------------------------------------- checkout
@app.post("/checkout")
def checkout():
    if FAULT["leak_kb"]:
        LEAK.append(bytearray(FAULT["leak_kb"] * 1024))  # a cache that never evicts
    body = request.get_json(force=True, silent=True) or {}
    sku, qty = body.get("sku", "SKU-1"), int(body.get("qty", 1))
    order_id = "ORD-" + uuid.uuid4().hex[:8]
    with tracer.start_as_current_span("validate_cart") as span:
        span.set_attribute("shop.sku", sku)
        span.set_attribute("shop.qty", qty)
        time.sleep(0.002)
    r = http.post(f"{INVENTORY_URL}/reserve", json={"sku": sku, "qty": qty, "order_id": order_id})
    if r.status_code == 409:
        log.warning("out of stock", extra={"fields": {"order_id": order_id, "sku": sku}})
        return jsonify(error="out of stock", order_id=order_id, trace_id=telemetry.current_trace_id()), 409
    if r.status_code != 200:
        log.error("inventory failed", extra={"fields": {"order_id": order_id, "status": r.status_code}})
        return jsonify(error="inventory unavailable", order_id=order_id, trace_id=telemetry.current_trace_id()), 503
    try:
        p = call_payments({"order_id": order_id, "amount": round(19.99 * qty, 2)})
    except PaymentsUnavailable as e:
        log.error("payments unavailable", extra={"fields": {"order_id": order_id, "reason": str(e)}})
        return jsonify(error="payments unavailable, try again shortly", order_id=order_id,
                       trace_id=telemetry.current_trace_id()), 503
    if p.status_code != 200:
        log.error("payment failed", extra={"fields": {"order_id": order_id, "status": p.status_code}})
        return jsonify(error="payment failed", order_id=order_id, trace_id=telemetry.current_trace_id()), 502
    log.info("order placed", extra={"fields": {"order_id": order_id, "sku": sku, "qty": qty}})
    return jsonify(order_id=order_id, status="placed", trace_id=telemetry.current_trace_id())


# ---------------------------------------------------------------- inventory
@app.post("/reserve")
def reserve():
    body = request.get_json(force=True)
    with tracer.start_as_current_span("db_pool_acquire") as span:
        t = time.perf_counter()
        my_pool = pool
        got = my_pool.acquire(timeout=1.0)
        POOL_WAIT.labels(SERVICE).observe(time.perf_counter() - t)
        span.set_attribute("db.pool.acquired", got)
    if not got:
        log.error("connection pool exhausted", extra={"fields": {"order_id": body["order_id"], "pool_size": POOL_SIZE}})
        return jsonify(error="connection pool exhausted"), 503
    with pool_lock:
        pool_state["in_use"] += 1
        POOL_IN_USE.labels(SERVICE).set(pool_state["in_use"])
    leaked = FAULT["pool_leak_rate"] and random.random() < FAULT["pool_leak_rate"]
    try:
        with tracer.start_as_current_span("stock_lookup") as span:
            span.set_attribute("shop.sku", body["sku"])
            time.sleep(random.uniform(0.003, 0.008))  # stands in for a database query
            with stock_lock:
                left = STOCK.get(body["sku"], 0)
                if left < body["qty"]:
                    return jsonify(error="out of stock"), 409
                STOCK[body["sku"]] = left - body["qty"]
    finally:
        if not leaked:  # the bug: an error path that forgets to return the connection
            my_pool.release()
            with pool_lock:
                pool_state["in_use"] = max(0, pool_state["in_use"] - 1)
                POOL_IN_USE.labels(SERVICE).set(pool_state["in_use"])
    log.info("stock reserved", extra={"fields": {"order_id": body["order_id"], "sku": body["sku"]}})
    return jsonify(reserved=True, left=STOCK[body["sku"]])


# ---------------------------------------------------------------- payments
@app.post("/charge")
def charge():
    body = request.get_json(force=True)
    with tracer.start_as_current_span("card_authorise") as span:
        span.set_attribute("shop.amount", body["amount"])
        time.sleep(random.uniform(0.010, 0.020))  # stands in for the card network
    log.info("payment captured", extra={"fields": {"order_id": body["order_id"], "amount": body["amount"]}})
    return jsonify(charged=True)
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/app"
cat > "$PROJECT_DIR/app/resilience.py" <<'SHOPSTREAM_EOF'
"""Day 5: the three tools that stop a slow dependency from taking everything down with it.

timeout   - never wait longer than the caller is willing to wait
retry     - try again a little later, with exponential backoff and full jitter, a bounded number of times
breaker   - after N consecutive failures stop calling for a while and fail fast; then let one trial through
"""
import random
import threading
import time


class CircuitOpen(Exception):
    pass


class CircuitBreaker:
    def __init__(self, failure_threshold=5, reset_timeout=5.0, clock=time.monotonic):
        self.failure_threshold, self.reset_timeout, self.clock = failure_threshold, reset_timeout, clock
        self.state, self.failures, self.opened_at = "closed", 0, 0.0
        self.trial_in_flight = False
        self.lock = threading.Lock()
        self.opens = 0

    def allow(self):
        with self.lock:
            if self.state == "open":
                if self.clock() - self.opened_at < self.reset_timeout:
                    return False
                self.state = "half_open"
                self.trial_in_flight = False
            if self.state == "half_open":
                if self.trial_in_flight:
                    return False
                self.trial_in_flight = True
            return True

    def record_success(self):
        with self.lock:
            self.state, self.failures, self.trial_in_flight = "closed", 0, False

    def record_failure(self):
        with self.lock:
            self.failures += 1
            if self.state == "half_open" or self.failures >= self.failure_threshold:
                if self.state != "open":
                    self.opens += 1
                self.state, self.opened_at, self.trial_in_flight = "open", self.clock(), False


def backoff(attempt, base=0.05, cap=0.5, rng=random):
    """Full jitter: a random wait between 0 and min(cap, base * 2^attempt)."""
    return rng.uniform(0, min(cap, base * (2 ** attempt)))
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/app"
cat > "$PROJECT_DIR/app/telemetry.py" <<'SHOPSTREAM_EOF'
"""The three signals, set up once per service.

Traces: OpenTelemetry SDK -> OTLP/HTTP -> Jaeger. Flask and requests are instrumented, so a
checkout that calls inventory and payments becomes one trace with spans from three services.
Metrics: Prometheus client, RED metrics (rate, errors, duration) on /metrics.
Logs: one JSON object per line on stdout, carrying the current trace_id and span_id.
"""
import json
import logging
import os
import sys
import time

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import Counter, Histogram

SERVICE = os.environ.get("SERVICE", "checkout")

REQUESTS = Counter("http_requests_total", "HTTP requests", ["service", "route", "status"])
DURATION = Histogram("http_request_duration_seconds", "HTTP request duration", ["service", "route"],
                     buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10))


class JsonFormatter(logging.Formatter):
    def format(self, record):
        ctx = trace.get_current_span().get_span_context()
        doc = {"ts": round(time.time(), 3), "level": record.levelname, "service": SERVICE, "msg": record.getMessage()}
        if ctx.is_valid:
            doc["trace_id"] = format(ctx.trace_id, "032x")
            doc["span_id"] = format(ctx.span_id, "016x")
        doc.update(getattr(record, "fields", {}))
        return json.dumps(doc)


def setup(app):
    provider = TracerProvider(resource=Resource.create({"service.name": SERVICE}))
    endpoint = os.environ.get("OTLP_ENDPOINT", "http://jaeger:4318/v1/traces")
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint), schedule_delay_millis=500))
    trace.set_tracer_provider(provider)
    FlaskInstrumentor().instrument_app(app, excluded_urls="health,metrics")
    RequestsInstrumentor().instrument()

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    log = logging.getLogger("shop")
    log.handlers = [handler]
    log.setLevel(logging.INFO)
    log.propagate = False
    logging.getLogger("werkzeug").setLevel(logging.WARNING)
    return log


def current_trace_id():
    ctx = trace.get_current_span().get_span_context()
    return format(ctx.trace_id, "032x") if ctx.is_valid else ""
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/grafana"
cat > "$PROJECT_DIR/grafana/Dockerfile" <<'SHOPSTREAM_EOF'
FROM grafana/grafana:11.3.0
ENV GF_AUTH_ANONYMOUS_ENABLED=true GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer GF_SECURITY_ADMIN_PASSWORD=shopstream
COPY provisioning /etc/grafana/provisioning
COPY dashboards /var/lib/grafana/dashboards
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/grafana/dashboards"
cat > "$PROJECT_DIR/grafana/dashboards/shopstream-red.json" <<'SHOPSTREAM_EOF'
{
 "uid": "shopstream-red",
 "title": "ShopStream \u2014 RED + resources",
 "schemaVersion": 39,
 "refresh": "5s",
 "time": {
  "from": "now-15m",
  "to": "now"
 },
 "panels": [
  {
   "id": 1,
   "type": "timeseries",
   "title": "Rate (requests/s)",
   "datasource": {
    "type": "prometheus",
    "uid": "prom"
   },
   "gridPos": {
    "h": 8,
    "w": 12,
    "x": 0,
    "y": 0
   },
   "fieldConfig": {
    "defaults": {
     "unit": "reqps"
    },
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "expr": "sum by (service) (rate(http_requests_total[1m]))",
     "legendFormat": "{{service}}"
    }
   ]
  },
  {
   "id": 2,
   "type": "timeseries",
   "title": "Errors (% 5xx)",
   "datasource": {
    "type": "prometheus",
    "uid": "prom"
   },
   "gridPos": {
    "h": 8,
    "w": 12,
    "x": 12,
    "y": 0
   },
   "fieldConfig": {
    "defaults": {
     "unit": "percent"
    },
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "expr": "100 * sum by (service) (rate(http_requests_total{status=~\"5..\"}[1m])) / sum by (service) (rate(http_requests_total[1m]))",
     "legendFormat": "{{service}}"
    }
   ]
  },
  {
   "id": 3,
   "type": "timeseries",
   "title": "Duration p99 (s)",
   "datasource": {
    "type": "prometheus",
    "uid": "prom"
   },
   "gridPos": {
    "h": 8,
    "w": 12,
    "x": 0,
    "y": 8
   },
   "fieldConfig": {
    "defaults": {
     "unit": "s"
    },
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "expr": "histogram_quantile(0.99, sum by (service, le) (rate(http_request_duration_seconds_bucket[1m])))",
     "legendFormat": "{{service}}"
    }
   ]
  },
  {
   "id": 4,
   "type": "timeseries",
   "title": "Duration p50 (s)",
   "datasource": {
    "type": "prometheus",
    "uid": "prom"
   },
   "gridPos": {
    "h": 8,
    "w": 12,
    "x": 12,
    "y": 8
   },
   "fieldConfig": {
    "defaults": {
     "unit": "s"
    },
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "expr": "histogram_quantile(0.5, sum by (service, le) (rate(http_request_duration_seconds_bucket[1m])))",
     "legendFormat": "{{service}}"
    }
   ]
  },
  {
   "id": 5,
   "type": "timeseries",
   "title": "DB pool in use / size (inventory)",
   "datasource": {
    "type": "prometheus",
    "uid": "prom"
   },
   "gridPos": {
    "h": 8,
    "w": 12,
    "x": 0,
    "y": 16
   },
   "fieldConfig": {
    "defaults": {
     "unit": "percentunit"
    },
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "expr": "max(db_pool_in_use{service=\"inventory\"}) / max(db_pool_size{service=\"inventory\"})",
     "legendFormat": "in use"
    }
   ]
  },
  {
   "id": 6,
   "type": "timeseries",
   "title": "Resident memory (MB)",
   "datasource": {
    "type": "prometheus",
    "uid": "prom"
   },
   "gridPos": {
    "h": 8,
    "w": 12,
    "x": 12,
    "y": 16
   },
   "fieldConfig": {
    "defaults": {
     "unit": "decmbytes"
    },
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "expr": "process_resident_memory_bytes / 1e6",
     "legendFormat": "{{instance}}"
    }
   ]
  }
 ]
}
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/grafana/provisioning/dashboards"
cat > "$PROJECT_DIR/grafana/provisioning/dashboards/shopstream.yml" <<'SHOPSTREAM_EOF'
apiVersion: 1
providers:
  - name: shopstream
    folder: ShopStream
    type: file
    options: {path: /var/lib/grafana/dashboards}
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/grafana/provisioning/datasources"
cat > "$PROJECT_DIR/grafana/provisioning/datasources/prometheus.yml" <<'SHOPSTREAM_EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prom
    type: prometheus
    url: http://prometheus:9090
    isDefault: true
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/prometheus"
cat > "$PROJECT_DIR/prometheus/Dockerfile" <<'SHOPSTREAM_EOF'
FROM prom/prometheus:v2.55.1
COPY prometheus.yml alerts.yml /etc/prometheus/
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/prometheus"
cat > "$PROJECT_DIR/prometheus/alerts.yml" <<'SHOPSTREAM_EOF'
groups:
  - name: shopstream
    rules:
      # The alert that pages for every hiccup: any 5xx in the last 30 s, no "for".
      - alert: AnyCheckoutError
        expr: sum(increase(http_requests_total{service="checkout",status=~"5.."}[30s])) > 0
        labels: {severity: page, kind: noisy}
        annotations: {summary: "A checkout returned 5xx"}
      # The alert worth waking up for: more than 5% of checkouts fail, for 30 s.
      - alert: CheckoutErrorRateHigh
        expr: |
          sum(rate(http_requests_total{service="checkout",status=~"5.."}[1m]))
            / sum(rate(http_requests_total{service="checkout"}[1m])) > 0.05
        for: 30s
        labels: {severity: page, kind: symptom}
        annotations: {summary: "More than 5% of checkouts are failing"}
      # Day 4: causes, caught before (or while) customers notice.
      - alert: InventoryPoolSaturated
        expr: max(db_pool_in_use{service="inventory"}) / max(db_pool_size{service="inventory"}) >= 0.8
        for: 10s
        labels: {severity: page, kind: cause}
        annotations: {summary: "Inventory's connection pool is at least 80% in use"}
      - alert: CheckoutMemoryLeak
        expr: deriv(process_resident_memory_bytes{instance="checkout:8000"}[1m]) > 500000
        for: 15s
        labels: {severity: ticket, kind: cause}
        annotations: {summary: "Checkout's memory grows faster than 0.5 MB/s"}
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/prometheus"
cat > "$PROJECT_DIR/prometheus/prometheus.yml" <<'SHOPSTREAM_EOF'
global:
  scrape_interval: 5s
  evaluation_interval: 5s
rule_files: ["/etc/prometheus/alerts.yml"]
scrape_configs:
  - job_name: shopstream
    static_configs:
      - targets: ["checkout:8000", "inventory:8000", "payments:8000"]
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/tests"
cat > "$PROJECT_DIR/tests/__init__.py" <<'SHOPSTREAM_EOF'

SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/tests"
cat > "$PROJECT_DIR/tests/test_analyze.py" <<'SHOPSTREAM_EOF'
import sys
import unittest

sys.path.insert(0, "tools")
import analyze


def span(sid, svc, kind, dur, parent=None):
    s = {"spanID": sid, "processID": svc, "duration": dur * 1000, "tags": [{"key": "span.kind", "value": kind}]}
    if parent:
        s["references"] = [{"spanID": parent}]
    return s


TRACE = {"processes": {"c": {"serviceName": "checkout"}, "p": {"serviceName": "payments"}},
         "spans": [span("1", "c", "server", 320), span("2", "c", "client", 310, "1"), span("3", "p", "server", 305, "2")]}


class AnalyzeTest(unittest.TestCase):
    def test_self_time_subtracts_downstream_calls(self):
        st = analyze.self_times(TRACE)
        self.assertAlmostEqual(st["checkout"], 10.0)
        self.assertAlmostEqual(st["payments"], 305.0)

    def test_slowest_service(self):
        t = analyze.p99_by_service([TRACE, TRACE])
        self.assertEqual(analyze.slowest(t), "payments")

    def test_percentile(self):
        self.assertEqual(analyze.pct(list(range(1, 101)), 99), 99)
        self.assertEqual(analyze.pct([], 99), 0.0)
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/tests"
cat > "$PROJECT_DIR/tests/test_postmortem.py" <<'SHOPSTREAM_EOF'
import sys
import unittest

sys.path.insert(0, "tools")
import incident


class PostmortemTest(unittest.TestCase):
    def test_timeline_and_numbers(self):
        ev = {"start": 1000.0, "first_error": 1004.0, "fire:InventoryPoolSaturated": 1016.0, "detected": 1016.0,
              "mitigated": 1036.0, "recovered": 1050.0}
        md, k = incident.markdown(ev, {"sent": 1000, "failed": 50},
                                  {"peak_error_ratio": 0.4, "peak_pool_in_use": 5, "trace_id": "abc", "acquire_ms": 1000})
        self.assertEqual((k["ttd"], k["ttm"], k["ttr"]), (16.0, 36.0, 50.0))
        lines = [l for l in md.splitlines() if l.startswith("| ") and "T+" in l]
        self.assertEqual([l.split("|")[2].strip() for l in lines], ["T+0 s", "T+4 s", "T+16 s", "T+36 s", "T+50 s"])
        self.assertIn("50 of 1000 checkouts failed (5.0%)", md)
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/tests"
cat > "$PROJECT_DIR/tests/test_resilience.py" <<'SHOPSTREAM_EOF'
import random
import unittest

from app.resilience import CircuitBreaker, backoff


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


class BreakerTest(unittest.TestCase):
    def test_opens_after_threshold_and_fails_fast(self):
        b = CircuitBreaker(3, 5.0, clock=Clock())
        for _ in range(3):
            self.assertTrue(b.allow())
            b.record_failure()
        self.assertEqual(b.state, "open")
        self.assertFalse(b.allow())
        self.assertEqual(b.opens, 1)

    def test_half_open_lets_one_trial_through(self):
        c = Clock()
        b = CircuitBreaker(1, 5.0, clock=c)
        b.allow(); b.record_failure()
        c.t = 5.1
        self.assertTrue(b.allow())
        self.assertFalse(b.allow())  # only one trial at a time
        b.record_success()
        self.assertEqual(b.state, "closed")

    def test_failed_trial_reopens(self):
        c = Clock()
        b = CircuitBreaker(1, 5.0, clock=c)
        b.allow(); b.record_failure()
        c.t = 6
        b.allow(); b.record_failure()
        self.assertEqual(b.state, "open")
        self.assertEqual(b.opens, 2)

    def test_backoff_is_jittered_and_capped(self):
        rng = random.Random(1)
        waits = [backoff(5, base=0.05, cap=0.5, rng=rng) for _ in range(200)]
        self.assertTrue(all(0 <= w <= 0.5 for w in waits))
        self.assertGreater(len(set(round(w, 4) for w in waits)), 150)
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/tests"
cat > "$PROJECT_DIR/tests/test_telemetry.py" <<'SHOPSTREAM_EOF'
import json
import logging
import sys
import unittest

sys.path.insert(0, "tools")
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider

from app import telemetry
import shop


class LogFormatTest(unittest.TestCase):
    def test_log_line_carries_trace_and_span_id(self):
        trace.set_tracer_provider(TracerProvider())
        tracer = trace.get_tracer("test")
        rec = logging.LogRecord("shop", logging.INFO, __file__, 1, "order placed", None, None)
        rec.fields = {"order_id": "ORD-1"}
        with tracer.start_as_current_span("x") as span:
            doc = json.loads(telemetry.JsonFormatter().format(rec))
            self.assertEqual(doc["trace_id"], format(span.get_span_context().trace_id, "032x"))
        self.assertEqual(doc["order_id"], "ORD-1")
        self.assertEqual(doc["msg"], "order placed")

    def test_log_line_without_span_has_no_trace_id(self):
        rec = logging.LogRecord("shop", logging.INFO, __file__, 1, "hello", None, None)
        self.assertNotIn("trace_id", json.loads(telemetry.JsonFormatter().format(rec)))


class MetricParseTest(unittest.TestCase):
    def test_sums_matching_series(self):
        text = ('http_requests_total{route="/checkout",service="checkout",status="200"} 3.0\n'
                'http_requests_total{route="/checkout",service="checkout",status="502"} 1.0\n'
                'http_requests_total{route="/reserve",service="inventory",status="200"} 9.0\n')
        self.assertEqual(shop.metric_value(text, "http_requests_total", service="checkout"), 4.0)
        self.assertEqual(shop.metric_value(text, "http_requests_total", service="checkout", status="200"), 3.0)


if __name__ == "__main__":
    unittest.main()
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/tools"
cat > "$PROJECT_DIR/tools/analyze.py" <<'SHOPSTREAM_EOF'
"""Find the slow service from traces alone (Jaeger query API).

For every trace we take each service's SERVER span (the request it handled) and its SELF time:
its duration minus the time spent in calls it made to other services. The service whose self-time
p99 is highest is where the time goes.
"""
import math
import time

import shop


def recent_traces(service="checkout", since_s=60, limit=500):
    now_us = int(time.time() * 1e6)
    q = f"/api/traces?service={service}&limit={limit}&start={now_us - since_s * 1_000_000}&end={now_us}"
    status, doc = shop.call("GET", shop.JAEGER + q, timeout=30)
    return doc.get("data", []) if status == 200 else []


def self_times(tr):
    """{service: self_time_ms} for one trace."""
    procs = {k: v["serviceName"] for k, v in tr["processes"].items()}
    spans = {s["spanID"]: s for s in tr["spans"]}
    kind = lambda s: next((t["value"] for t in s.get("tags", []) if t["key"] == "span.kind"), "")
    out = {}
    for s in tr["spans"]:
        if kind(s) != "server":
            continue
        svc = procs[s["processID"]]
        # time in outgoing calls = client spans whose parent chain leads to this server span
        outgoing = 0
        for c in tr["spans"]:
            if kind(c) != "client" or procs[c["processID"]] != svc:
                continue
            p = c
            while p.get("references"):
                pid = p["references"][0]["spanID"]
                if pid == s["spanID"]:
                    outgoing += c["duration"]
                    break
                p = spans.get(pid, {})
        out[svc] = out.get(svc, 0) + (s["duration"] - outgoing) / 1000
    return out


def pct(values, p):
    if not values:
        return 0.0
    v = sorted(values)
    return v[min(len(v) - 1, max(0, math.ceil(p / 100 * len(v)) - 1))]  # nearest rank


def p99_by_service(traces):
    per = {}
    for tr in traces:
        for svc, ms in self_times(tr).items():
            per.setdefault(svc, []).append(ms)
    return {svc: {"n": len(v), "p50": pct(v, 50), "p99": pct(v, 99)} for svc, v in sorted(per.items())}


def slowest(table):
    return max(table, key=lambda s: table[s]["p99"]) if table else None
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/tools"
cat > "$PROJECT_DIR/tools/checks.py" <<'SHOPSTREAM_EOF'
"""Day 6 checks: a short incident produces a complete postmortem with an ordered timeline."""
import incident
import shop

ev, impact = incident.run(leak_rate=0.3, response_s=5, warmup=15)
md, k = incident.markdown(ev, impact, incident.evidence(ev))
needed = ["start", "first_error", "detected", "mitigated", "recovered"]
missing = [n for n in needed if n not in ev]
print(f"[VERIFY] incident: detected after {k['ttd']:.0f} s, mitigated after {k['ttm']:.0f} s, recovered after {k['ttr']:.0f} s; "
      f"{impact['failed']} of {impact['sent']} checkouts failed")
if missing:
    shop.fail(f"timeline is missing: {missing}")
if not (ev["start"] < ev["first_error"] and ev["detected"] < ev["mitigated"] < ev["recovered"]):
    shop.fail("timeline events are out of order")
for section in ("## Summary", "## Impact", "## Timeline", "## Key numbers", "## Evidence", "## Root cause", "## Action items"):
    if section not in md:
        shop.fail(f"postmortem missing section {section}")
print("[VERIFY] postmortem has summary, impact, timeline, key numbers, evidence, root cause and action items")
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/tools"
cat > "$PROJECT_DIR/tools/demo.py" <<'SHOPSTREAM_EOF'
"""Day 6 demo is run by start.sh: incident.py writes POSTMORTEM.md next to start.sh."""
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/tools"
cat > "$PROJECT_DIR/tools/incident.py" <<'SHOPSTREAM_EOF'
"""Day 6: run an incident end to end and write the postmortem from telemetry.

1. Steady traffic (20 checkouts/s).
2. T0: a deploy ships a connection-pool leak in inventory (fault injection).
3. Detection: the first page from Prometheus (InventoryPoolSaturated or CheckoutErrorRateHigh).
4. Mitigation: after RESPONSE_S seconds (an on-call engineer acknowledging and diagnosing),
   roll back (fault off) and recycle the pool.
5. Recovery: checkout's error ratio over the last 30 s back under 1%.
Then the timeline, the impact and the evidence (metrics, a trace, log lines) go into POSTMORTEM.md.
Progress goes to stderr; the postmortem markdown goes to stdout.
"""
import datetime as dt
import json
import sys
import time
import urllib.parse

import shop
from traffic import Traffic


def note(msg):
    print(msg, file=sys.stderr, flush=True)


def ts(t):
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%H:%M:%S")


def run(leak_rate=0.1, response_s=20, rps=20, warmup=20):
    shop.wait_healthy()
    shop.wait_prometheus()
    shop.clear_faults()
    shop.inject("inventory", reset=True)
    shop.resilience("resilient")
    tr = Traffic(rps).start()
    note(f"warm-up {warmup} s at {rps} checkouts/s")
    time.sleep(warmup)
    end = time.time() + 120
    while shop.alerts() and time.time() < end:  # start from a quiet pager (an earlier run may still be resolving)
        time.sleep(2)
    sent0, failed0 = tr.sent, tr.failed
    ev = {}
    t0 = time.time()
    ev["start"] = t0
    shop.inject("inventory", pool_leak_rate=leak_rate)
    note(f"{ts(t0)} fault: inventory leaks {leak_rate:.0%} of its connections")
    while True:
        now = time.time()
        if "first_error" not in ev and tr.failed > failed0:
            ev["first_error"] = now
        a = shop.alerts()
        for name in ("InventoryPoolSaturated", "CheckoutErrorRateHigh"):
            if a.get(name) == "firing" and f"fire:{name}" not in ev:
                ev[f"fire:{name}"] = now
                note(f"{ts(now)} PAGE {name}")
        if "detected" not in ev and any(k.startswith("fire:") for k in ev):
            ev["detected"] = now
        if "detected" in ev and "mitigated" not in ev and now - ev["detected"] >= response_s:
            shop.inject("inventory", pool_leak_rate=0, reset=True)
            ev["mitigated"] = now
            note(f"{ts(now)} mitigation: rolled back and recycled the pool")
        if "mitigated" in ev:
            r = shop.promql('sum(rate(http_requests_total{service="checkout",status=~"5.."}[30s])) / sum(rate(http_requests_total{service="checkout"}[30s]))')
            ratio = float(r[0]["value"][1]) if r else 1.0
            if ratio < 0.01 and now - ev["mitigated"] > 5:
                ev["recovered"] = now
                note(f"{ts(now)} recovered: checkout error ratio {ratio:.2%}")
                break
        if now - t0 > 300:
            note("gave up after 300 s")
            break
        time.sleep(1)
    tr.stop()
    impact = {"sent": tr.sent - sent0, "failed": tr.failed - failed0}
    return ev, impact


def evidence(ev):
    window = int(time.time() - ev["start"]) + 30
    peak_err = shop.promql(f'max_over_time((sum(rate(http_requests_total{{service="checkout",status=~"5.."}}[30s])) / sum(rate(http_requests_total{{service="checkout"}}[30s])))[{window}s:5s])')
    peak_pool = shop.promql(f'max_over_time(max(db_pool_in_use{{service="inventory"}})[{window}s:5s])')
    tags = urllib.parse.quote(json.dumps({"http.status_code": "503"}))
    now_us = int(time.time() * 1e6)
    status, doc = shop.call("GET", f"{shop.JAEGER}/api/traces?service=inventory&tags={tags}&limit=5"
                                   f"&start={int(ev['start'] * 1e6)}&end={now_us}")
    tr = (doc.get("data") or [None])[0] if status == 200 else None
    acquire = None
    if tr:
        acquire = max((s["duration"] / 1000 for s in tr["spans"] if s["operationName"] == "db_pool_acquire"), default=None)
    return {"peak_error_ratio": float(peak_err[0]["value"][1]) if peak_err else None,
            "peak_pool_in_use": float(peak_pool[0]["value"][1]) if peak_pool else None,
            "trace_id": tr["traceID"] if tr else None, "acquire_ms": acquire}


def markdown(ev, impact, evd):
    t0 = ev["start"]
    rel = lambda k: f"T+{ev[k] - t0:.0f} s" if k in ev else "—"
    rows = [("start", "Deploy ships a connection-pool leak in inventory (fault injected)"),
            ("first_error", "First customer-facing failure: a checkout returns 503"),
            ("fire:InventoryPoolSaturated", "Page: InventoryPoolSaturated (cause alert)"),
            ("fire:CheckoutErrorRateHigh", "Page: CheckoutErrorRateHigh (symptom alert)"),
            ("mitigated", "Mitigation: rollback and pool recycle"),
            ("recovered", "Recovery: checkout error ratio under 1% (30 s window)")]
    rows = sorted([r for r in rows if r[0] in ev], key=lambda r: ev[r[0]])
    ttd = ev.get("detected", t0) - t0
    ttm = ev.get("mitigated", t0) - t0
    ttr = ev.get("recovered", t0) - t0
    pct = 100 * impact["failed"] / max(1, impact["sent"])
    out = [f"# Postmortem: checkout failures caused by an inventory connection-pool leak",
           "", f"Date: {dt.datetime.fromtimestamp(t0, dt.timezone.utc):%Y-%m-%d} (UTC). Status: resolved. Blameless.",
           "", "## Summary", "",
           f"A change in inventory stopped returning some database connections to its pool. The pool (5 connections) filled up, "
           f"inventory answered 503 \"connection pool exhausted\", and checkouts failed until the change was rolled back.",
           "", "## Impact", "",
           f"- {impact['failed']} of {impact['sent']} checkouts failed ({pct:.1f}%) between {ts(t0)} and {ts(ev.get('recovered', time.time()))} UTC.",
           f"- Peak checkout error ratio: {100 * (evd['peak_error_ratio'] or 0):.0f}% (30 s window).",
           "", "## Timeline (UTC)", "", "| Time | Offset | Event |", "|---|---|---|"]
    out += [f"| {ts(ev[k])} | {rel(k)} | {text} |" for k, text in rows]
    out += ["", "## Key numbers", "", "| Metric | Value |", "|---|---|",
            f"| Time to detect (first page) | {ttd:.0f} s |", f"| Time to mitigate | {ttm:.0f} s |",
            f"| Time to recover | {ttr:.0f} s |", f"| Failed checkouts | {impact['failed']} |"]
    out += ["", "## Evidence", "",
            f"- Metric: `db_pool_in_use` for inventory peaked at {evd['peak_pool_in_use'] or 0:.0f} of 5 connections.",
            f"- Trace `{evd['trace_id']}`: `db_pool_acquire` waited {evd['acquire_ms'] or 0:.0f} ms before giving up (1 s pool timeout)." if evd["trace_id"] else "- No failing trace found in Jaeger.",
            "- Logs: inventory logged `connection pool exhausted` with the same trace_id (`docker compose logs inventory | grep exhausted`).",
            "", "## Root cause", "",
            "An error path in inventory's reserve handler did not release its connection. Each leaked connection is gone "
            "until the process restarts, so a small leak rate exhausts a small pool within seconds under normal traffic.",
            "", "## What went well", "",
            "- The cause alert (pool saturation) and the symptom alert (error rate) both fired, and the trace pointed at the exact span.",
            "", "## What went wrong", "",
            f"- {ev.get('first_error', t0) - t0:.0f} s passed between the deploy and the first failure, but {ttd:.0f} s before anyone was paged.",
            "", "## Action items", "", "| Action | Type | Owner |", "|---|---|---|",
            "| Release connections in a `finally` block; add a test that fails when a connection leaks | fix | inventory team |",
            "| Alert on pool usage above 80% for 10 s (exists) and on pool wait p99 | detect | SRE |",
            "| Canary deploys: roll back automatically when the checkout error ratio passes 5% | prevent | platform |"]
    return "\n".join(out) + "\n", {"ttd": ttd, "ttm": ttm, "ttr": ttr, "pct": pct}


if __name__ == "__main__":
    leak = float(sys.argv[1]) if len(sys.argv) > 1 else 0.1
    response = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    ev, impact = run(leak_rate=leak, response_s=response)
    md, k = markdown(ev, impact, evidence(ev))
    note(f"TTD {k['ttd']:.0f} s, TTM {k['ttm']:.0f} s, TTR {k['ttr']:.0f} s, failed {impact['failed']}/{impact['sent']} ({k['pct']:.1f}%)")
    print(md)
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/tools"
cat > "$PROJECT_DIR/tools/load.py" <<'SHOPSTREAM_EOF'
"""A small load generator: N checkouts from C concurrent clients; returns client latencies (ms)."""
import concurrent.futures as cf
import time

import shop


def run(n=200, concurrency=8, sku_count=20):
    def one(i):
        t = time.perf_counter()
        status, _ = shop.checkout(f"SKU-{i % sku_count}", 1)
        return status, (time.perf_counter() - t) * 1000
    with cf.ThreadPoolExecutor(concurrency) as ex:
        res = list(ex.map(one, range(n)))
    return [ms for _, ms in res], sum(1 for s, _ in res if s != 200)
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/tools"
cat > "$PROJECT_DIR/tools/mix.py" <<'SHOPSTREAM_EOF'
"""Closed-loop clients that browse (/catalog) and buy (/checkout), each with a 2 s timeout like a browser."""
import concurrent.futures as cf
import random
import threading
import time
import urllib.request

import shop


def run(seconds=20, clients=24, buy_share=0.3):
    stats = {"catalog": [0, 0, []], "checkout": [0, 0, []]}  # sent, ok, latencies
    lock = threading.Lock()
    end = time.time() + seconds

    def client(k):
        rng = random.Random(k)
        while time.time() < end:
            route = "checkout" if rng.random() < buy_share else "catalog"
            t = time.perf_counter()
            try:
                if route == "catalog":
                    with urllib.request.urlopen(shop.CHECKOUT + "/catalog", timeout=2) as r:
                        ok = r.status == 200
                else:
                    ok = shop.call("POST", shop.CHECKOUT + "/checkout", {"sku": "SKU-1", "qty": 1}, timeout=2)[0] == 200
            except Exception:
                ok = False
            ms = (time.perf_counter() - t) * 1000
            with lock:
                s = stats[route]
                s[0] += 1
                s[1] += ok
                s[2].append(ms)
            if not ok:
                time.sleep(0.05)

    with cf.ThreadPoolExecutor(clients) as ex:
        list(ex.map(client, range(clients)))
    return stats
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/tools"
cat > "$PROJECT_DIR/tools/shop.py" <<'SHOPSTREAM_EOF'
"""Helpers for the demo and the checks. They run in the `tools` container on the compose network."""
import json
import sys
import time
import urllib.request

CHECKOUT = "http://checkout:8000"
SERVICES = {"checkout": "http://checkout:8000", "inventory": "http://inventory:8000", "payments": "http://payments:8000"}
JAEGER = "http://jaeger:16686"


def call(method, url, body=None, timeout=10):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def checkout(sku="SKU-1", qty=1):
    return call("POST", CHECKOUT + "/checkout", {"sku": sku, "qty": qty})


def get_trace(trace_id, timeout=20):
    """Jaeger's query API; spans arrive within a second (batch export every 500 ms)."""
    end = time.time() + timeout
    while time.time() < end:
        try:
            status, doc = call("GET", f"{JAEGER}/api/traces/{trace_id}")
            if status == 200 and doc.get("data"):
                return doc["data"][0]
        except Exception:
            pass
        time.sleep(0.5)
    return None


def spans_by_service(tr):
    procs = {k: v["serviceName"] for k, v in tr["processes"].items()}
    out = {}
    for s in tr["spans"]:
        out.setdefault(procs[s["processID"]], []).append(s)
    return out


def metric_value(text, name, **labels):
    total = 0.0
    for line in text.splitlines():
        if line.startswith(name + "{") and all(f'{k}="{v}"' in line for k, v in labels.items()):
            total += float(line.rsplit(" ", 1)[1])
    return total


def metrics(service):
    with urllib.request.urlopen(SERVICES[service] + "/metrics", timeout=5) as r:
        return r.read().decode()


def wait_healthy(timeout=90):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if all(call("GET", u + "/health", timeout=2)[0] == 200 for u in SERVICES.values()) and \
                    call("GET", JAEGER + "/api/services", timeout=2)[0] == 200:
                return True
        except Exception:
            pass
        time.sleep(1)
    return False


def fail(msg):
    print(f"[FAIL] {msg}")
    sys.exit(1)


def fault(service, delay_ms=0, error_rate=0.0):
    for attempt in range(6):  # a saturated service may need a while to answer its admin endpoint
        try:
            return call("POST", SERVICES[service] + "/admin/fault", {"delay_ms": delay_ms, "error_rate": error_rate}, timeout=15)
        except Exception:
            time.sleep(1)
    raise RuntimeError(f"{service} /admin/fault did not answer")


def clear_faults():
    for s in SERVICES:
        fault(s)


PROM = "http://prometheus:9090"
GRAFANA = "http://grafana:3000"


def promql(expr):
    import urllib.parse
    status, doc = call("GET", PROM + "/api/v1/query?query=" + urllib.parse.quote(expr))
    return doc.get("data", {}).get("result", []) if status == 200 else []


def alerts():
    """{alertname: state} for alerts that are pending or firing right now."""
    status, doc = call("GET", PROM + "/api/v1/alerts")
    return {a["labels"]["alertname"]: a["state"] for a in doc.get("data", {}).get("alerts", [])} if status == 200 else {}


def wait_prometheus(timeout=90):
    end = time.time() + timeout
    while time.time() < end:
        try:
            status, doc = call("GET", PROM + "/api/v1/targets", timeout=3)
            up = [t for t in doc["data"]["activeTargets"] if t["health"] == "up"]
            if len(up) >= 3:
                return True
        except Exception:
            pass
        time.sleep(1)
    return False


def inject(service, **fault):
    return call("POST", SERVICES[service] + "/admin/fault", fault)


def gauge(expr):
    r = promql(expr)
    return float(r[0]["value"][1]) if r else 0.0


def resilience(mode=None):
    if mode:
        return call("POST", CHECKOUT + "/admin/resilience", {"mode": mode})[1]
    return call("GET", CHECKOUT + "/admin/resilience")[1]


def payments_calls(retries=20):
    """How many /charge requests payments has finished (its own counter). Retried: a saturated
    payments service may not answer /metrics until its hung requests drain."""
    for _ in range(retries):
        try:
            return metric_value(metrics("payments"), "http_requests_total", service="payments", route="/charge")
        except Exception:
            time.sleep(1)
    raise RuntimeError("payments /metrics did not answer")
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/tools"
cat > "$PROJECT_DIR/tools/traffic.py" <<'SHOPSTREAM_EOF'
"""Steady background traffic in a thread: `rps` checkouts per second until stopped."""
import threading
import time

import shop


class Traffic:
    def __init__(self, rps=20, path_mix=None):
        self.rps, self.stop_flag = rps, threading.Event()
        self.sent = self.failed = 0
        self.lock = threading.Lock()
        self.threads = []

    def _worker(self, offset):
        i = offset
        while not self.stop_flag.is_set():
            t = time.perf_counter()
            try:
                status, _ = shop.checkout(f"SKU-{i % 20}", 1)
            except Exception:
                status = 0
            with self.lock:
                self.sent += 1
                self.failed += status != 200
            i += 4
            time.sleep(max(0.0, 4 / self.rps - (time.perf_counter() - t)))

    def start(self):
        for k in range(4):
            th = threading.Thread(target=self._worker, args=(k,), daemon=True)
            th.start()
            self.threads.append(th)
        return self

    def stop(self):
        self.stop_flag.set()
        for th in self.threads:
            th.join(timeout=10)
SHOPSTREAM_EOF

cd "$PROJECT_DIR"
say "Build images and start the stack"
docker compose down --remove-orphans >/dev/null 2>&1 || true
docker compose up -d --build 2>&1 | grep -v -E '^ *(#|=>)' | tail -15
say "Unit tests"
TESTS="$(docker compose run --rm -T -w /srv tools python -m unittest discover -s tests 2>&1)" || { echo "$TESTS" | tail -30; echo "[ERROR] unit tests failed"; exit 1; }
echo "$TESTS" | tail -3
docker compose run --rm -T tools python -c "import shop,sys; sys.exit(0 if shop.wait_healthy(120) else 1)" || { echo "[ERROR] services not healthy:"; docker compose ps; exit 1; }
echo "[INFO] stack is up: $(docker compose ps --services --status running | tr '\n' ' ')"

cat > "$ROOT/verify.sh" <<'VERIFY_EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd)/shopstream-otel"
export COMPOSE_PROJECT_NAME=shopstream-otel
OUT="$(docker compose run --rm -T tools python checks.py)" || { echo "$OUT"; exit 1; }
echo "$OUT"
echo "PASS  Lesson 6 complete. Your completion code: SHOP3-POSTMORTEM-3T9W"
VERIFY_EOF
chmod +x "$ROOT/verify.sh"

say "Verify"
bash "$ROOT/verify.sh"

say "Demo"
docker compose run --rm -T tools python incident.py 0.1 20 > "$ROOT/POSTMORTEM.md"
echo "--- POSTMORTEM.md (written next to start.sh) ---"
sed -n '/## Impact/,/## Evidence/p' "$ROOT/POSTMORTEM.md"

say "Done"
echo "Jaeger UI:  http://localhost:16686    checkout: http://localhost:8101"
echo "Prometheus: http://localhost:9090    Grafana: http://localhost:3000/d/shopstream-red (admin / shopstream)"
echo "Run bash verify.sh for your completion code, bash stop.sh when you are finished."
