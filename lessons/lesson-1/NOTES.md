# Day 1: One checkout, three signals

A customer says checkout is slow. You have three services and a log file per service. Without telemetry you grep three log files by timestamp and guess. With it, you paste one trace ID and see every hop the request took, how long each took, and every log line it wrote. Today you wire up all three signals — traces, metrics and logs — on a small ShopStream checkout, and prove they describe the same request.

## What you build

Three Python services from one Docker image, each started with a different `SERVICE` name:

- **checkout** (port 8101) — `POST /checkout` validates the cart, then calls inventory and payments.
- **inventory** — `POST /reserve` looks up and reserves stock.
- **payments** — `POST /charge` charges the order.

Plus **Jaeger** (port 16686) to collect and show traces. One file, `app/telemetry.py`, gives every service all three signals:

| Signal | What | Where you read it |
|---|---|---|
| Traces | OpenTelemetry SDK, Flask and requests auto-instrumentation, exported over OTLP/HTTP | Jaeger UI |
| Metrics | `http_requests_total` and `http_request_duration_seconds` (RED: rate, errors, duration) | `/metrics` on each service |
| Logs | One JSON object per line, with `trace_id` and `span_id` | `docker compose logs` |

## How one request becomes one trace

```python
provider = TracerProvider(resource=Resource.create({"service.name": SERVICE}))
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint)))
trace.set_tracer_provider(provider)
FlaskInstrumentor().instrument_app(app)   # a server span for every incoming request
RequestsInstrumentor().instrument()       # a client span for every outgoing call, plus the traceparent header
```

When checkout calls inventory, the requests instrumentation adds a W3C `traceparent` header carrying the trace ID and the caller's span ID. Inventory's Flask instrumentation reads it and makes its server span a child of that client span. No service shares memory or a database; the header is the only thing that links them.

The log formatter reads the same context, so every log line written while handling the request carries the trace ID:

```python
ctx = trace.get_current_span().get_span_context()
doc["trace_id"] = format(ctx.trace_id, "032x")
```

## What we measured

One checkout on Docker Desktop:

- **8 spans from 3 services**, 33 ms end to end: checkout's server span, `validate_cart`, two client spans (to inventory and payments), inventory's server span and `stock_lookup`, payments' server span and `card_authorise`.
- The same trace ID appeared in log lines from **all three services**.
- After 100 more checkouts, each service's `http_requests_total` matched the traffic, and the client saw **p50 38 ms, p99 47 ms**.

## Why three signals and not one

- **Metrics** are cheap and aggregated: they tell you *that* something is wrong (error rate up, p99 up) and when it started. They can't tell you which request.
- **Traces** follow one request across services: they tell you *where* the time or the error is.
- **Logs** hold the detail: the order ID, the exception, the response a service got.

The trace ID is the join key between them. On a dashboard you see a spike, from the spike you find a slow trace, and from the trace ID you find the exact log lines.

## Try it

Run these from the `shopstream-otel` folder that `start.sh` created, while the lesson is running.

```bash
curl -s -X POST localhost:8101/checkout -H 'Content-Type: application/json' -d '{"sku":"SKU-3","qty":1}'
```

Copy the `trace_id` from the response, open http://localhost:16686, paste it into the search box, and expand the spans. Then:

```bash
docker compose -p shopstream-otel logs | grep <trace_id>
```

## Say it in an interview

**Q: What are the three pillars of observability, and what is each good for?**
A: Metrics for cheap aggregate health and alerting; traces for following a single request across services to find where time or errors come from; logs for the detailed record of individual events. Correlating them by trace ID is what makes them useful together.

**Q: How does trace context cross a service boundary?**
A: The caller's HTTP client adds a `traceparent` header with the trace ID and its span ID; the callee's server instrumentation extracts it and creates its span as a child. OpenTelemetry follows the W3C Trace Context standard, so different languages and vendors interoperate.

**Q: Why export spans in batches?**
A: Sending each span synchronously would add network latency to every request. A batch processor queues spans and exports them in the background; the trade is a short delay before they appear and the chance of losing the last batch if the process crashes.

## Recap

- One `telemetry.py` gives each service traces, RED metrics and trace-aware JSON logs.
- The `traceparent` header turns calls across three services into one trace.
- Measured: 8 spans, 3 services, 33 ms; p50 38 ms, p99 47 ms over 100 checkouts.
- The trace ID joins metrics, traces and logs.

## Challenge (10 minutes)

Add a span named `fraud_check` inside payments' `/charge`, with an attribute `shop.amount`, and find it in Jaeger.

<details class="sdc-hint"><summary>Hint 1</summary>Use `with tracer.start_as_current_span("fraud_check") as span:` around a short `time.sleep`.</details>

<details class="sdc-hint"><summary>Hint 2</summary>`span.set_attribute("shop.amount", body["amount"])`.</details>

<details class="sdc-hint"><summary>Hint 3</summary>Rebuild with `docker compose -p shopstream-otel up -d --build`, place an order, and open its trace: the new span sits under payments' server span.</details>
