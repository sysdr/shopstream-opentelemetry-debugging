#!/usr/bin/env bash
# ShopStream observability — Day 1: One checkout, three signals
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
CMD ["gunicorn", "-b", "0.0.0.0:8000", "-w", "1", "--threads", "16", "--timeout", "120", "app.main:app"]
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/."
cat > "$PROJECT_DIR/compose.yaml" <<'SHOPSTREAM_EOF'
# ShopStream: three Python services + Jaeger. No bind mounts: everything is built into the image.
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
import os
import random
import threading
import time
import uuid

import requests
from flask import Flask, Response, g, jsonify, request
from opentelemetry import trace
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from app import telemetry

SERVICE = telemetry.SERVICE
INVENTORY_URL = os.environ.get("INVENTORY_URL", "http://inventory:8000")
PAYMENTS_URL = os.environ.get("PAYMENTS_URL", "http://payments:8000")

app = Flask(__name__)
log = telemetry.setup(app)
tracer = trace.get_tracer("shopstream")
http = requests.Session()

STOCK = {f"SKU-{i}": 1000 for i in range(20)}
stock_lock = threading.Lock()


@app.before_request
def _start():
    g.t0 = time.perf_counter()


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


# ---------------------------------------------------------------- checkout
@app.post("/checkout")
def checkout():
    body = request.get_json(force=True, silent=True) or {}
    sku, qty = body.get("sku", "SKU-1"), int(body.get("qty", 1))
    order_id = "ORD-" + uuid.uuid4().hex[:8]
    with tracer.start_as_current_span("validate_cart") as span:
        span.set_attribute("shop.sku", sku)
        span.set_attribute("shop.qty", qty)
        time.sleep(0.002)
    r = http.post(f"{INVENTORY_URL}/reserve", json={"sku": sku, "qty": qty, "order_id": order_id})
    if r.status_code != 200:
        log.warning("reserve failed", extra={"fields": {"order_id": order_id, "status": r.status_code}})
        return jsonify(error="out of stock", order_id=order_id, trace_id=telemetry.current_trace_id()), 409
    p = http.post(f"{PAYMENTS_URL}/charge", json={"order_id": order_id, "amount": round(19.99 * qty, 2)})
    if p.status_code != 200:
        log.error("payment failed", extra={"fields": {"order_id": order_id, "status": p.status_code}})
        return jsonify(error="payment failed", order_id=order_id, trace_id=telemetry.current_trace_id()), 502
    log.info("order placed", extra={"fields": {"order_id": order_id, "sku": sku, "qty": qty}})
    return jsonify(order_id=order_id, status="placed", trace_id=telemetry.current_trace_id())


# ---------------------------------------------------------------- inventory
@app.post("/reserve")
def reserve():
    body = request.get_json(force=True)
    with tracer.start_as_current_span("stock_lookup") as span:
        span.set_attribute("shop.sku", body["sku"])
        time.sleep(random.uniform(0.003, 0.008))  # stands in for a database query
        with stock_lock:
            left = STOCK.get(body["sku"], 0)
            if left < body["qty"]:
                return jsonify(error="out of stock"), 409
            STOCK[body["sku"]] = left - body["qty"]
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
mkdir -p "$PROJECT_DIR/tests"
cat > "$PROJECT_DIR/tests/__init__.py" <<'SHOPSTREAM_EOF'

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
cat > "$PROJECT_DIR/tools/checks.py" <<'SHOPSTREAM_EOF'
"""Day 1 checks used by verify.sh: one checkout must produce all three signals."""
import shop

if not shop.wait_healthy():
    shop.fail("services or Jaeger not healthy")
status, body = shop.checkout("SKU-3", 2)
if status != 200 or not body.get("trace_id"):
    shop.fail(f"checkout failed: {status} {body}")
tr = shop.get_trace(body["trace_id"])
if not tr:
    shop.fail("the checkout's trace never reached Jaeger")
by = shop.spans_by_service(tr)
print(f"[VERIFY] trace {body['trace_id']}: {len(tr['spans'])} spans from {sorted(by)}")
if set(by) != {"checkout", "inventory", "payments"}:
    shop.fail("the trace must contain spans from checkout, inventory and payments")
m = shop.metrics("checkout")
if shop.metric_value(m, "http_requests_total", service="checkout", route="/checkout", status="200") < 1:
    shop.fail("checkout's /metrics does not count the request")
print("[VERIFY] metrics: http_requests_total counts the checkout")
SHOPSTREAM_EOF
mkdir -p "$PROJECT_DIR/tools"
cat > "$PROJECT_DIR/tools/demo.py" <<'SHOPSTREAM_EOF'
"""Day 1 demo: one checkout, three signals."""
import statistics
import time

import shop

shop.wait_healthy()
status, body = shop.checkout("SKU-7", 1)
print(f"POST /checkout -> {status} {body['order_id']}  trace_id={body['trace_id']}")
tr = shop.get_trace(body["trace_id"])
by = shop.spans_by_service(tr)
root = min(tr["spans"], key=lambda s: s["startTime"])
print(f"\n1) TRACE  {len(tr['spans'])} spans, {len(by)} services, end to end {root['duration'] / 1000:.1f} ms")
t0 = root["startTime"]
for s in sorted(tr["spans"], key=lambda s: s["startTime"]):
    svc = tr["processes"][s["processID"]]["serviceName"]
    off = (s["startTime"] - t0) / 1000
    print(f"   {svc:10} {s['operationName'][:34]:34} start +{off:6.1f} ms  took {s['duration'] / 1000:6.1f} ms")

print("\n2) METRICS  (RED: rate, errors, duration) after 100 more checkouts")
lat = []
for i in range(100):
    t = time.perf_counter(); shop.checkout(f"SKU-{i % 20}", 1); lat.append((time.perf_counter() - t) * 1000)
for svc in ("checkout", "inventory", "payments"):
    m = shop.metrics(svc)
    n = shop.metric_value(m, "http_requests_total", service=svc)
    print(f"   {svc:10} http_requests_total={n:.0f}")
lat.sort()
print(f"   client view: p50 {statistics.median(lat):.1f} ms  p99 {lat[98]:.1f} ms")

print("\n3) LOGS  the same trace_id in every service's log line (docker compose logs, below)")
print(f"   grep {body['trace_id']}")
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
TID="$(echo "$OUT" | sed -n 's/.*\[VERIFY\] trace \([0-9a-f]\{32\}\).*/\1/p')"
N="$(docker compose logs --no-color checkout inventory payments 2>/dev/null | grep "$TID" | sed 's/ *|.*//' | sort -u | wc -l)"
echo "[VERIFY] logs: trace $TID appears in the logs of $N services"
[ "$N" -ge 3 ] || { echo "[FAIL] every service should log the checkout's trace_id"; exit 1; }
echo "PASS  Lesson 1 complete. Your completion code: SHOP3-SIGNALS-4V7N"
VERIFY_EOF
chmod +x "$ROOT/verify.sh"

say "Verify"
bash "$ROOT/verify.sh"

say "Demo"
DEMO="$(docker compose run --rm -T tools python demo.py)"; echo "$DEMO"
TID="$(echo "$DEMO" | sed -n 's/.*grep \([0-9a-f]\{32\}\).*/\1/p' | head -1)"
docker compose logs --no-color --no-log-prefix checkout inventory payments 2>/dev/null | grep "$TID" | cut -c1-170 || true

say "Done"
echo "Jaeger UI:  http://localhost:16686    checkout: http://localhost:8101"
echo "Run bash verify.sh for your completion code, bash stop.sh when you are finished."
