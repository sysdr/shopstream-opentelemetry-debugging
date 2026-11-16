# Implementation guide — Day 1: One checkout, three signals

Time: 20–30 minutes. Needs **Docker** (Docker Desktop, or Docker Engine with the Compose plugin) and about 2 GB of free memory. Nothing else: Python and every tool run inside containers.

## Get the code

Download **start.sh** and **stop.sh** from the Scripts tab, or clone the course repo:

```bash
git clone https://github.com/sysdr/shopstream-opentelemetry-debugging.git
cd shopstream-opentelemetry-debugging/lessons/lesson-1
```

`start.sh` writes the complete project for Day 1 into `./shopstream-otel`, so you can start at any lesson.

## What start.sh does

1. Checks that Docker and Docker Compose are available and the engine is running.
2. Writes the project into `./shopstream-otel`.
3. Builds the images and starts Jaeger, checkout, inventory, payments (`docker compose up -d --build`; the first build downloads about 1 GB of images).
4. Runs the 3 unit tests inside the tools container.
5. Waits for every service to be healthy, writes `verify.sh`, runs it, then runs the demo.

## What's new in the code

| File | What it does |
|---|---|
| `Dockerfile, requirements.txt` | One Python 3.12 image (Flask, gunicorn, OpenTelemetry 1.29, prometheus-client) for all three services |
| `compose.yaml` | Jaeger 1.62 plus checkout (8101), inventory (8102) and payments (8103); a `tools` container for the demo and checks |
| `app/telemetry.py` | TracerProvider with OTLP/HTTP export, Flask and requests instrumentation, RED metrics, JSON logs with trace_id |
| `app/main.py` | POST /checkout → POST /reserve (inventory) → POST /charge (payments); /health, /metrics |
| `tools/shop.py` | Helpers: place a checkout, fetch a trace from Jaeger, read metrics |
| `tools/demo.py, tools/checks.py` | The measured demo and the checks verify.sh runs |

## Run it

```bash
bash start.sh
```

When it finishes, open:

| What | Where |
|---|---|
| Jaeger | http://localhost:16686 |
| checkout | http://localhost:8101 |

## Expected output

Timings depend on your machine; the shape should look like this (Docker Desktop, 8 CPUs):

```text
== Verify
[VERIFY] trace dbc85669d82b489501095edfeaeea6bb: 8 spans from ['checkout', 'inventory', 'payments']
[VERIFY] metrics: http_requests_total counts the checkout
[VERIFY] logs: trace dbc85669d82b489501095edfeaeea6bb appears in the logs of 3 services
PASS  Lesson 1 complete. Your completion code: SHOP3-SIGNALS-4V7N
== Demo
POST /checkout -> 200 ORD-a9f77dee  trace_id=293e3ef4019404dfe623caff7e2da6ea
1) TRACE  8 spans, 3 services, end to end 32.9 ms
   checkout   POST /checkout                     start +   0.0 ms  took   32.9 ms
   checkout   validate_cart                      start +   0.7 ms  took    2.1 ms
   checkout   POST                               start +   3.1 ms  took    8.0 ms
   inventory  POST /reserve                      start +   3.9 ms  took    6.7 ms
   inventory  stock_lookup                       start +   4.6 ms  took    5.4 ms
   checkout   POST                               start +  11.8 ms  took   20.4 ms
   payments   POST /charge                       start +  12.8 ms  took   18.5 ms
   payments   card_authorise                     start +  13.4 ms  took   16.9 ms
2) METRICS  (RED: rate, errors, duration) after 100 more checkouts
   checkout   http_requests_total=102
   inventory  http_requests_total=102
   payments   http_requests_total=102
   client view: p50 38.0 ms  p99 46.7 ms
3) LOGS  the same trace_id in every service's log line (docker compose logs, below)
   grep 293e3ef4019404dfe623caff7e2da6ea
```

## Try it yourself

```bash
curl -s -X POST localhost:8101/checkout -H 'Content-Type: application/json' -d '{"sku":"SKU-3","qty":1}'
```

```bash
curl -s localhost:8101/metrics | grep http_requests_total
```

```bash
cd shopstream-otel && docker compose -p shopstream-otel logs checkout inventory payments | grep <trace_id>
```

## Verify and get your completion code

```bash
bash verify.sh
```

Places a checkout, fetches its trace from Jaeger and checks it has spans from all three services, checks each service's request counter and that the trace ID appears in the logs of at least three services. On success it prints:

```text
PASS  Lesson 1 complete. Your completion code: SHOP3-SIGNALS-4V7N
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
