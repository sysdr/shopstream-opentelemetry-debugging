# Day 4: Catch a memory leak and an exhausted pool

Some failures don't arrive as a spike. A connection pool loses one connection every few hundred requests; memory grows a megabyte a second. Everything looks fine until, suddenly, nothing works. Today you inject both of these slow-burning faults into ShopStream and catch them with *cause* alerts — metrics that warn you before, or right as, customers start to fail.

## What you build

- **A database connection pool in inventory**: 5 connections (a `BoundedSemaphore` standing in for real ones). Each `/reserve` acquires a connection with a 1-second timeout; if none is free, inventory returns **503 "connection pool exhausted"**. The wait is a span, `db_pool_acquire`, so it shows up in traces.
- **Pool metrics**: `db_pool_in_use`, `db_pool_size` and the histogram `db_pool_wait_seconds`.
- **Two new faults** via `POST /admin/fault`:
  - `pool_leak_rate` — the fraction of inventory requests that never return their connection (a missing `finally`).
  - `leak_kb` — kilobytes checkout keeps forever per request (a cache with no eviction).
- **Two cause alerts**:

```yaml
- alert: InventoryPoolSaturated
  expr: max(db_pool_in_use{service="inventory"}) / max(db_pool_size{service="inventory"}) >= 0.8
  for: 10s
- alert: CheckoutMemoryLeak
  expr: deriv(process_resident_memory_bytes{instance="checkout:8000"}[1m]) > 500000
  for: 15s
```

## The leak in code

```python
got = my_pool.acquire(timeout=1.0)
if not got:
    log.error("connection pool exhausted", ...)
    return jsonify(error="connection pool exhausted"), 503
leaked = random.random() < FAULT["pool_leak_rate"]
try:
    ...                       # the database query
finally:
    if not leaked:            # the injected bug: some paths never give the connection back
        my_pool.release()
```

In real code this is a `return` or an exception between `acquire` and `release`. The fix is always the same: release in a `finally` block, or use a context manager.

## What we measured

Steady traffic at 20 checkouts per second, pool of 5:

**Pool leak, 5% of requests:**

- First failed checkout after **4 s** — 5 connections at 5% leak rate is about 100 requests, and the leak plus the 1 s acquire timeout turns into failures quickly.
- `InventoryPoolSaturated` fired after **19 s**; by then 64 of 113 checkouts had failed and the pool was 100% in use.

**Memory leak, 64 KB per request (about 1.3 MB/s):**

- Checkout's resident memory grew from **51 MB to 116 MB**.
- `CheckoutMemoryLeak` fired after **50 s**. None of 1,004 checkouts failed — a memory leak is invisible to customers until the process is killed for running out of memory, which is exactly why you alert on the trend.

Verify saw the same pattern in a shorter run: five checkouts succeed, the next three return 503 with all 5 connections in use, and memory climbs from 51 to 73 MB.

## Symptoms versus causes

Day 3's rule was to page on symptoms. Cause alerts earn a place when they are:

- **Predictive:** pool saturation precedes errors; memory growth precedes an out-of-memory kill.
- **Actionable:** they point straight at the fix — restart, roll back, raise the limit.
- **Rare when healthy:** a healthy pool is rarely above 80% for 10 s.

The memory alert is labelled `severity: ticket`, not `page`: nobody needs to get up at 3 a.m. for memory that will last until morning, but someone must look at it during the day.

## Finding it in a trace

Open a failed checkout in Jaeger: inventory's server span contains a `db_pool_acquire` span that lasted 1 second with `db.pool.acquired = false`. The inventory log line with the same trace ID says "connection pool exhausted". Three signals, one story.

## Try it

Run these from the `shopstream-otel` folder that `start.sh` created, while the lesson is running.

```bash
docker compose -p shopstream-otel run --rm -T tools python -c "import shop; shop.inject('inventory', pool_leak_rate=0.1)"
```

Watch the pool panel in Grafana, then mitigate with `shop.inject('inventory', reset=True)` — what a restart does.

## Say it in an interview

**Q: How would you detect a connection-pool leak before it causes an outage?**
A: Export pool usage and wait time as metrics and alert when usage stays above about 80% or wait p99 rises. Then find the leak with traces of slow acquires and code review for paths that skip `release` — usually an early return or exception without `finally`.

**Q: How do you alert on a memory leak?**
A: On the rate of growth (`deriv` or a linear prediction such as `predict_linear` reaching the limit), not on a fixed threshold, since a large but stable heap is normal. Make it a ticket unless it predicts an out-of-memory kill within hours.

**Q: When is a cause-based alert justified?**
A: When it reliably predicts user impact, fires earlier than the symptom alert, and comes with a clear action.

## Recap

- A 5% connection leak broke checkouts after 4 s; the pool alert fired after 19 s at 100% usage.
- A 64 KB-per-request memory leak grew checkout from 51 to 116 MB with zero failed requests; the trend alert fired after 50 s.
- Cause alerts must be predictive, actionable and quiet when healthy.
- Traces and logs confirm the cause: `db_pool_acquire` timing out, "connection pool exhausted".

## Challenge (10 minutes)

Add an alert on pool *wait time*: fire when p99 of `db_pool_wait_seconds` is above 200 ms for 10 s. Does it fire before or after `InventoryPoolSaturated`?

<details class="sdc-hint"><summary>Hint 1</summary>`histogram_quantile(0.99, sum by (le) (rate(db_pool_wait_seconds_bucket{service="inventory"}[30s]))) > 0.2`.</details>

<details class="sdc-hint"><summary>Hint 2</summary>Add it to `prometheus/alerts.yml` and rebuild Prometheus with `docker compose -p shopstream-otel up -d --build prometheus`.</details>

<details class="sdc-hint"><summary>Hint 3</summary>Run the leak at 5% and poll `shop.alerts()` once a second, recording when each alert first fires.</details>
