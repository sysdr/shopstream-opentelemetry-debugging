# Day 3: Dashboards and one alert worth waking for

An alert that fires for every hiccup trains people to ignore it. An alert that never fires lets a real outage run for an hour. Today you add Prometheus and Grafana to ShopStream, build a RED dashboard for all three services, and compare two alerts on the same traffic: one that pages for any error, and one that pages only when customers are actually hurting.

## What you build

- **Prometheus** (port 9090) scraping `/metrics` on checkout, inventory and payments every 5 seconds, with alert rules in `prometheus/alerts.yml`.
- **Grafana** (port 3000), provisioned from files: a Prometheus data source and a dashboard called **ShopStream — RED** with four panels — rate, errors (% 5xx), p99 and p50 duration, each split by service. Anonymous viewers can look; admin login is `admin / shopstream`.
- **Two alerts** on checkout:

```yaml
- alert: AnyCheckoutError          # pages for every hiccup
  expr: sum(increase(http_requests_total{service="checkout",status=~"5.."}[30s])) > 0

- alert: CheckoutErrorRateHigh     # pages when customers are hurting
  expr: |
    sum(rate(http_requests_total{service="checkout",status=~"5.."}[1m]))
      / sum(rate(http_requests_total{service="checkout"}[1m])) > 0.05
  for: 30s
```

## RED in PromQL

RED — **R**ate, **E**rrors, **D**uration — is the minimum dashboard for any request-driven service:

```promql
sum by (service) (rate(http_requests_total[1m]))                                    # rate
100 * sum by (service) (rate(http_requests_total{status=~"5.."}[1m]))
    / sum by (service) (rate(http_requests_total[1m]))                              # errors %
histogram_quantile(0.99, sum by (service, le) (rate(http_request_duration_seconds_bucket[1m])))  # p99
```

`histogram_quantile` estimates the percentile from bucket counts, so its precision depends on the buckets you chose in `telemetry.py` (5 ms up to 10 s). Rates are always computed over a window — here 1 minute — which smooths noise but also delays how fast a change shows up.

## The experiment

Traffic runs at 20 checkouts per second throughout:

1. **Noise (60 s):** payments fails 1% of requests — the normal background of retries, deploys and flaky networks.
2. **Quiet (45 s):** no failures, so every alert can resolve.
3. **Incident (60 s):** payments fails 30% of requests.

The demo records every time each alert *starts* firing (a page) and in which phase.

## What we measured

3,704 checkouts, 345 failed:

| Alert | Pages during noise | Pages during incident | Precision | Seconds firing (noise / incident) |
|---|---|---|---|---|
| AnyCheckoutError | 1 | 1 | **50%** | 35 / 50 |
| CheckoutErrorRateHigh | **0** | 1 | **100%** | 0 / 11 |

`AnyCheckoutError` woke someone up for 1% background noise and stayed red for 35 seconds of it. `CheckoutErrorRateHigh` ignored the noise and paged once for the real incident.

The cost shows in the last column: the ratio alert was firing for only 11 of the incident's 60 seconds. The 1-minute rate window needs time to climb past 5%, and then `for: 30s` has to hold. That is roughly 45–50 seconds of detection delay — a deliberate trade of speed for precision. You can tighten it (shorter windows, shorter `for`) and you will buy back some noise.

## Choosing what to page on

- **Page on symptoms users feel:** error ratio and latency of the user-facing service. A 5xx inside inventory that checkout retried successfully is not a page.
- **Use ratios, not counts:** "5 errors" means something different at 1 request/s and at 1,000.
- **Require persistence:** `for:` filters spikes that resolve on their own.
- **Everything else goes on a dashboard or a ticket**, not a pager.

## Try it

Run these from the `shopstream-otel` folder that `start.sh` created, while the lesson is running.

Open http://localhost:3000/d/shopstream-red and http://localhost:9090/alerts, then:

```bash
docker compose -p shopstream-otel run --rm -T tools python -c "import shop; shop.fault('payments', error_rate=0.1)"
```

Watch the errors panel climb and the alert go from inactive to pending to firing. Clear with `shop.clear_faults()`.

## Say it in an interview

**Q: What would you alert on for a checkout service?**
A: User-facing symptoms: error ratio above a threshold for a sustained period, and p99 latency above the SLO. Causes such as CPU or a single dependency's errors go on dashboards, or become alerts only when they reliably predict user impact.

**Q: What does `for:` do in a Prometheus alert?**
A: The expression must be true at every evaluation for that long before the alert moves from pending to firing. It removes flapping and one-off spikes, at the cost of slower detection.

**Q: What are the RED metrics?**
A: Rate of requests, errors (count or ratio of failed requests) and duration (latency distribution, usually percentiles). Together they describe how a request-driven service is serving its callers.

## Recap

- Prometheus scrapes RED metrics; Grafana shows them per service from a provisioned dashboard.
- Measured: the any-error alert had 50% precision and fired for 35 s of pure noise; the ratio alert had 100% precision.
- The ratio alert's precision cost detection time: firing for only 11 s of a 60 s incident.
- Page on sustained symptoms as ratios; put causes on dashboards.

## Challenge (10 minutes)

Add a latency alert, `CheckoutSlow`, that fires when checkout's p99 is above 500 ms for 30 s, and trigger it with a payments delay.

<details class="sdc-hint"><summary>Hint 1</summary>Use `histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{service="checkout"}[1m]))) > 0.5`.</details>

<details class="sdc-hint"><summary>Hint 2</summary>Add it to `prometheus/alerts.yml`, then `docker compose -p shopstream-otel up -d --build prometheus`.</details>

<details class="sdc-hint"><summary>Hint 3</summary>`shop.fault("payments", delay_ms=600)` and keep traffic running with `python load.py`.</details>
