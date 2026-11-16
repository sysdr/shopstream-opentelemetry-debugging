# Day 5: Stop a cascading failure

Payments is having a bad day: every call takes 3 seconds. That should only affect people who are paying. Instead, the whole shop goes down — browsing, search, everything — because checkout's threads are all stuck waiting on payments. That is a cascading failure. Today you watch it happen, make it worse with a retry storm, and then contain it with three standard tools: a timeout, retries with jittered backoff, and a circuit breaker.

## What you build

- A new endpoint on checkout, **`GET /catalog`**, that needs no other service. In a healthy system it should never fail because payments is slow.
- **Three ways for checkout to call payments**, switchable at runtime with `POST /admin/resilience {"mode": ...}`:

| Mode | Timeout | Retries | Breaker |
|---|---|---|---|
| `naive` | none | none | no |
| `retry_storm` | 1 s | 3 immediate retries | no |
| `resilient` | 300 ms | 1 retry after a jittered backoff | opens after 5 failures, 5 s cool-down |

- **`CircuitBreaker`** in `app/resilience.py`: closed → open after 5 consecutive failures → half-open after 5 s, letting exactly one trial call through.
- **A browser-like load generator** (`tools/mix.py`): 24 clients, 70% browsing and 30% buying, each request with a 2-second timeout.

## Why one slow dependency takes everything down

Checkout runs 16 worker threads. In `naive` mode every checkout request holds a thread for the full 3 seconds payments takes. With enough buyers, all 16 threads are busy waiting, and a `/catalog` request — which needs nothing from payments — queues behind them until the client gives up. The failure has spread from payments to services that don't even call it.

The retry storm makes it worse: every failed call becomes four calls to a service that is already overloaded, so payments falls further behind and every thread waits even longer.

## The resilient call

```python
if not breaker.allow():
    raise PaymentsUnavailable("circuit open")          # fail fast: no thread held
for attempt in range(2):
    try:
        r = http.post(f"{PAYMENTS_URL}/charge", json=payload, timeout=0.3)
        if r.status_code < 500:
            breaker.record_success()
            return r
    except requests.RequestException:
        pass
    if attempt == 0:
        time.sleep(backoff(attempt))                    # random wait in [0, min(cap, base * 2^n)]
breaker.record_failure()
raise PaymentsUnavailable("payments failed twice")
```

The timeout caps how long a thread can be held. Full jitter spreads retries out so that thousands of clients don't hit the recovering service in the same instant. The breaker turns "wait 600 ms to fail" into "fail in microseconds" once failure is clearly the norm, and the half-open trial lets the system notice when payments comes back.

## What we measured

20 seconds per mode with payments hanging 3 s per call, 24 clients, 30% buying, on Docker Desktop (8 CPUs):

| Mode | Browsing succeeded | Browse p99 | Requests served in 20 s | Calls to payments per checkout |
|---|---|---|---|---|
| `naive` | 76% | 2,004 ms (client timeout) | 366 | 1.00 |
| `retry_storm` | **41%** | 2,005 ms | 310 | **4.00** |
| `resilient` | **100%** | **75 ms** | **9,434** | **0.01** |

No checkout succeeded in any mode — payments was down, and nothing can make a hung card network approve a charge. The difference is everything else. Without a timeout a quarter of browsing failed; the retry storm made it 59% while quadrupling the load on payments; the resilient client kept browsing at 100% with a 75 ms p99, served 25 times more requests, and sent payments 40 calls in 20 seconds instead of hundreds. The breaker opened 4 times, each time letting one trial through after 5 seconds.

Verify measures the same on a shorter run: browsing 100% with p99 36 ms while payments hung, checkout failing fast (p99 689 ms), and all 5 checkouts succeeding again once payments recovered and the breaker closed.

## Choosing the numbers

- **Timeout:** a little above the dependency's healthy p99 (payments takes 10–20 ms here; 300 ms is generous). Never infinite.
- **Retries:** at most one or two, only for idempotent operations (a charge needs an idempotency key), and with a retry budget at scale.
- **Breaker threshold and cool-down:** long enough to ride out a blip, short enough to notice recovery; watch `circuit_open` on the dashboard.

## Try it

```bash
curl -s -X POST localhost:8103/admin/fault -H 'Content-Type: application/json' -d '{"delay_ms":3000}'
curl -s -X POST localhost:8101/admin/resilience -H 'Content-Type: application/json' -d '{"mode":"naive"}'
curl -s -m 3 localhost:8101/catalog     # try while buying in another terminal
curl -s localhost:8101/admin/resilience
```

## Say it in an interview

**Q: What is a cascading failure?**
A: A failure in one component exhausts a shared resource (threads, connections, memory) in its callers, so components that don't depend on the failing one fail too. Here a slow payments service blocked checkout's threads and broke browsing.

**Q: Why are naive retries dangerous?**
A: They multiply load on a service that is already struggling — 4 calls per checkout here — and synchronized retries arrive in waves. Use few retries, exponential backoff with jitter, a retry budget, and only for idempotent operations.

**Q: What does a circuit breaker add on top of timeouts?**
A: Timeouts still spend the full timeout on every call. A breaker notices that calls are failing and fails fast for a while, freeing threads and giving the dependency room to recover, then probes with a single trial call.

## Recap

- One hung dependency took 24% of browsing down with no timeouts, and 59% with naive retries.
- Retries without backoff quadrupled the load on the sick service.
- Timeout + jittered retry + circuit breaker kept browsing at 100% (p99 75 ms) and cut calls to payments to 0.01 per checkout.
- Failing fast is the goal when a dependency is down; recovering automatically when it returns is the other half.

## Challenge (10 minutes)

Add a **bulkhead**: limit checkout to 4 concurrent calls to payments (a semaphore), and reject the 5th immediately. Run the `naive` mode again with the bulkhead on — what happens to browsing?

<details class="sdc-hint"><summary>Hint 1</summary>A `threading.BoundedSemaphore(4)` with `acquire(blocking=False)` around the call to payments; release in a `finally`.</details>

<details class="sdc-hint"><summary>Hint 2</summary>Even without timeouts, only 4 of the 16 threads can be stuck on payments, so 12 stay free for `/catalog`.</details>

<details class="sdc-hint"><summary>Hint 3</summary>Compare the `browse ok` column with and without the bulkhead using `tools/mix.py` from the tools container.</details>
