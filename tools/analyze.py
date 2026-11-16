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
