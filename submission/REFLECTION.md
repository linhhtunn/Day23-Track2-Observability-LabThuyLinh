# Day 23 Lab Reflection

**Student:** Nguyễn Thùy Linh
**Submission date:** 2026-05-11
**Lab repo URL:** https://github.com/linhhtunn/Day23-Track2-Observability-LabThuyLinh

---

## 1. Hardware + setup output

Chạy natively trên Windows 11  qua `start-local.ps1`. Python 3.12 (Miniconda), tất cả binaries được tải về `local-bins/`.

```
platform: Windows 11 Home Single Language
mode: native-binaries (no Docker)
python: 3.12.11 (miniconda3)
services:
  prometheus:     ready (port 9090)
  alertmanager:   ready (port 9093)
  grafana:        ready (port 3000)
  loki:           ready (port 3100)
  jaeger:         ready (port 16686)
  otel-collector: ready (port 8888)
  app (FastAPI):  ready (port 8000)
all_ports_free: true
```

---

## 2. Track 02 — Dashboards & Alerts

### 6 essential panels

Dashboard "AI Service Overview (Day 23)" hiển thị:
- Request rate: `rate(inference_requests_total[1m])`
- Error rate: `rate(inference_requests_total{status="error"}[1m])`
- Latency P50/P95/P99 từ histogram buckets
- Active in-flight: `inference_active_gauge`
- Token throughput (input + output tổng hợp)
- GPU utilization: `gpu_utilization_percent` (simulated 30–95%)

Screenshot: `submission/screenshots/dashboard-overview.png`

### Burn-rate panel

SLO dashboard dùng multi-window multi-burn-rate alerting:
- Fast burn: 1h window × 14× budget consumption rate → Critical
- Slow burn: 6h window × 6× budget rate → Warning

Screenshot: `submission/screenshots/slo-burn-rate.png`

### Alert fire + resolve

| When | What | Evidence |
|---|---|---|
| T0 | Gửi liên tục request `fail=true` | `scripts/trigger-alert.sh` |
| T0+90s | `ServiceDown` fired | `submission/screenshots/alertmanager-firing.png` |
| T1 | Restore app | restart uvicorn |
| T1+60s | Alert resolved | `submission/screenshots/slack-resolved.png` |

### Điều bất ngờ về Prometheus / Grafana

Cardinality explosion nghiêm trọng hơn nhiều so với tôi nghĩ: thêm một label `user_id` vào `inference_requests_total` với 10,000 user có thể tạo ra 100,000 time series chỉ cho một counter, và Prometheus OOM trong vài giờ. Grafana provisioning-as-code (JSON dashboards commit vào git) cũng rất tiện: không cần click UI, mỗi thay đổi dashboard đều có git history và có thể review như code.

---

## 3. Track 03 — Tracing & Logs

### Trace trong Jaeger

Service `inference-api` tạo root span `predict` với 3 child spans:
- `embed-text` (~5ms) — text embedding step
- `vector-search` (~10ms) — similarity search
- `generate-tokens` (~150–300ms) — phần lớn latency ở đây

Screenshot: `submission/screenshots/jaeger-trace.png`

### Log line correlated to trace

```json
{"event": "prediction served", "level": "info", "timestamp": "2026-05-11T10:23:45.123Z",
 "model": "llama3-mock", "input_tokens": 8, "output_tokens": 42,
 "quality": 0.821, "duration_seconds": 0.2134,
 "trace_id": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"}
```

`trace_id` trong log khớp với span ID trong Jaeger. Grafana Loki tự động link log → Jaeger nhờ `derivedFields` regex `"trace_id":"([a-fA-F0-9]+)"`.

### Tail-sampling math

Với 10 req/s, error rate 1%, slow rate (>2s) 0.5%:
- 100% errors: 0.1 req/s giữ hết
- 100% slow: 0.05 req/s giữ hết
- 1% of healthy 9.85 req/s: 0.099 req/s

Tổng lưu: **0.249 req/s ≈ 2.5%** của tổng traffic, nhưng bao phủ 100% errors và slow outliers.

---

