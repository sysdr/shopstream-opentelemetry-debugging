# Implementation guide — Day 5: Stop a cascading failure

Time: 30–40 minutes. Needs **Docker** (Docker Desktop, or Docker Engine with the Compose plugin) and about 2 GB of free memory. Nothing else: Python and every tool run inside containers.

## Get the code

Download **start.sh** and **stop.sh** from the Scripts tab, or clone the course repo:

```bash
git clone https://github.com/sysdr/shopstream-opentelemetry-debugging.git
cd shopstream-opentelemetry-debugging/lessons/lesson-5
```

`start.sh` writes the complete project for Day 5 into `./shopstream-otel`, so you can start at any lesson.

## What start.sh does

1. Checks that Docker and Docker Compose are available and the engine is running.
2. Writes the project into `./shopstream-otel`.
3. Builds the images and starts Jaeger, Prometheus, Grafana, checkout, inventory, payments (`docker compose up -d --build`; the first build downloads about 1 GB of images).
4. Runs the 10 unit tests inside the tools container.
5. Waits for every service to be healthy, writes `verify.sh`, runs it, then runs the demo.

## What's new in the code

| File | What it does |
|---|---|
| `app/resilience.py` | CircuitBreaker (closed, open, half-open with one trial) and backoff() with full jitter |
| `app/main.py` | GET /catalog (no dependencies); POST/GET /admin/resilience with modes naive, retry_storm, resilient |
| `tools/mix.py` | 24 clients, 70% browsing and 30% buying, 2 s client timeout |
| `tests/test_resilience.py` | Breaker transitions and backoff bounds with a fake clock |

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
[VERIFY] payments hung: browse ok 100% (p99 36 ms), checkout p99 689 ms (fails fast), breaker open after 2 opening(s)
[VERIFY] payments back: 5/5 checkouts succeed after the breaker's 5 s cool-down
PASS  Lesson 5 complete. Your completion code: SHOP3-CASCADE-7H5Q
== Demo
[naive] browse ok 76%  p99 2004 ms | buy ok 0% | requests 366 | payments received 116 calls for 116 checkouts | breaker opened 0x
[retry_storm] browse ok 41%  p99 2005 ms | buy ok 0% | requests 310 | payments received 400 calls for 100 checkouts | breaker opened 0x
[resilient] browse ok 100%  p99 75 ms | buy ok 0% | requests 9434 | payments received 40 calls for 2847 checkouts | breaker opened 4x
During a 20 s payments outage (3 s hang per call), 24 clients, 30% buying:
mode          browse ok  browse p99   buy ok   total requests   payments calls / checkout
naive               76%      2004 ms       0%             366              1.00
retry_storm         41%      2005 ms       0%             310              4.00
resilient          100%        75 ms       0%            9434              0.01
```

## Try it yourself

```bash
curl -s -X POST localhost:8103/admin/fault -H 'Content-Type: application/json' -d '{"delay_ms":3000}'
```

```bash
curl -s -X POST localhost:8101/admin/resilience -H 'Content-Type: application/json' -d '{"mode":"resilient"}'
```

```bash
curl -s localhost:8101/admin/resilience
```

## Verify and get your completion code

```bash
bash verify.sh
```

Hangs payments, checks browsing stays at 100% with a low p99 and checkout fails fast with the breaker open, then restores payments and checks checkouts succeed again after the cool-down. On success it prints:

```text
PASS  Lesson 5 complete. Your completion code: SHOP3-CASCADE-7H5Q
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
