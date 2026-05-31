# Observability Stack

Docker Compose stack deployed on the same EC2 instance as the Flask backend.
Currently active: **Logs** pillar only (Grafana + Loki + Promtail).
Metrics and Traces are configured but commented out — see [Extending the Stack](#extending-the-stack).

## The Three Pillars

| Pillar | Tool | Purpose | Query Language |
|---|---|---|---|
| **Logs** | Loki + Promtail | Stores raw log lines from files | LogQL |
| **Metrics** | Prometheus + Mimir | Stores numeric time-series data scraped from `/metrics` endpoints | PromQL |
| **Traces** | Tempo | Stores distributed request traces from OpenTelemetry-instrumented apps | TraceQL |

## Active Services

### Grafana (`grafana/grafana:11.6.1`)
- UI at `http://localhost:3000` via SSH tunnel
- Admin credentials set in `.env`
- Data sources and dashboards provisioned automatically from `provisioning/`

### Loki (`grafana/loki:3.4.3`)
- Receives log streams pushed by Promtail
- Internal URL: `http://loki:3100`
- Data stored in `loki-data` Docker volume

### Promtail (`grafana/promtail:3.4.3`)
- Tails log sources on the EC2 host and ships them to Loki
- Configured in `promtail-config.yaml`
- Mounts `/var/lib/docker/containers` (read-only) to access Docker container logs
- Currently scrapes:
  - `/var/lib/docker/containers/*/*.log` — all Docker container stdout/stderr, labelled as `job=flask`. Flask logs to stdout so everything (app logs + Gunicorn worker output + crashes) is captured here.
  - `/var/log/nginx/*.log` — Nginx access/error logs (Nginx runs on the host, not in Docker)

## Accessing Grafana

Port 3000 is not open to the internet. Access via SSH tunnel:

```bash
ssh -i <path-to-key>.pem \
    -L 3000:localhost:3000 \
    -N ec2-user@<EC2_HOST>
```

Then open `http://localhost:3000` in your browser.

## Provisioning

Grafana is configured automatically on startup — no manual setup required.

```
provisioning/
  datasources/
    loki.yaml          # Loki registered as default data source
  dashboards/
    dashboards.yaml    # Tells Grafana where to find dashboard JSON files
    flask.json         # Flask App dashboard (logs + request rate + error count)
```

To add a new dashboard: drop a `.json` file into `provisioning/dashboards/` and restart Grafana.
To export an existing dashboard: Grafana UI → Dashboard → Share → Export → Save to file.

---

## Extending the Stack

### Add Metrics (Prometheus + Mimir)

Uncomment `prometheus` and `mimir` in `docker-compose.yaml`.

**Requirements:**

Flask must expose a `/metrics` endpoint. Add `prometheus-flask-exporter` to `requirements.txt` and instrument the app:

```python
from prometheus_flask_exporter import PrometheusMetrics
metrics = PrometheusMetrics(app)
```

Prometheus is already configured to scrape `host.docker.internal:8000/metrics` (`prometheus.yaml`) and remote-write to Mimir.

Add Mimir as a Grafana data source in `provisioning/datasources/mimir.yaml`:

```yaml
apiVersion: 1
datasources:
  - name: Mimir
    type: prometheus
    url: http://mimir:9009/prometheus
```

**What you gain:** request rate, error rate, latency histograms, CPU/memory panels using PromQL.

---

### Add Traces (Tempo)

Uncomment `tempo` in `docker-compose.yaml`.

Flask already has OpenTelemetry instrumentation in `app.py` sending spans to `http://tempo:4318/v1/traces`.

Add Tempo as a Grafana data source in `provisioning/datasources/tempo.yaml`:

```yaml
apiVersion: 1
datasources:
  - name: Tempo
    type: tempo
    url: http://tempo:3200
```

**What you gain:** end-to-end request traces, per-endpoint latency breakdown, slow span identification.

---

### Correlate Logs → Traces

Once both Loki and Tempo are active, clicking a log line can jump directly to its trace.
Add the following to `provisioning/datasources/loki.yaml` under the datasource entry:

```yaml
    jsonData:
      derivedFields:
        - name: TraceID
          matcherRegex: "trace_id=(\\w+)"
          url: "${__value.raw}"
          datasourceUid: tempo
```

---

### Add More Log Sources

Promtail already tails all Docker container logs via `/var/lib/docker/containers`. To filter or label specific containers differently, add a pipeline stage in `promtail-config.yaml` that matches on the container name label:

```yaml
    pipeline_stages:
      - json:
          expressions:
            output: log
            stream: stream
            container_name: attrs.name
      - labels:
          stream:
          container_name:
      - output:
          source: output
```

To capture additional host log files (e.g. system logs), add a new `scrape_config` entry:

```yaml
  - job_name: system
    static_configs:
      - targets: [localhost]
        labels:
          job: system
          __path__: /var/log/messages
```

---

### Move to a Dedicated Observability Instance

On a `t4g.nano` (512 MB), only Grafana + Loki + Promtail fits comfortably (~400 MB).
To run the full stack, either:

- **Upgrade** the app instance to `t4g.medium` (4 GB) — change `instance_type` in `backend/infra/terraform.tfvars`
- **Separate** — provision a second EC2 instance for observability, deploy the full stack there, and run only Promtail on the app instance pointing at the remote Loki/Tempo endpoints:

```yaml
# promtail-config.yaml on the app instance
clients:
  - url: http://<OBSERVABILITY_EC2_PRIVATE_IP>:3100/loki/api/v1/push
```

The observability instance's security group only needs to accept ports 3100 (Loki) and 4318 (Tempo) from the app instance's private IP.

---

## Resource Usage (approximate)

| Service | RAM |
|---|---|
| Grafana | ~200 MB |
| Loki | ~150 MB |
| Promtail | ~50 MB |
| Tempo | ~200 MB |
| Prometheus | ~100 MB |
| Mimir | ~250 MB |
| **Full stack total** | **~950 MB** |
| **Current (Loki only)** | **~400 MB** |


