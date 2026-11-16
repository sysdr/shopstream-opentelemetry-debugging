# Implementation guide — Day 6: Write the postmortem

Time: 30–40 minutes. Needs **Docker** (Docker Desktop, or Docker Engine with the Compose plugin) and about 2 GB of free memory. Nothing else: Python and every tool run inside containers.

## Get the code

Download **start.sh** and **stop.sh** from the Scripts tab, or clone the course repo:

```bash
git clone https://github.com/sysdr/shopstream-opentelemetry-debugging.git
cd shopstream-opentelemetry-debugging/lessons/lesson-6
```

`start.sh` writes the complete project for Day 6 into `./shopstream-otel`, so you can start at any lesson.

## What start.sh does

1. Checks that Docker and Docker Compose are available and the engine is running.
2. Writes the project into `./shopstream-otel`.
3. Builds the images and starts Jaeger, Prometheus, Grafana, checkout, inventory, payments (`docker compose up -d --build`; the first build downloads about 1 GB of images).
4. Runs the 11 unit tests inside the tools container.
5. Waits for every service to be healthy, writes `verify.sh`, runs it, then runs the demo.

## What's new in the code

| File | What it does |
|---|---|
| `tools/incident.py` | Runs the incident (traffic, bad deploy, page, response, rollback, recovery) and prints POSTMORTEM.md |
| `tools/incident.py (evidence)` | Peak error ratio and pool usage from Prometheus, a failing trace from Jaeger, the matching log line |
| `tests/test_postmortem.py` | The postmortem has every section and correct TTD/TTM/TTR |

## Run it

```bash
bash start.sh
```

When it finishes, open:

| What | Where |
|---|---|
| Jaeger | http://localhost:16686 |
| checkout | http://localhost:8101 |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3000/d/shopstream-red (admin / shopstream) |

## Expected output

Timings depend on your machine; the shape should look like this (Docker Desktop, 8 CPUs):

```text
== Verify
warm-up 15 s at 20 checkouts/s
03:20:22 fault: inventory leaks 30% of its connections
03:20:41 PAGE InventoryPoolSaturated
03:20:46 mitigation: rolled back and recycled the pool
03:21:11 PAGE CheckoutErrorRateHigh
03:21:12 recovered: checkout error ratio 0.82%
[VERIFY] incident: detected after 19 s, mitigated after 24 s, recovered after 50 s; 96 of 616 checkouts failed
[VERIFY] postmortem has summary, impact, timeline, key numbers, evidence, root cause and action items
PASS  Lesson 6 complete. Your completion code: SHOP3-POSTMORTEM-3T9W
== Demo
warm-up 20 s at 20 checkouts/s
03:21:41 fault: inventory leaks 10% of its connections
03:22:01 PAGE InventoryPoolSaturated
03:22:21 mitigation: rolled back and recycled the pool
03:22:36 PAGE CheckoutErrorRateHigh
03:22:46 recovered: checkout error ratio 0.81%
TTD 20 s, TTM 40 s, TTR 65 s, failed 152/688 (22.1%)
--- POSTMORTEM.md (written next to start.sh) ---
- 152 of 688 checkouts failed (22.1%) between 03:21:41 and 03:22:46 UTC.
- Peak checkout error ratio: 100% (30 s window).
| Time | Offset | Event |
|---|---|---|
| 03:21:41 | T+0 s | Deploy ships a connection-pool leak in inventory (fault injected) |
| 03:21:44 | T+3 s | First customer-facing failure: a checkout returns 503 |
| 03:22:01 | T+20 s | Page: InventoryPoolSaturated (cause alert) |
| 03:22:21 | T+40 s | Mitigation: rollback and pool recycle |
| 03:22:36 | T+55 s | Page: CheckoutErrorRateHigh (symptom alert) |
| 03:22:46 | T+65 s | Recovery: checkout error ratio under 1% (30 s window) |
| Metric | Value |
|---|---|
| Time to detect (first page) | 20 s |
| Time to mitigate | 40 s |
| Time to recover | 65 s |
| Failed checkouts | 152 |
```

## Try it yourself

```bash
cd shopstream-otel && docker compose -p shopstream-otel run --rm -T tools python incident.py 0.2 10 > ../MY_POSTMORTEM.md
```

```bash
less MY_POSTMORTEM.md   # or POSTMORTEM.md from start.sh
```

## Verify and get your completion code

```bash
bash verify.sh
```

Runs a short incident (30% leak, 5 s response) and checks it was detected, mitigated and recovered, and that the postmortem has every section. On success it prints:

```text
PASS  Lesson 6 complete. Your completion code: SHOP3-POSTMORTEM-3T9W
```

Enter the code below the lesson to mark it complete.

## Stop

```bash
bash stop.sh
```

Stops and removes every container of the lesson (`docker compose down`). Images stay cached, so the next lesson starts faster.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Cannot connect to the Docker daemon` | Start Docker Desktop (or `sudo systemctl start docker`) and run start.sh again |
| `port is already allocated` | Another lesson or app uses 8101–8103, 16686, 9090 or 3000: `bash stop.sh`, or stop the other app |
| `services not healthy` | `cd shopstream-otel && docker compose -p shopstream-otel logs checkout` shows the error |
| Unit tests fail | The output above the error names the failing test |
| A trace is not in Jaeger yet | Spans are exported in batches every 0.5 s; wait a second and search again |
| Slow first run | The first build downloads base images; later lessons reuse them |
