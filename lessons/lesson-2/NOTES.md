# Day 2: Find the slow service in 5 minutes

"Checkout is slow" is the most common page in microservices — and checkout is usually not the problem. Its latency includes every service it calls. Today you make one service slow on purpose and find it from traces alone, without reading code or guessing, in one query that takes seconds.

## What you build

- **Fault injection** on every service: `POST /admin/fault {"delay_ms": 300}` or `{"error_rate": 0.3}`. The delay is recorded as an `injected_delay` span so it is visible in the trace, like a slow database call would be.
- **`tools/analyze.py`**, which reads recent traces from Jaeger's query API and computes each service's **self time**.
- **`tools/load.py`**, which sends checkouts from 8 concurrent clients and records client-side latency.

## Total time lies, self time doesn't

In a trace, checkout's server span lasts as long as the whole request, because it waits for inventory and payments. If payments gets 300 ms slower, checkout's duration grows by 300 ms too — and a dashboard of "duration by service" points at both.

Self time removes the waiting:

```
self time = server span duration − time spent in its own outgoing calls
```

For checkout that is its own work (validating the cart, building the response). For payments, which calls nothing, self time equals its server span. The analysis walks each trace, finds every server span, subtracts its child client spans, and computes p50 and p99 per service:

```python
def p99_by_service(traces):
    per = {}
    for tr in traces:
        for svc, ms in self_times(tr).items():
            per.setdefault(svc, []).append(ms)
    return {svc: {"n": len(v), "p50": pct(v, 50), "p99": pct(v, 99)} for svc, v in per.items()}
```

Percentiles use the nearest-rank method (`ceil(p/100 × n)`), so p99 of 200 values is the 198th — a real observed request, not an interpolated one.

## What we measured

200 checkouts from 8 clients, before and after adding 300 ms to payments:

| | Client p50 | Client p99 |
|---|---|---|
| Baseline | 41 ms | 68 ms |
| Payments +300 ms | 336 ms | 353 ms |

Self time p99 by service with the fault:

| Service | Self p99 | Change |
|---|---|---|
| payments | 323 ms | **+299 ms** |
| checkout | 9 ms | unchanged (14 ms before) |
| inventory | 11 ms | unchanged (19 ms before) |

Checkout's total latency rose by about 290 ms, but its self time did not move. The analysis named payments as the slowest service in 2.1 seconds. Verify does the same with a 200 ms delay on a service it picks itself, and found inventory at 210 ms self p99.

## Reading it in Jaeger

Open http://localhost:16686, pick service `checkout`, and sort by longest. In a slow trace the long bar sits under payments' `POST /charge` server span, and inside it the `injected_delay` span is the culprit. Jaeger's trace view shows the same thing the script computes: a client span that is long only because the server span it waits for is long.

## Try it

Run these from the `shopstream-otel` folder that `start.sh` created, while the lesson is running.

```bash
docker compose -p shopstream-otel run --rm -T tools python -c "import shop; shop.fault('inventory', delay_ms=150)"
docker compose -p shopstream-otel run --rm -T tools python demo.py
```

Then clear it with `shop.clear_faults()`.

## Say it in an interview

**Q: Checkout's p99 doubled. How do you find which service caused it?**
A: Look at traces, not per-service durations. Compute each service's self time — its span minus its outgoing calls — and compare p99 against a baseline. The service whose self time grew is the cause; services that only wait on it look slow but aren't.

**Q: Why p99 and not average?**
A: Averages hide tails. A few very slow requests barely move the mean but are exactly what users complain about, and in a fan-out system one slow dependency in 100 makes many user requests slow.

**Q: What are the limits of trace-based analysis?**
A: Sampling may drop the slow traces you need, so tail-based sampling or keeping all errors and slow requests helps. Time in queues or thread pools before a span starts is invisible unless you instrument it, and clock skew between hosts can distort cross-service offsets.

## Recap

- Total duration blames every caller; self time blames the service that is actually slow.
- Fault injection with a visible span makes the slowdown reproducible.
- Measured: client p99 68 → 353 ms; payments self p99 +299 ms; checkout self time unchanged.
- The analysis is a few dozen lines over Jaeger's query API.

## Challenge (10 minutes)

Make inventory fail 20% of its requests instead of being slow, and extend `analyze.py` to report error count per service from the traces.

<details class="sdc-hint"><summary>Hint 1</summary>`shop.fault("inventory", error_rate=0.2)`.</details>

<details class="sdc-hint"><summary>Hint 2</summary>Server spans with an error carry the tag `error = true` or `otel.status_code = ERROR`; check `s["tags"]`.</details>

<details class="sdc-hint"><summary>Hint 3</summary>Count per service the same way `self_times` groups spans by `processID`.</details>
