# Implementation guide — Day 3: Dashboards and one alert worth waking for

Time: 30–40 minutes. Needs **Docker** (Docker Desktop, or Docker Engine with the Compose plugin) and about 2 GB of free memory. Nothing else: Python and every tool run inside containers.

## Get the code

Download **start.sh** and **stop.sh** from the Scripts tab, or clone the course repo:

```bash
git clone https://github.com/sysdr/shopstream-opentelemetry-debugging.git
cd shopstream-opentelemetry-debugging/lessons/lesson-3
```

`start.sh` writes the complete project for Day 3 into `./shopstream-otel`, so you can start at any lesson.

## What start.sh does

1. Checks that Docker and Docker Compose are available and the engine is running.
2. Writes the project into `./shopstream-otel`.
3. Builds the images and starts Jaeger, Prometheus, Grafana, checkout, inventory, payments (`docker compose up -d --build`; the first build downloads about 1 GB of images).
4. Runs the 6 unit tests inside the tools container.
5. Waits for every service to be healthy, writes `verify.sh`, runs it, then runs the demo.

## What's new in the code

| File | What it does |
|---|---|
| `prometheus/prometheus.yml, Dockerfile` | Prometheus 2.55: scrape and evaluate every 5 s |
| `prometheus/alerts.yml` | AnyCheckoutError (any 5xx in 30 s) and CheckoutErrorRateHigh (>5% for 30 s) |
| `grafana/…` | Grafana 11.3, provisioned data source and the ShopStream — RED dashboard (4 panels) |
| `tools/traffic.py` | Steady background traffic at a fixed rate |
| `tools/shop.py` | promql(), alerts(), wait_prometheus() |

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
[VERIFY] Prometheus sees requests from: ['checkout', 'inventory', 'payments']
[VERIFY] alert rules loaded: ['AnyCheckoutError', 'CheckoutErrorRateHigh']
[VERIFY] Grafana dashboard: ShopStream — RED with 4 panels
PASS  Lesson 3 complete. Your completion code: SHOP3-ALERT-6R3P
== Demo
Warm-up: 20 checkouts/s for 20 s so the rate() windows have data ...
Phase A: 1% of payments fail for 60 s (noise)
Quiet: no failures for 45 s
Phase B: 30% of payments fail for 60 s (incident)
RED now (requests/s by service): checkout=20.0, inventory=20.0, payments=20.0
Pages over the run (3704 checkouts, 345 failed):
   alert                    pages in noise  pages in incident  precision  seconds firing (noise / incident)
   AnyCheckoutError                      1                  1        50%   35 / 50
   CheckoutErrorRateHigh                 0                  1       100%    0 / 11
```

## Try it yourself

```bash
open http://localhost:3000/d/shopstream-red   # Grafana, anonymous viewer
```

```bash
curl -s -X POST localhost:8103/admin/fault -H 'Content-Type: application/json' -d '{"error_rate":0.1}'
```

```bash
curl -s localhost:9090/api/v1/alerts
```

## Verify and get your completion code

```bash
bash verify.sh
```

Checks Prometheus scrapes all three services, both alert rules are loaded and the Grafana dashboard has 4 panels. On success it prints:

```text
PASS  Lesson 3 complete. Your completion code: SHOP3-ALERT-6R3P
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