## 4. Track 04 — Drift Detection

### PSI scores

```json
{
  "prompt_length": {
    "psi": 3.461,
    "kl": 1.798,
    "ks_stat": 0.702,
    "ks_pvalue": 0.0,
    "drift": "yes"
  },
  "embedding_norm": {
    "psi": 0.019,
    "kl": 0.032,
    "ks_stat": 0.052,
    "ks_pvalue": 0.0,
    "drift": "no"
  },
  "response_length": {
    "psi": 0.016,
    "kl": 0.018,
    "ks_stat": 0.056,
    "ks_pvalue": 0.0,
    "drift": "no"
  },
  "response_quality": {
    "psi": 8.849,
    "kl": 13.501,
    "ks_stat": 0.941,
    "ks_pvalue": 0.0,
    "drift": "yes"
  }
}
```

### Chọn test nào cho feature nào?

- **prompt_length** → PSI: đo distribution shift của input rõ ràng (Normal(50) → Normal(85)), PSI > 0.2 là ngưỡng chuẩn production.
- **embedding_norm** → KS test: phân phối hẹp ổn định, cần độ nhạy cao với shift nhỏ trong tails.
- **response_length** → KS test: tương tự, muốn phát hiện sớm khi output length bắt đầu thay đổi.
- **response_quality** → PSI + KL: thay đổi từ Beta(8,2) → Beta(2,6) là quality regression thảm họa; PSI capture shape change toàn diện, KL divergence đo information loss giữa hai phân phối.

---

## 5. Track 05 — Cross-Day Integration

### Prior-day metric khó expose nhất?

Khó nhất là **Day 17 (Airflow DAG metrics)** vì Airflow không có Prometheus endpoint tích hợp sẵn — cần thêm `statsd_exporter` như một service trung gian, cấu hình `statsd_port` trong `airflow.cfg`, sau đó viết mapping rules để convert StatsD metric names sang Prometheus labels. Không giống Day 19 (Qdrant expose `/metrics` built-in) hay Day 20 (llama.cpp có `/metrics` mặc định). Với Airflow cần thêm một service + mapping file, rất dễ bị format mismatch giữa StatsD và Prometheus naming convention.

---

## 6. The single change that mattered most

**Label discipline trên `inference_requests_total`** là thay đổi quan trọng nhất trong toàn bộ thiết kế stack. Ban đầu tôi cân nhắc thêm label `user_id`, `endpoint`, và `version` vào counter để có thể debug chi tiết từng user segment. Nhưng sau khi nghiên cứu slide §3 về cardinality budget, tôi quyết định chỉ giữ `{model, status}` — 2 dimensions với cardinality thấp (~5 models × 2 statuses = 10 time series). Quyết định này biến stack từ "đẹp trên paper nhưng chết Prometheus trong 24h" thành "hoạt động ổn định dài hạn."

Concept cốt lõi là **cardinality budget**: mỗi label dimension nhân tất cả existing series. Một `user_id` với 50,000 users × 10 base series = 500,000 series chỉ cho một metric. Với 6 metric families như trong lab, đó là 3 triệu active time series — Prometheus cần ~15GB RAM chỉ để giữ head block. Bài học này áp dụng ngay vào Track 05: khi integrate Day 19 Qdrant metrics, tôi drop label `collection_id` (có thể có hàng trăm collections) và chỉ giữ `node_id`. Một quyết định nhỏ về label schema ở ngày thiết kế ngăn được incident lớn ở production. Đây chính là sự khác biệt giữa observability "hoạt động" và observability "có thể vận hành lâu dài."

---

## Screenshots

Các screenshots trong `submission/screenshots/`:
- `dashboard-overview.png` — AI Service Overview với 6 panels
- `slo-burn-rate.png` — SLO burn-rate dashboard
- `alertmanager-firing.png` — Alert đang firing trong Alertmanager UI
- `slack-firing.png` — Slack notification khi alert fire
- `slack-resolved.png` — Slack notification khi alert resolve
- `jaeger-trace.png` — End-to-end trace với embed-text → vector-search → generate-tokens
