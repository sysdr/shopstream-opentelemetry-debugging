# Debug Microservices with OpenTelemetry and Prometheus

Source code for the free course **[Debug Microservices with OpenTelemetry and Prometheus](https://systemdrd.com/courses/debug-microservices-with-opentelemetry-and-prometheus/)** on systemdrd.com — step 3 of the free ShopStream path.

ShopStream's checkout calls inventory and payments. Over six lessons you give all three services traces, metrics and logs, find a slow service from traces alone, build RED dashboards and an alert worth waking up for, catch a connection-pool leak and a memory leak, stop a cascading failure with timeouts, jittered retries and a circuit breaker, and generate a postmortem from telemetry.

- **Docker with Compose** is all you need. Python 3.12, Flask, OpenTelemetry 1.29, Jaeger 1.62, Prometheus 2.55 and Grafana 11.3 all run in containers.
- Every lesson injects a real fault and measures the result; the numbers in the notes come from those runs.

## Lessons

Each lesson folder is self-contained: `start.sh` writes the complete project up to that day into `./shopstream-otel`, builds the images, runs the unit tests, starts the stack, verifies it and runs a measured demo. `README.md` is the implementation guide, `NOTES.md` the lesson notes, `diagrams/` the diagrams.

| Day | Lesson | What you measure |
|---|---|---|
| 1 | [One checkout, three signals](lessons/lesson-1) | 8 spans from 3 services in one trace; the trace ID in every service's logs |
| 2 | [Find the slow service in 5 minutes](lessons/lesson-2) | payments +300 ms: client p99 68 → 353 ms, found by self time from traces |
| 3 | [Dashboards and one alert worth waking for](lessons/lesson-3) | any-error alert 50% precision; error-ratio alert 100% |
| 4 | [Catch a memory leak and an exhausted pool](lessons/lesson-4) | 5% connection leak: failures after 4 s, pool alert after 19 s; memory 51 → 116 MB |
| 5 | [Stop a cascading failure](lessons/lesson-5) | payments hung: browsing 76% (naive), 41% (retry storm), 100% (breaker) |
| 6 | [Write the postmortem](lessons/lesson-6) | detect 20 s, mitigate 40 s, recover 65 s; POSTMORTEM.md generated from telemetry |

## Quick start

```bash
git clone https://github.com/sysdr/shopstream-opentelemetry-debugging.git
cd shopstream-opentelemetry-debugging/lessons/lesson-1
bash start.sh     # build, tests, containers, verify, demo
bash stop.sh
```

| What | Where |
|---|---|
| Jaeger | http://localhost:16686 |
| checkout | http://localhost:8101 (inventory 8102, payments 8103) |
| Prometheus (Days 3–6) | http://localhost:9090 |
| Grafana (Days 3–6) | http://localhost:3000/d/shopstream-red (admin / shopstream) |

`bash test_all.sh` runs all six lessons (about 20 minutes).

## The finished project

The repository root holds the final code (Day 6). Run it with:

```bash
docker compose -p shopstream-otel up -d --build
docker compose -p shopstream-otel run --rm -T -w /srv tools python -m unittest discover -s tests
docker compose -p shopstream-otel run --rm -T tools python incident.py 0.1 20 > POSTMORTEM.md
docker compose -p shopstream-otel down
```

| Path | Role |
|---|---|
| `app/telemetry.py` | OpenTelemetry tracing (OTLP to Jaeger), RED metrics, JSON logs with trace_id |
| `app/main.py` | checkout, inventory and payments (one image, `SERVICE` picks the role); fault injection; connection pool; resilience modes |
| `app/resilience.py` | circuit breaker and jittered backoff |
| `prometheus/`, `grafana/` | scrape config, alert rules, provisioned RED dashboard |
| `tools/` | analysis (`analyze.py`), load (`load.py`, `traffic.py`, `mix.py`), `incident.py` postmortem generator |
| `tests/` | 11 unit tests |

## License

MIT
