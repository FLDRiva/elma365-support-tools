#!/bin/bash
# elma365-collect.sh — сборщик диагностики ELMA365
# Вывод: elma365-report-TIMESTAMP.json.gz

set -euo pipefail

NAMESPACE=""
OUTPUT_DIR="$(pwd)"
TIMESTAMP=$(date '+%Y.%m.%d_%H.%M')
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        --output|-o)    OUTPUT_DIR="$2"; shift 2 ;;
        --verbose|-v)   VERBOSE=1; shift ;;
        --help|-h)
            echo "Использование: $0 [--namespace NS] [--output DIR]"
            exit 0 ;;
        *) shift ;;
    esac
done

log()   { echo "$(date '+%H:%M:%S') $*" >&2; }
debug() { [[ $VERBOSE -eq 1 ]] && echo "DEBUG $*" >&2 || true; }
warn()  { echo "WARN $*" >&2; }

check_deps() {
    local missing=()
    for cmd in kubectl jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Не найдены: ${missing[*]}"
        exit 1
    fi
}

detect_namespace() {
    [[ -n "$NAMESPACE" ]] && return

    NAMESPACE=$(kubectl get ns -l "app.kubernetes.io/name=elma365" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$NAMESPACE" ]]; then
        read -rp "Namespace ELMA365 не найден. Введи namespace: " NAMESPACE
        [[ -z "$NAMESPACE" ]] && { echo "Namespace не указан"; exit 1; }
    fi
    log "Namespace: $NAMESPACE"
}

collect_k8s() {
    log "Kubernetes..."

    local pods_json
    pods_json=$(kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')

    # kubectl top --containers требует metrics-server; ключ — "pod/container"
    local top_data="{}"
    if kubectl top pod -n "$NAMESPACE" --containers --no-headers 2>/dev/null | head -1 | grep -q '.'; then
        top_data=$(kubectl top pod -n "$NAMESPACE" --containers --no-headers 2>/dev/null \
            | awk '{print "{\"" $1 "/" $2 "\": {\"cpu\": \"" $3 "\", \"mem\": \"" $4 "\"}}"}' \
            | jq -sc 'add // {}' 2>/dev/null || echo "{}")
    fi

    local pods
    pods=$(echo "$pods_json" | jq --argjson top "$top_data" '[.items[] |
        .metadata.name as $pod_name |
        (.spec.containers | map({(.name): {
            cpu_req: (.resources.requests.cpu    // ""),
            cpu_lim: (.resources.limits.cpu      // ""),
            mem_req: (.resources.requests.memory // ""),
            mem_lim: (.resources.limits.memory   // "")
        }}) | add // {}) as $spec |
        {
            name:     $pod_name,
            phase:    .status.phase,
            ready:    ([ .status.containerStatuses[]?.ready ] | all),
            restarts: ([.status.containerStatuses[]?.restartCount] | add // 0),
            node:     .spec.nodeName,
            containers: [.status.containerStatuses[]? | .name as $cname |
                {
                    name:       $cname,
                    ready:      .ready,
                    restarts:   .restartCount,
                    last_state: (.lastState.terminated.reason // ""),
                    cpu_req:    ($spec[$cname].cpu_req // ""),
                    cpu_lim:    ($spec[$cname].cpu_lim // ""),
                    mem_req:    ($spec[$cname].mem_req // ""),
                    mem_lim:    ($spec[$cname].mem_lim // ""),
                    cpu_now:    ($top["\($pod_name)/\($cname)"].cpu // ""),
                    mem_now:    ($top["\($pod_name)/\($cname)"].mem // "")
                }
            ]
        }
    ]' 2>/dev/null || echo "[]")

    local hpa
    hpa=$(kubectl get hpa -n "$NAMESPACE" -o json 2>/dev/null \
        | jq '[.items[] | {
            name:    .metadata.name,
            target:  .spec.scaleTargetRef.name,
            min:     (.spec.minReplicas // 1),
            max:     .spec.maxReplicas,
            current: .status.currentReplicas,
            desired: .status.desiredReplicas
        }]' 2>/dev/null || echo "[]")

    jq -n \
        --argjson pods "$pods" \
        --argjson hpa "$hpa" \
        '{pods: $pods, hpas: $hpa}'
}

collect_logs() {
    log "Логи сервисов (error/warn)..."

    local entries="[]"
    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" \
        -l tier=elma365 \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    local total=0
    for pod in $pods; do
        [[ $total -ge 500 ]] && break

        local tmp_log
        tmp_log=$(mktemp)
        kubectl logs "$pod" -n "$NAMESPACE" \
            --tail=200 2>/dev/null > "$tmp_log" || true

        if [[ -s "$tmp_log" ]]; then
            local pod_entries
            pod_entries=$(jq -Rn --arg pod "$pod" '
                [inputs | . as $line | try fromjson catch null |
                 select(. != null) |
                 select(.level == "error" or .level == "fatal" or .level == "warn" or .level == "warning") |
                 {
                   pod:     $pod,
                   level:   .level,
                   time:    (.timestamp // .time // ""),
                   service: ((.logger // "") | ltrimstr("elma365.")),
                   msg:     (.msg // .message // ""),
                   error:   (.error // "")
                 }]
            ' < "$tmp_log" 2>/dev/null || echo "[]")

            local count
            count=$(echo "$pod_entries" | jq 'length' 2>/dev/null || echo 0)
            if [[ "$count" -gt 0 ]]; then
                total=$((total + count))
                entries=$(jq -n --argjson a "$entries" --argjson b "$pod_entries" '$a + $b')
            fi
        fi
        rm -f "$tmp_log"
    done

    entries=$(echo "$entries" | jq 'sort_by(.time) | reverse | .[:500]' 2>/dev/null || echo "[]")

    jq -n --argjson entries "$entries" '{entries: $entries}'
}

main() {
    check_deps
    detect_namespace

    local report_file="$OUTPUT_DIR/elma365-report-${TIMESTAMP}.json.gz"

    local cluster logs
    cluster=$(collect_k8s)
    logs=$(collect_logs)

    jq -n \
        --arg namespace    "$NAMESPACE" \
        --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg version      "1.0" \
        --argjson cluster  "$cluster" \
        --argjson logs     "$logs" \
        '{
            meta: {
                namespace:    $namespace,
                collected_at: $collected_at,
                version:      $version
            },
            cluster: $cluster,
            logs:    $logs
        }' | gzip > "$report_file"

    log "Готово: $(basename "$report_file")"
    echo "$report_file"
}

main "$@"
