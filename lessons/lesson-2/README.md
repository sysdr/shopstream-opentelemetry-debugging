# Implementation guide — Day 2: Find the slow service in 5 minutes

Time: 25–35 minutes. Needs **Docker** (Docker Desktop, or Docker Engine with the Compose plugin) and about 2 GB of free memory. Nothing else: Python and every tool run inside containers.

## Get the code

Download **start.sh** and **stop.sh** from the Scripts tab, or clone the course repo:

```bash
git clone https://github.com/sysdr/shopstream-opentelemetry-debugging.git
cd shopstream-opentelemetry-debugging/lessons/lesson-2
```

`start.sh` writes the complete project for Day 2 into `./shopstream-otel`, so you can start at any lesson.

## What start.sh does

1. Checks that Docker and Docker Compose are available and the engine is running.
2. Writes the project into `./shopstream-otel`.
3. Builds the images and starts Jaeger, checkout, inventory, payments (`docker compose up -d --build`; the first build downloads about 1 GB of images).
4. Runs the 6 unit tests inside the tools container.
5. Waits for every service to be healthy, writes `verify.sh`, runs it, then runs the demo.

## What's new in the code

| File | What it does |
|---|---|
| `app/main.py` | Fault injection: POST /admin/fault {delay_ms, error_rate}; the delay is an `injected_delay` span |
| `tools/analyze.py` | Reads traces from Jaeger's query API; self time per service; nearest-rank p50/p99; slowest service |
| `tools/load.py` | Concurrent checkouts with client-side latency |
| `tests/test_analyze.py` | Self-time and percentile tests on hand-built traces |

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
[VERIFY] 200 ms injected into inventory; slowest by self-time p99: inventory (210 ms over 40 traces)
PASS  Lesson 2 complete. Your completion code: SHOP3-SLOW-9K2D
== Demo
Baseline: 200 checkouts, client p50 41 ms, p99 68 ms, errors 0
Self time by service (baseline)
   service     traces   self p50 ms   self p99 ms
   checkout       200          5.0          14.1
   inventory      200          6.9          18.9
   payments       200         16.7          23.4
Break it: payments now waits 300 ms before every charge (POST /admin/fault)
Slow:     200 checkouts, client p50 336 ms, p99 353 ms, errors 0
Self time by service (with the fault)
   service     traces   self p50 ms   self p99 ms
   checkout       200          4.4           8.9
   inventory      200          7.0          11.2
   payments       200        316.8         322.5
Slowest service by self-time p99: payments  (+299 ms vs baseline)
Found from traces in 2.1 s of analysis; checkout's own self-time stayed at 8.9 ms p99 even though its total latency rose
Fault cleared.
```

## Try it yourself

```bash
curl -s -X POST localhost:8102/admin/fault -H 'Content-Type: application/json' -d '{"delay_ms":150}'
```

```bash
cd shopstream-otel && docker compose -p shopstream-otel run --rm -T tools python demo.py
```

```bash
curl -s -X POST localhost:8102/admin/fault -H 'Content-Type: application/json' -d '{}'
```

## Verify and get your completion code

```bash
bash verify.sh
```

Adds a 200 ms delay to a service it chooses, sends load, and checks the trace analysis names that service with self-time p99 above 150 ms while checkout's own self time stays small. On success it prints:

```text
PASS  Lesson 2 complete. Your completion code: SHOP3-SLOW-9K2D
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
