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
