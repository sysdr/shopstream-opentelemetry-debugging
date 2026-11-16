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
