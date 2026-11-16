# Implementation guide — Day 4: Catch a memory leak and an exhausted pool

Time: 30–40 minutes. Needs **Docker** (Docker Desktop, or Docker Engine with the Compose plugin) and about 2 GB of free memory. Nothing else: Python and every tool run inside containers.

## Get the code

Download **start.sh** and **stop.sh** from the Scripts tab, or clone the course repo:

```bash
git clone https://github.com/sysdr/shopstream-opentelemetry-debugging.git
cd shopstream-opentelemetry-debugging/lessons/lesson-4
```

`start.sh` writes the complete project for Day 4 into `./shopstream-otel`, so you can start at any lesson.

## What start.sh does

1. Checks that Docker and Docker Compose are available and the engine is running.
2. Writes the project into `./shopstream-otel`.
3. Builds the images and starts Jaeger, Prometheus, Grafana, checkout, inventory, payments (`docker compose up -d --build`; the first build downloads about 1 GB of images).
4. Runs the 6 unit tests inside the tools container.
5. Waits for every service to be healthy, writes `verify.sh`, runs it, then runs the demo.

## What's new in the code

| File | What it does |
|---|---|
| `app/main.py` | Inventory connection pool (5, 1 s acquire timeout, `db_pool_acquire` span); faults `pool_leak_rate`, `leak_kb`, `reset` |
| `app/main.py (metrics)` | db_pool_in_use, db_pool_size, db_pool_wait_seconds |
| `prometheus/alerts.yml` | InventoryPoolSaturated (≥80% for 10 s) and CheckoutMemoryLeak (RSS growing >0.5 MB/s for 15 s) |
| `grafana/dashboards` | Pool usage and resident memory panels |
| `Dockerfile` | MALLOC_MMAP_THRESHOLD_ so memory freed by a reset goes back to the OS, like a restart |

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
[VERIFY] pool leak: statuses [200, 200, 200, 200, 200, 503, 503, 503], db_pool_in_use=5/5
[VERIFY] memory leak: checkout RSS 51 MB -> 73 MB after 40 requests x 512 KB
PASS  Lesson 4 complete. Your completion code: SHOP3-LEAK-2X8M
== Demo
Steady traffic: 20 checkouts/s (warm-up 20 s)
1) Connection-pool leak: 5% of inventory requests never return their connection (pool size 5)
   pool usage now 100%
   first failed checkout after 4.0 s
   InventoryPoolSaturated FIRING after 19.0 s (64 of 113 checkouts failed meanwhile)
   mitigation: leak switched off and pool reset (what a rollback + restart does)
2) Memory leak: checkout keeps 64 KB per request forever (20 req/s = 1.3 MB/s)
   resident memory 51 MB -> 116 MB
   CheckoutMemoryLeak FIRING after 50.0 s; 0 of 1004 checkouts failed meanwhile (a leak is silent for customers until the process runs out of memory)
```

## Try it yourself

```bash
curl -s -X POST localhost:8102/admin/fault -H 'Content-Type: application/json' -d '{"pool_leak_rate":0.1}'
```

```bash
curl -s localhost:8102/metrics | grep db_pool
```

```bash
curl -s -X POST localhost:8102/admin/fault -H 'Content-Type: application/json' -d '{"reset":true}'
```

## Verify and get your completion code

```bash
bash verify.sh
```

Leaks every connection, checks the first 5 checkouts succeed and the next fail with 503 while the pool shows 5 of 5 in use, then leaks memory and checks checkout's resident memory grows. On success it prints:

```text
PASS  Lesson 4 complete. Your completion code: SHOP3-LEAK-2X8M
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
