#!/usr/bin/env bash
# `make metrics-up` / `make metrics-check` (SPEC FR-50, FR-52).
#   up:    start Prometheus + Grafana for SCHED's stack (slurm: compose profile; k8s or slinky: kind).
#   check: ask Prometheus for a sample of ray_rsk_epoch_seconds and (Slurm stacks) slurm_jobs within the
#          last hour, and ask Grafana for the dashboard. Exit 1 if anything is missing.
set -euo pipefail
: "${PROMETHEUS_IMAGE:?}" "${GRAFANA_IMAGE:?}" "${COMPOSE:?}"
action=${1:?usage: metrics.sh up|check}
SCHED=${SCHED:-slurm}
[[ "$SCHED" =~ ^(slurm|k8s|slinky)$ ]] || { echo "metrics: SCHED must be slurm, k8s or slinky" >&2; exit 2; }
k() { kubectl --context kind-rayk8s "$@"; }

# wget from inside the Prometheus container/pod, which reaches both Prometheus and Grafana by name.
in_prom() {
  if [[ $SCHED == slurm ]]; then docker exec prometheus wget -qO- "$1"; else k -n monitoring exec deploy/prometheus -- wget -qO- "$1"; fi
}
urlencode() {
  local s=$1 out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    case $c in [a-zA-Z0-9._~-]) out+=$c ;; *) printf -v c '%%%02X' "'$c"; out+=$c ;; esac
  done
  echo "$out"
}

up() {
  if [[ $SCHED == slurm ]]; then
    $COMPOSE --profile metrics up -d --wait prometheus grafana
  else
    kind get clusters 2>/dev/null | grep -qx rayk8s || { echo "metrics: no kind cluster (run make train-k8s or make up-slinky)" >&2; exit 1; }
    k create namespace monitoring --dry-run=client -o yaml | k apply -f - >/dev/null
    k -n monitoring create configmap prometheus-config --from-file=prometheus.yml=observability/prometheus/k8s.yml \
      --dry-run=client -o yaml | k apply -f - >/dev/null
    k -n monitoring create configmap grafana-datasources --from-file=observability/grafana/provisioning/datasources \
      --dry-run=client -o yaml | k apply -f - >/dev/null
    k -n monitoring create configmap grafana-providers --from-file=observability/grafana/provisioning/dashboards \
      --dry-run=client -o yaml | k apply -f - >/dev/null
    k -n monitoring create configmap grafana-dashboard --from-file=observability/grafana/rsk-dashboard.json \
      --dry-run=client -o yaml | k apply -f - >/dev/null
    sed -e "s|__PROMETHEUS_IMAGE__|$PROMETHEUS_IMAGE|" -e "s|__GRAFANA_IMAGE__|$GRAFANA_IMAGE|" k8s/metrics.yaml | k apply -f - >/dev/null
    k -n monitoring rollout status deploy/prometheus --timeout=300s
    k -n monitoring rollout status deploy/grafana --timeout=300s
    echo "metrics: Grafana: kubectl --context kind-rayk8s -n monitoring port-forward svc/grafana 3000:3000"
  fi
  echo "metrics: Grafana dashboard at http://127.0.0.1:3000/d/rsk"
}

check() {
  local failed=0 q out
  local queries=("max_over_time(ray_rsk_epoch_seconds{scheduler=\"$SCHED\"}[1h])")
  [[ $SCHED != k8s ]] && queries+=("max_over_time(slurm_jobs{scheduler=\"$SCHED\"}[1h])")
  for q in "${queries[@]}"; do
    out=$(in_prom "http://prometheus:9090/api/v1/query?query=$(urlencode "$q")" 2>&1 || true)
    if [[ "$out" == *'"status":"success"'* && "$out" != *'"result":[]'* ]]; then
      echo "PASS prometheus has $q"
    else
      echo "FAIL prometheus has no sample for $q: ${out:0:200}"
      failed=1
    fi
  done
  out=$(in_prom "http://grafana:3000/api/dashboards/uid/rsk" 2>&1 || true)
  if [[ "$out" == *'"uid":"rsk"'* ]]; then echo "PASS grafana serves dashboard rsk"; else echo "FAIL grafana dashboard rsk: ${out:0:200}"; failed=1; fi
  return "$failed"
}

"$action"
