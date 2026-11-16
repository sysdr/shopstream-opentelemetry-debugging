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
