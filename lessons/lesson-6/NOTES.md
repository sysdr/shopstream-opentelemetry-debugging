# Day 6: Write the postmortem

Every incident ends with the same question: what happened, when, and what do we change? Teams that answer it from memory get vague timelines and blame. Teams that answer it from telemetry get exact times, real numbers and action items that stick. Today you run a full incident against ShopStream — a bad deploy, a page, an on-call response, a rollback, recovery — and generate the postmortem from the traces, metrics and logs you built in Days 1–5.

## What you build

`tools/incident.py`, which plays every role in the incident and keeps the clock:

1. **Traffic:** 20 checkouts per second, as in production.
2. **The bad deploy (T+0):** inventory starts leaking 10% of its database connections (the Day 4 fault).
3. **Detection:** the script polls Prometheus' alerts; the first page marks *detected*.
4. **Response:** 20 seconds for a human to acknowledge and diagnose, then *mitigation* — roll back the change and recycle the pool.
5. **Recovery:** checkout's error ratio over 30 s back under 1%.
6. **Evidence:** peak error ratio and pool usage from Prometheus, one failing trace from Jaeger with its `db_pool_acquire` span, and the matching log line.

It then writes **POSTMORTEM.md** next to `start.sh`: summary, impact, a timeline with UTC times and T+ offsets, key numbers, evidence, root cause, what went well and badly, and action items. The format is blameless: it describes what the system and the process did, not who made a mistake.

## The three numbers that matter

- **Time to detect (TTD):** from the start of impact to the first page. Shortened by better alerts.
- **Time to mitigate (TTM):** from the start to the moment the bleeding stops. Shortened by runbooks, rollbacks and feature flags.
- **Time to recover (TTR):** until the system is healthy again by its own SLO. Includes everything above plus drain time.

Measure all three from the same clock as your telemetry, or the timeline will argue with your graphs.

## What we measured

One run on Docker Desktop (the generated POSTMORTEM.md, abridged):

| Time (UTC) | Offset | Event |
|---|---|---|
| 03:21:41 | T+0 s | Deploy ships a connection-pool leak in inventory |
| 03:21:44 | T+3 s | First customer-facing failure: a checkout returns 503 |
| 03:22:01 | T+20 s | Page: InventoryPoolSaturated (cause alert) |
| 03:22:21 | T+40 s | Mitigation: rollback and pool recycle |
| 03:22:36 | T+55 s | Page: CheckoutErrorRateHigh (symptom alert) |
| 03:22:46 | T+65 s | Recovery: checkout error ratio under 1% |

| Metric | Value |
|---|---|
| Time to detect | 20 s |
| Time to mitigate | 40 s |
| Time to recover | 65 s |
| Failed checkouts | 152 of 688 (22.1%) |

Two lessons are already visible in the timeline. Customers felt the problem 3 seconds after the deploy, but the first page came 17 seconds later — that gap is the alert's `for: 10s` plus scrape and evaluation intervals, a trade you chose on Day 3. And the symptom alert (`CheckoutErrorRateHigh`) fired *after* the mitigation: its 30-second window and 30-second `for` meant it described an incident that was already being fixed. The cause alert on pool saturation is what made a 20-second detection possible.

The verify run used a faster scenario (30% leak, 5-second response) and produced a complete postmortem with detection after 19 s, mitigation after 24 s and recovery after 50 s.

## Writing action items that get done

Each action item in the generated file names a type and an owner:

| Action | Type |
|---|---|
| Release connections in a `finally` block; add a test that fails when a connection leaks | fix |
| Alert on pool usage above 80% for 10 s, and on pool wait p99 | detect |
| Canary deploys that roll back when the checkout error ratio passes 5% | prevent |

"Be more careful" is not an action item. A test, an alert, a guardrail or an automatic rollback is.

## Try it

Run these from the `shopstream-otel` folder that `start.sh` created, while the lesson is running.

```bash
docker compose -p shopstream-otel run --rm -T tools python incident.py 0.2 10 > MY_POSTMORTEM.md
less MY_POSTMORTEM.md
```

The two arguments are the leak rate and the on-call response time in seconds. Try 0.05 and 60: how many checkouts does a slow response cost?

## Say it in an interview

**Q: What goes into a good postmortem?**
A: A summary, measured impact, a timestamped timeline from detection through recovery, the root cause and contributing factors, what went well and badly, and owned, specific action items — written blamelessly.

**Q: What is the difference between time to detect, mitigate and recover?**
A: Detect is impact start to first alert; mitigate is to when impact stops growing (rollback, failover); recover is to when the service is back within its SLO. Each is improved by different investments: alerting, runbooks and automation, and capacity or drain time.

**Q: Why alert on causes as well as symptoms?**
A: Symptom alerts (error rate, latency) are what users feel and should page, but they lag. A cause alert such as pool saturation can fire earlier and points at the fix. Here the cause alert fired 35 seconds before the symptom alert.

## Recap

- The postmortem is generated from the same telemetry you use during the incident: no reconstructing from memory.
- Measured: detect 20 s, mitigate 40 s, recover 65 s; 152 of 688 checkouts failed.
- The cause alert beat the symptom alert by 35 s; the symptom alert fired after mitigation.
- Good action items are specific, owned and change the system.

## Challenge (10 minutes)

Make the mitigation automatic: when `InventoryPoolSaturated` fires, `incident.py` should recycle the pool immediately instead of waiting for a human. How much do TTM and the number of failed checkouts drop?

<details class="sdc-hint"><summary>Hint 1</summary>Run `incident.py 0.1 0`: a response time of 0 seconds models automatic remediation.</details>

<details class="sdc-hint"><summary>Hint 2</summary>Compare "Failed checkouts" and "Time to mitigate" in the two generated files.</details>

<details class="sdc-hint"><summary>Hint 3</summary>Automatic restarts hide leaks; add an action item to alert when the remediation runs more than twice an hour.</details>
