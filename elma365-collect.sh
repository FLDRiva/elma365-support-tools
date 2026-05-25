#!/bin/bash
# elma365-collect.sh — сборщик диагностики ELMA365
# Читает DSN из Secret ELMA365. Не требует нашего сервиса.
# Результат: elma365-report-TIMESTAMP.json.gz

set -euo pipefail

NAMESPACE=""
OUTPUT_DIR="$(pwd)"
DB_SECRET="elma365-db-connections"
TIMESTAMP=$(date '+%Y.%m.%d')
REPORT_FILE=""
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        --output|-o)    OUTPUT_DIR="$2"; shift 2 ;;
        --secret)       DB_SECRET="$2"; shift 2 ;;
        --verbose|-v)   VERBOSE=1; shift ;;
        --help|-h)
            echo "Использование: $0 [--namespace NS] [--output DIR] [--secret NAME]"
            exit 0 ;;
        *) shift ;;
    esac
done

log()  { echo "[$(date '+%H:%M:%S')] $*" >&2; }
debug(){ [[ $VERBOSE -eq 1 ]] && echo "[DEBUG] $*" >&2 || true; }
warn() { echo "[WARN]  $*" >&2; }

check_deps() {
    local missing=()
    for cmd in kubectl jq openssl curl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Не найдены: ${missing[*]}"
        exit 1
    fi
}

detect_namespace() {
    if [[ -n "$NAMESPACE" ]]; then
        return
    fi

    NAMESPACE=$(kubectl get secret --all-namespaces 2>/dev/null \
        | awk "/$DB_SECRET/ && \$1 != \"default\""'{print $1}' | head -1)

    if [[ -z "$NAMESPACE" ]]; then
        # Fallback: namespace по лейблу
        NAMESPACE=$(kubectl get ns -l "app.kubernetes.io/name=elma365" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi

    if [[ -z "$NAMESPACE" ]]; then
        read -rp "Namespace ELMA365 не найден автоматически. Введи namespace: " NAMESPACE
        [[ -z "$NAMESPACE" ]] && { echo "Namespace не указан"; exit 1; }
    fi
    log "Namespace: $NAMESPACE"
}

read_dsn() {
    local key="$1"
    kubectl get secret "$DB_SECRET" -n "$NAMESPACE" \
        -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d 2>/dev/null || echo ""
}

# Ищем под с доступом к psql или python3+psycopg2
pg_query() {
    local dsn="$1"
    local sql="$2"
    local pod

    pod=$(kubectl get pods -n "$NAMESPACE" -l "tier=elma365" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$pod" ]]; then
        echo "null"
        return
    fi

    if kubectl exec "$pod" -n "$NAMESPACE" -- which psql &>/dev/null 2>&1; then
        kubectl exec "$pod" -n "$NAMESPACE" -- \
            psql "$dsn" -t -A -F',' -c "$sql" 2>/dev/null || echo ""
    elif kubectl exec "$pod" -n "$NAMESPACE" -- which python3 &>/dev/null 2>&1; then
        kubectl exec "$pod" -n "$NAMESPACE" -- python3 -c "
import sys
try:
    import psycopg2, json
    conn = psycopg2.connect('$dsn')
    cur = conn.cursor()
    cur.execute('''$sql''')
    cols = [d[0] for d in cur.description] if cur.description else []
    rows = [dict(zip(cols, r)) for r in (cur.fetchall() or [])]
    print(json.dumps(rows))
except Exception as e:
    print(json.dumps({'error': str(e)}))
" 2>/dev/null || echo "[]"
    else
        echo "[]"
    fi
}

check_cert() {
    local host="$1"
    local port="${2:-443}"
    local result

    result=$(echo | timeout 5 openssl s_client -connect "$host:$port" \
        -servername "$host" 2>/dev/null | openssl x509 -noout \
        -enddate -issuer -subject 2>/dev/null || echo "")

    if [[ -z "$result" ]]; then
        echo "{\"host\":\"$host\",\"port\":$port,\"error\":\"недоступен\"}"
        return
    fi

    local end_date issuer subject days_left
    end_date=$(echo "$result" | grep notAfter | cut -d= -f2-)
    issuer=$(echo "$result"   | grep issuer  | head -1 | cut -d= -f2-)
    subject=$(echo "$result"  | grep subject | head -1 | cut -d= -f2-)

    if [[ -n "$end_date" ]]; then
        days_left=$(( ( $(date -d "$end_date" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$end_date" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    else
        days_left=-1
    fi

    local status="ok"
    [[ $days_left -lt 30 ]] && status="warn"
    [[ $days_left -lt 7  ]] && status="critical"
    [[ $days_left -le 0  ]] && status="expired"

    jq -n \
        --arg host "$host" \
        --argjson port "$port" \
        --arg end_date "$end_date" \
        --argjson days_left "$days_left" \
        --arg issuer "$issuer" \
        --arg subject "$subject" \
        --arg status "$status" \
        '{host:$host,port:$port,expires:$end_date,days_left:$days_left,issuer:$issuer,subject:$subject,status:$status}'
}

check_tcp() {
    local host="$1"
    local port="$2"
    local name="${3:-$host:$port}"

    if timeout 3 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        echo "{\"name\":\"$name\",\"host\":\"$host\",\"port\":$port,\"reachable\":true}"
    else
        echo "{\"name\":\"$name\",\"host\":\"$host\",\"port\":$port,\"reachable\":false}"
    fi
}

dsn_host() {
    echo "$1" | sed -E 's|.*@([^:/]+).*|\1|'
}

dsn_port() {
    local port
    port=$(echo "$1" | sed -E 's|.*:([0-9]+)/.*|\1|')
    [[ "$port" =~ ^[0-9]+$ ]] && echo "$port" || echo ""
}

collect_machine_specs() {
    local node_name
    node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$node_name" ]]; then
        echo "null"
        return
    fi

    local cpu ram
    cpu=$(kubectl get node "$node_name" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null || echo "0")
    ram=$(kubectl get node "$node_name" -o jsonpath='{.status.capacity.memory}' 2>/dev/null || echo "0Ki")

    local ram_gb
    ram_gb=$(echo "$ram" | sed 's/Ki//' | awk '{printf "%.1f", $1/1024/1024}')

    jq -n --arg cpu "$cpu" --arg ram_gb "$ram_gb" --arg ram_raw "$ram" \
        '{cpu_cores:($cpu|tonumber),ram_gb:($ram_gb|tonumber),ram_raw:$ram_raw}'
}

collect_postgres() {
    local dsn="$1"
    local name="$2"
    log "PostgreSQL [$name]..."

    local connections version db_size slow_queries locks bloat pg_config

    version=$(pg_query "$dsn" "SELECT version()" 2>/dev/null | head -1 || echo "")

    connections=$(pg_query "$dsn" "
        SELECT state, count(*) as cnt
        FROM pg_stat_activity
        GROUP BY state
        ORDER BY cnt DESC" 2>/dev/null || echo "[]")

    db_size=$(pg_query "$dsn" \
        "SELECT pg_size_pretty(pg_database_size(current_database()))" \
        2>/dev/null | head -1 || echo "")

    slow_queries=$(pg_query "$dsn" "
        SELECT pid, state,
               EXTRACT(EPOCH FROM (now()-query_start))::int as duration_sec,
               LEFT(query,200) as query,
               wait_event_type, wait_event
        FROM pg_stat_activity
        WHERE state != 'idle'
          AND query_start IS NOT NULL
          AND EXTRACT(EPOCH FROM (now()-query_start)) > 5
          AND pid != pg_backend_pid()
        ORDER BY duration_sec DESC
        LIMIT 20" 2>/dev/null || echo "[]")

    locks=$(pg_query "$dsn" "
        SELECT bl.pid, ba.query as blocked_query,
               kl.pid as blocking_pid, ka.query as blocking_query
        FROM pg_catalog.pg_locks bl
        JOIN pg_catalog.pg_stat_activity ba ON bl.pid = ba.pid
        JOIN pg_catalog.pg_locks kl
             ON kl.transactionid = bl.transactionid AND kl.pid != bl.pid
        JOIN pg_catalog.pg_stat_activity ka ON kl.pid = ka.pid
        WHERE NOT bl.granted
        LIMIT 10" 2>/dev/null || echo "[]")

    bloat=$(pg_query "$dsn" "
        SELECT relname, n_dead_tup, n_live_tup,
               CASE WHEN n_live_tup+n_dead_tup=0 THEN 0
                    ELSE ROUND(100.0*n_dead_tup/(n_live_tup+n_dead_tup),1)
               END as bloat_pct,
               last_vacuum, last_autovacuum
        FROM pg_stat_user_tables
        WHERE n_dead_tup > 1000
        ORDER BY n_dead_tup DESC
        LIMIT 15" 2>/dev/null || echo "[]")

    pg_config=$(pg_query "$dsn" "
        SELECT name, setting, unit, short_desc
        FROM pg_settings
        WHERE name IN (
            'shared_buffers','work_mem','maintenance_work_mem',
            'effective_cache_size','max_connections','wal_level',
            'checkpoint_completion_target','random_page_cost',
            'max_worker_processes','max_parallel_workers',
            'log_min_duration_statement','autovacuum',
            'autovacuum_vacuum_cost_delay'
        )
        ORDER BY name" 2>/dev/null || echo "[]")

    # pg_stat_statements может отсутствовать — проверяем перед запросом
    local stat_stmts="[]"
    local has_stmts
    has_stmts=$(pg_query "$dsn" \
        "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_stat_statements')" \
        2>/dev/null | tr -d ',' || echo "f")

    local service_load="[]"
    service_load=$(pg_query "$dsn" "
        SELECT
            COALESCE(NULLIF(application_name,''), 'unknown') as service,
            count(*) as total_connections,
            count(*) FILTER (WHERE state='active') as active,
            count(*) FILTER (WHERE state='idle') as idle,
            count(*) FILTER (WHERE wait_event_type='Lock') as waiting,
            COALESCE(MAX(EXTRACT(EPOCH FROM (now()-query_start))::int)
                FILTER (WHERE state='active'), 0) as max_query_sec
        FROM pg_stat_activity
        WHERE pid != pg_backend_pid()
        GROUP BY application_name
        ORDER BY total_connections DESC
        LIMIT 20" 2>/dev/null || echo "[]")

    if [[ "$has_stmts" == "t" ]]; then
        stat_stmts=$(pg_query "$dsn" "
            SELECT
                LEFT(s.query,300) as query,
                s.calls,
                ROUND(s.mean_exec_time::numeric,2) as mean_ms,
                ROUND(s.total_exec_time::numeric,2) as total_ms,
                ROUND(s.max_exec_time::numeric,2) as max_ms,
                COALESCE((
                    SELECT application_name
                    FROM pg_stat_activity a
                    WHERE a.query = s.query
                    LIMIT 1
                ), '') as service
            FROM pg_stat_statements s
            WHERE s.query NOT LIKE '%pg_stat%'
              AND s.calls > 3
            ORDER BY s.total_exec_time DESC
            LIMIT 20" 2>/dev/null || echo "[]")
    fi

    jq -n \
        --arg name "$name" \
        --arg version "$version" \
        --arg db_size "$db_size" \
        --arg connections "$connections" \
        --arg slow_queries "$slow_queries" \
        --arg locks "$locks" \
        --arg bloat "$bloat" \
        --arg pg_config "$pg_config" \
        --arg stat_stmts "$stat_stmts" \
        --arg service_load "$service_load" \
        --argjson has_stmts "$([ "$has_stmts" = "t" ] && echo true || echo false)" \
        '{
            name: $name,
            version: $version,
            db_size: $db_size,
            has_pg_stat_statements: $has_stmts,
            connections: ($connections | try(fromjson) // []),
            service_load: ($service_load | try(fromjson) // []),
            slow_queries: ($slow_queries | try(fromjson) // []),
            locks: ($locks | try(fromjson) // []),
            bloat_tables: ($bloat | try(fromjson) // []),
            config: ($pg_config | try(fromjson) // []),
            top_queries: ($stat_stmts | try(fromjson) // [])
        }'
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
            name: $pod_name,
            phase: .status.phase,
            ready: ([ .status.containerStatuses[]?.ready ] | all),
            restarts: ([.status.containerStatuses[]?.restartCount] | add // 0),
            node: .spec.nodeName,
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

    local events
    events=$(kubectl get events -n "$NAMESPACE" \
        --field-selector=type=Warning \
        --sort-by='.metadata.creationTimestamp' \
        -o json 2>/dev/null \
        | jq '[.items[] | {
            reason: .reason,
            message: .message,
            object: .involvedObject.name,
            kind: .involvedObject.kind,
            count: .count,
            last_seen: .lastTimestamp
        }]' 2>/dev/null || echo "[]")

    local hpa
    hpa=$(kubectl get hpa -n "$NAMESPACE" -o json 2>/dev/null \
        | jq '[.items[] | {
            name: .metadata.name,
            target: .spec.scaleTargetRef.name,
            min: (.spec.minReplicas // 1),
            max: .spec.maxReplicas,
            current: .status.currentReplicas,
            desired: .status.desiredReplicas
        }]' 2>/dev/null || echo "[]")

    local nodes
    nodes=$(kubectl get nodes -o json 2>/dev/null \
        | jq '[.items[] | {
            name: .metadata.name,
            ready: ([ .status.conditions[] | select(.type=="Ready") | .status=="True" ] | any),
            cpu: .status.capacity.cpu,
            memory: .status.capacity.memory,
            version: .status.nodeInfo.kubeletVersion
        }]' 2>/dev/null || echo "[]")

    local helm_history
    helm_history=$(helm history elma365 -n "$NAMESPACE" \
        --output json 2>/dev/null || echo "[]")

    local migration
    local deploy_pod
    deploy_pod=$(kubectl get pods -n "$NAMESPACE" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' \
        -l app=deploy 2>/dev/null || echo "")

    migration=""
    if [[ -n "$deploy_pod" ]]; then
        local elma_version=""
        elma_version=$(kubectl get configmap -n "$NAMESPACE" \
            -o json 2>/dev/null \
            | jq -r '.items[] | select(.data.version?) | .data.version' \
            2>/dev/null | head -1 || echo "")

        # >= 2025.7: deploy не слушает localhost, нужен отдельный curl-pod
        # < 2025.7:  exec напрямую в deploy
        local migr_url="http://localhost:3000/migration/states"
        local migr_url_old="http://localhost:3000/migration/state"

        if [[ "$elma_version" > "2025.6" && -n "$elma_version" ]]; then
            migration=$(kubectl run curl-migration-diag \
                -n "$NAMESPACE" \
                --image=curlimages/curl:8.2.1 \
                --rm --restart=Never --quiet \
                -- curl -sf -m 10 \
                -H "Accept: application/json" \
                http://deploy:3000/migration/states 2>/dev/null \
                || echo "unavailable")
        else
            migration=$(kubectl exec "$deploy_pod" -n "$NAMESPACE" \
                -c deploy -- curl -sf -m 10 \
                -H "Accept: application/json" \
                "$migr_url" 2>/dev/null \
                || kubectl exec "$deploy_pod" -n "$NAMESPACE" \
                -c deploy -- curl -sf -m 10 \
                -H "Accept: application/json" \
                "$migr_url_old" 2>/dev/null \
                || echo "unavailable")
        fi
    fi

    local istio_data="null"
    if kubectl get ns istio-system &>/dev/null 2>&1; then
        local istiod_ready="false"
        local istio_version=""
        local sidecar_count=0

        istiod_pod=$(kubectl get pods -n istio-system -l app=istiod \
            --field-selector=status.phase=Running \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        [[ -n "$istiod_pod" ]] && istiod_ready="true"

        istio_version=$(kubectl get pods -n istio-system -l app=istiod \
            -o jsonpath='{.items[0].metadata.labels.istio\.io/rev}' 2>/dev/null || echo "")

        sidecar_count=$(kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null \
            | jq '[.items[] | select(.spec.containers[]?.name == "istio-proxy")] | length' 2>/dev/null || echo "0")

        istio_data=$(jq -n \
            --argjson installed true \
            --argjson istiod_ready "$istiod_ready" \
            --arg version "$istio_version" \
            --argjson sidecar_count "$sidecar_count" \
            '{installed:$installed,istiod_ready:$istiod_ready,version:$version,sidecar_injected_pods:$sidecar_count}')
    fi

    jq -n \
        --argjson pods "$pods" \
        --argjson events "$events" \
        --argjson hpa "$hpa" \
        --argjson nodes "$nodes" \
        --argjson helm "$helm_history" \
        --arg migration "$migration" \
        --arg namespace "$NAMESPACE" \
        --argjson istio "$istio_data" \
        '{
            namespace: $namespace,
            pods: $pods,
            events: $events,
            hpas: $hpa,
            nodes: $nodes,
            helm_history: $helm,
            migration_state: $migration,
            istio: $istio
        }'
}

collect_logs() {
    log "Логи сервисов (error/fatal)..."
    local result="{}"

    # Фильтрация error/fatal по label tier=elma365 — идентично старому скрипту
    local tmp_err
    tmp_err=$(mktemp)
    kubectl logs -n "$NAMESPACE" \
        -l tier=elma365 --all-containers \
        --tail=500 2>/dev/null \
        | grep -E '"level":"(fatal|error)"|"(fatal|error)"|level=(fatal|error)| ERROR | FATAL ' \
        | tail -300 > "$tmp_err" || true
    result=$(echo "$result" | jq \
        --rawfile v "$tmp_err" \
        '. + {"__elma_errors": $v}')
    rm -f "$tmp_err"

    # Последние 100 строк каждого пода для быстрого просмотра в HTML
    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    for pod in $pods; do
        local tmp_log
        tmp_log=$(mktemp)
        kubectl logs "$pod" -n "$NAMESPACE" \
            --tail=100 2>/dev/null > "$tmp_log" || true

        if [[ -s "$tmp_log" ]]; then
            result=$(echo "$result" | jq \
                --arg pod "$pod" \
                --rawfile logs "$tmp_log" \
                '. + {($pod): $logs}')
        fi
        rm -f "$tmp_log"
    done

    echo "$result"
}

collect_certs() {
    log "Сертификаты..."

    local certs="[]"

    local ingress_host
    ingress_host=$(kubectl get ingress -n "$NAMESPACE" \
        -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "")

    if [[ -n "$ingress_host" ]]; then
        local cert_info
        cert_info=$(check_cert "$ingress_host" 443)
        certs=$(echo "$certs" | jq --argjson c "$cert_info" '. + [$c]')
    fi

    local k8s_certs
    k8s_certs=$(kubectl get secret -n "$NAMESPACE" \
        -o json 2>/dev/null \
        | jq -r '.items[] | select(.type=="kubernetes.io/tls") |
            "\(.metadata.name) \(.data["tls.crt"] // "")"' \
        2>/dev/null || echo "")

    while IFS=' ' read -r secret_name cert_b64; do
        [[ -z "$cert_b64" ]] && continue
        local cert_data expiry days_left
        cert_data=$(echo "$cert_b64" | base64 -d 2>/dev/null | \
            openssl x509 -noout -enddate -subject 2>/dev/null || echo "")
        if [[ -n "$cert_data" ]]; then
            expiry=$(echo "$cert_data" | grep notAfter | cut -d= -f2-)
            days_left=$(( ( $(date -d "$expiry" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
            local status="ok"
            [[ $days_left -lt 30 ]] && status="warn"
            [[ $days_left -lt 7  ]] && status="critical"
            certs=$(echo "$certs" | jq \
                --arg name "$secret_name" \
                --arg expiry "$expiry" \
                --argjson days "$days_left" \
                --arg status "$status" \
                '. + [{source:"k8s-secret",name:$name,expires:$expiry,days_left:$days,status:$status}]')
        fi
    done <<< "$k8s_certs"

    local mongo_dsn
    mongo_dsn=$(read_dsn "MONGO_URL")
    if [[ "$mongo_dsn" == *"ssl=true"* ]] || [[ "$mongo_dsn" == *"tls=true"* ]]; then
        local mongo_host
        mongo_host=$(dsn_host "$mongo_dsn")
        local mongo_port
        mongo_port=$(dsn_port "$mongo_dsn")
        local cert_info
        cert_info=$(check_cert "$mongo_host" "${mongo_port:-27017}")
        certs=$(echo "$certs" | jq \
            --argjson c "$cert_info" \
            '. + [$c | . + {source:"mongodb"}]')
    fi

    echo "$certs"
}

_pod_logs() {
    local label="$1"
    local pod logs=""
    pod=$(kubectl get pods -n "$NAMESPACE" -l "app=$label" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    [[ -n "$pod" ]] && logs=$(kubectl logs "$pod" -n "$NAMESPACE" \
        --tail=200 2>/dev/null | grep -v '^$' | tail -100 || echo "")
    jq -n --arg pod "$pod" --arg logs "$logs" '{pod:$pod,logs:$logs}'
}

collect_auth() {
    log "Auth endpoints..."

    # Данные подов пишем в temp-файлы — обход лимита ARG_MAX
    local _t_auth _t_vahter _t_hydra
    _t_auth=$(mktemp);   _pod_logs "auth"          > "$_t_auth"
    _t_vahter=$(mktemp); _pod_logs "vahter"         > "$_t_vahter"
    _t_hydra=$(mktemp);  _pod_logs "hydra-adaptor"  > "$_t_hydra"

    local appconfig
    appconfig=$(kubectl get configmap -n "$NAMESPACE" \
        -o json 2>/dev/null \
        | jq -r '.items[] | select(.data.appconfig?) | .data.appconfig' \
        2>/dev/null | head -1 || echo "")

    local auth_endpoints=("ldap" "keycloak" "saml" "ad" "oidc")
    local connectivity="{}"

    for keyword in "${auth_endpoints[@]}"; do
        local url
        url=$(echo "$appconfig" | grep -iE "$keyword.*http" | \
            grep -oE 'https?://[^"]+' | head -1 || echo "")
        if [[ -n "$url" ]]; then
            local host port status_code
            host=$(echo "$url" | sed -E 's|https?://([^/:]+).*|\1|')
            port=$(echo "$url" | grep -oE ':[0-9]+' | tr -d ':' | head -1)
            port="${port:-443}"
            status_code=$(curl -sk -o /dev/null -w "%{http_code}" \
                --max-time 5 "$url" 2>/dev/null || echo "000")
            connectivity=$(echo "$connectivity" | jq \
                --arg kw "$keyword" \
                --arg url "$url" \
                --arg code "$status_code" \
                --argjson reachable "$([ "$status_code" != "000" ] && echo true || echo false)" \
                '. + {($kw): {url:$url, http_code:$code, reachable:$reachable}}')
        fi
    done

    jq -n \
        --slurpfile auth   "$_t_auth" \
        --slurpfile vahter "$_t_vahter" \
        --slurpfile hydra  "$_t_hydra" \
        --argjson conn     "$connectivity" \
        '{
            auth:          $auth[0],
            vahter:        $vahter[0],
            hydra_adaptor: $hydra[0],
            connectivity:  $conn
        }'

    rm -f "$_t_auth" "$_t_vahter" "$_t_hydra"
}

collect_rabbitmq() {
    local amqp_dsn="$1"
    log "RabbitMQ..."

    # amqp://user:pass@host:5672/vhost → http://user:pass@host:15672/api
    local user pass host
    user=$(echo "$amqp_dsn" | sed -E 's|amqp://([^:]+):.*|\1|')
    pass=$(echo "$amqp_dsn" | sed -E 's|amqp://[^:]+:([^@]+)@.*|\1|')
    host=$(echo "$amqp_dsn" | sed -E 's|amqp://[^@]+@([^:/]+).*|\1|')
    local mgmt_url="http://${user}:${pass}@${host}:15672/api"

    local queues overview
    queues=$(curl -sf --max-time 10 "$mgmt_url/queues" 2>/dev/null \
        | jq '[.[] | {
            name: .name,
            vhost: .vhost,
            messages: .messages,
            messages_ready: .messages_ready,
            messages_unacked: .messages_unacknowledged,
            consumers: .consumers,
            state: .state
        }]' 2>/dev/null || echo "[]")

    overview=$(curl -sf --max-time 10 "$mgmt_url/overview" 2>/dev/null \
        | jq '{
            version: .rabbitmq_version,
            nodes: .object_totals.queues,
            messages_total: .queue_totals.messages
        }' 2>/dev/null || echo "{}")

    jq -n \
        --argjson queues "$queues" \
        --argjson overview "$overview" \
        '{queues: $queues, overview: $overview}'
}

collect_redis() {
    local dsn="$1"
    log "Redis..."

    local host port password
    host=$(echo "$dsn" | sed -E 's|redis://[^@]*@([^:/]+).*|\1|; s|redis://([^:/]+).*|\1|')
    port=$(echo "$dsn" | sed -E 's|.*:([0-9]+)/.*|\1|; s|.*:([0-9]+)$|\1|')
    password=$(echo "$dsn" | sed -E 's|redis://[^:]*:([^@]+)@.*|\1|')
    [[ "$port" =~ ^[0-9]+$ ]] || port="6379"
    [[ "$password" == "$dsn" ]] && password=""

    local pod
    pod=$(kubectl get pods -n "$NAMESPACE" \
        -l tier=elma365 \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$pod" ]]; then
        echo '{"error": "pod not found"}'
        return
    fi

    local info=""
    if kubectl exec "$pod" -n "$NAMESPACE" -- which redis-cli &>/dev/null 2>&1; then
        local redis_args=(-h "$host" -p "$port")
        [[ -n "$password" ]] && redis_args+=(-a "$password")
        info=$(kubectl exec "$pod" -n "$NAMESPACE" -- \
            redis-cli "${redis_args[@]}" INFO all 2>/dev/null || echo "")
        if [[ -n "$info" ]]; then
            info=$(echo "$info" | awk -F: '/^[^#]/{gsub(/\r/,""); if(NF==2) printf "\"%s\":\"%s\",", $1, $2}' \
                | sed 's/,$//' | sed 's/^/{/; s/$/}/')
        fi
    fi
    [[ -z "$info" || "$info" == "{}" ]] && info='{"error":"redis-cli not available in pod"}'
    echo "$info"
}

pg_tune_recommendations() {
    local pg_config="$1"
    local machine_specs="$2"

    local ram_gb
    ram_gb=$(echo "$machine_specs" | jq -r '.ram_gb // 4' 2>/dev/null || echo "4")
    local cpu
    cpu=$(echo "$machine_specs" | jq -r '.cpu_cores // 2' 2>/dev/null || echo "2")

    local shared_buffers_mb work_mem_mb maintenance_work_mem_mb effective_cache_size_mb
    shared_buffers_mb=$(awk "BEGIN {printf \"%d\", $ram_gb * 1024 * 0.25}")
    effective_cache_size_mb=$(awk "BEGIN {printf \"%d\", $ram_gb * 1024 * 0.75}")
    maintenance_work_mem_mb=$(awk "BEGIN {printf \"%d\", $ram_gb * 1024 * 0.0625}")
    local max_conn
    max_conn=$(echo "$pg_config" | jq -r '.[] | select(.name=="max_connections") | .setting' 2>/dev/null)
    [[ -z "$max_conn" || ! "$max_conn" =~ ^[0-9]+$ ]] && max_conn=100
    work_mem_mb=$(awk "BEGIN {printf \"%d\", ($ram_gb * 1024 * 0.75 - $shared_buffers_mb) / ($max_conn * 2)}")
    [[ $work_mem_mb -lt 4 ]] && work_mem_mb=4

    jq -n \
        --argjson shared_buffers_mb "$shared_buffers_mb" \
        --argjson work_mem_mb "$work_mem_mb" \
        --argjson maintenance_work_mem_mb "$maintenance_work_mem_mb" \
        --argjson effective_cache_size_mb "$effective_cache_size_mb" \
        --argjson ram_gb "$ram_gb" \
        --argjson cpu "$cpu" \
        '{
            based_on: {ram_gb: $ram_gb, cpu_cores: $cpu},
            recommended: {
                shared_buffers: "\($shared_buffers_mb)MB",
                work_mem: "\($work_mem_mb)MB",
                maintenance_work_mem: "\($maintenance_work_mem_mb)MB",
                effective_cache_size: "\($effective_cache_size_mb)MB",
                max_worker_processes: $cpu,
                max_parallel_workers: $cpu
            },
            note: "Рассчитано по формулам PGTune для OLTP нагрузки"
        }'
}

collect_s3() {
    local s3_config="$1"
    local endpoint bucket key secret ssl

    endpoint=$(echo "$s3_config" | jq -r '.backend.address // ""' 2>/dev/null)
    bucket=$(echo "$s3_config"   | jq -r '.bucket // ""' 2>/dev/null)
    key=$(echo "$s3_config"      | jq -r '.accesskeyid // ""' 2>/dev/null)
    secret=$(echo "$s3_config"   | jq -r '.secretaccesskey // ""' 2>/dev/null)
    ssl=$(echo "$s3_config"      | jq -r '.ssl.enabled // "false"' 2>/dev/null)

    [[ -z "$endpoint" || -z "$bucket" ]] && echo "null" && return

    local scheme="http"
    [[ "$ssl" == "true" ]] && scheme="https"

    local host port
    host=$(echo "$endpoint" | sed -E 's|:[0-9]+||')
    port=$(echo "$endpoint" | grep -oE ':[0-9]+' | tr -d ':' || echo "443")
    [[ "$ssl" != "true" ]] && port="9000"

    if ! timeout 3 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        jq -n --arg bucket "$bucket" --arg endpoint "$endpoint" \
            '{bucket:$bucket,endpoint:$endpoint,accessible:false,error:"endpoint недоступен"}'
        return
    fi

    jq -n --arg bucket "$bucket" --arg endpoint "$endpoint" \
        '{bucket:$bucket,endpoint:$endpoint,accessible:true,note:"Детальная проверка через сервис"}'
}

collect_mongo() {
    local mongo_url="$1"
    log "MongoDB..."

    local mongo_pod
    mongo_pod=$(kubectl get pods -n "$NAMESPACE" \
        -l tier=elma365 \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$mongo_pod" ]]; then
        echo '{"error":"pod not found"}'
        return
    fi

    local mongo_js='JSON.stringify({
        connections: db.adminCommand({serverStatus:1}).connections,
        opcounters: db.adminCommand({serverStatus:1}).opcounters,
        repl_set: (function(){ try{ return rs.status().set; }catch(e){ return ""; } })(),
        repl_members: (function(){ try{ return rs.status().members.length; }catch(e){ return 0; } })()
    })'

    if kubectl exec "$mongo_pod" -n "$NAMESPACE" -- which mongosh &>/dev/null 2>&1; then
        kubectl exec "$mongo_pod" -n "$NAMESPACE" -- \
            mongosh "$mongo_url" --quiet --eval "$mongo_js" 2>/dev/null \
            || echo '{"error":"mongosh failed"}'
    elif kubectl exec "$mongo_pod" -n "$NAMESPACE" -- which mongo &>/dev/null 2>&1; then
        kubectl exec "$mongo_pod" -n "$NAMESPACE" -- \
            mongo "$mongo_url" --quiet --eval "$mongo_js" 2>/dev/null \
            || echo '{"error":"mongo failed"}'
    else
        echo '{"error":"mongosh/mongo not available in pod"}'
    fi
}

generate_html_report() {
    local json_gz="$1"
    local html_file="${json_gz%.json.gz}.html"
    local json_data
    # Экранируем </script> внутри JSON чтобы не сломать HTML-парсер браузера
    json_data=$(gzip -cd "$json_gz" | sed 's|</script>|<\\/script>|g')

    # Часть 1: HTML-шапка + встроенный CSS
    cat > "$html_file" << 'HTML_HEAD'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ELMA365 Diagnostics</title>
<style>
/* Reset & Base */
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
:root {
  --bg:        #0f1117;
  --bg2:       #161b22;
  --bg3:       #1c2128;
  --border:    #30363d;
  --text:      #e1e4e8;
  --muted:     #8b949e;
  --blue:      #58a6ff;
  --green:     #3fb950;
  --yellow:    #d29922;
  --red:       #f85149;
  --orange:    #e3b341;
  --sidebar-w: 220px;
  --header-h:  52px;
}
html, body { height: 100%; font-family: 'Segoe UI', system-ui, sans-serif; background: var(--bg); color: var(--text); font-size: 14px; }

/* Layout */
#app    { display: flex; flex-direction: column; height: 100vh; }
#header { height: var(--header-h); background: var(--bg2); border-bottom: 1px solid var(--border); display: flex; align-items: center; padding: 0 20px; gap: 16px; flex-shrink: 0; z-index: 10; }
#body   { display: flex; flex: 1; overflow: hidden; }
#sidebar{ width: var(--sidebar-w); background: var(--bg2); border-right: 1px solid var(--border); display: flex; flex-direction: column; flex-shrink: 0; overflow-y: auto; }
#main   { flex: 1; overflow-y: auto; padding: 24px; }

/* Header */
#header .logo     { font-size: 16px; font-weight: 700; color: var(--blue); letter-spacing: .5px; }
#header .logo span{ color: var(--muted); font-weight: 400; }
#header .spacer   { flex: 1; }

/* Sidebar / TOC */
.nav-section { padding: 16px 12px 6px; font-size: 11px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: .8px; }
.nav-item, .toc-link {
  display: flex; align-items: center; gap: 10px; padding: 8px 16px;
  cursor: pointer; color: var(--muted); border-left: 3px solid transparent;
  transition: all .15s; font-size: 13px; text-decoration: none;
}
.nav-item:hover, .toc-link:hover { background: var(--bg3); color: var(--text); }
.nav-item.active { background: var(--bg3); color: var(--blue); border-left-color: var(--blue); }
.nav-item .icon  { width: 16px; text-align: center; }
.nav-badge { margin-left: auto; background: var(--red); color: #fff; border-radius: 10px; padding: 1px 7px; font-size: 11px; }
.nav-hint  { display: block; font-size: 10px; color: var(--muted); margin-top: 1px; opacity: 0.7; }

/* Report page layout */
.rp-header {
  display: flex; align-items: center; flex-wrap: wrap; gap: 12px;
  padding: 16px 20px; background: var(--bg2); border: 1px solid var(--border);
  border-radius: 8px; margin-bottom: 8px;
}
.rp-title { font-size: 16px; font-weight: 700; color: var(--blue); }
.rp-meta  { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }

/* Sections */
.report-section {
  border-top: 2px solid var(--border);
  padding: 28px 0 8px;
  margin-bottom: 8px;
  scroll-margin-top: 16px;
}
.section-title {
  font-size: 20px; font-weight: 700; margin-bottom: 20px;
  color: var(--text); letter-spacing: -.3px;
  padding-bottom: 8px; border-bottom: 1px solid var(--border);
}
.sub-title    { font-size: 15px; font-weight: 600; margin: 20px 0 10px; color: var(--text); }
.sub-title-sm { font-size: 13px; font-weight: 600; margin: 16px 0 8px; color: var(--muted); text-transform: uppercase; letter-spacing: .4px; }
.section-hint { font-size: 12px; color: var(--muted); margin-bottom: 10px; line-height: 1.5; }
.warn-title   { color: var(--yellow); }

/* Stat row */
.stat-row { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 20px; }
.stat-box {
  background: var(--bg2); border: 1px solid var(--border); border-radius: 8px;
  padding: 14px 18px; min-width: 130px; flex: 1;
}
.stat-val  { font-size: 28px; font-weight: 700; line-height: 1; color: var(--text); }
.stat-key  { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .4px; margin-top: 5px; }
.stat-sub  { font-size: 11px; color: var(--muted); margin-top: 3px; }
.stat-box.ok   .stat-val { color: var(--green); }
.stat-box.warn .stat-val { color: var(--yellow); }
.stat-box.err  .stat-val { color: var(--red); }

/* Summary cards */
.summary-cards { display: flex; gap: 16px; margin-bottom: 20px; flex-wrap: wrap; }
.sum-card {
  flex: 1; min-width: 140px; background: var(--bg2);
  border: 1px solid var(--border); border-radius: 8px; padding: 20px;
  text-align: center;
}
.sum-num   { font-size: 42px; font-weight: 700; line-height: 1; }
.sum-label { font-size: 12px; color: var(--muted); margin-top: 6px; }
.sum-card.ok   .sum-num { color: var(--green); }
.sum-card.warn .sum-num { color: var(--yellow); }
.sum-card.err  .sum-num { color: var(--red); }

/* Issue list */
.issue-list   { margin-bottom: 16px; }
.issue-row    { display: flex; align-items: flex-start; gap: 10px; padding: 9px 14px; background: var(--bg2); border-radius: 6px; margin-bottom: 4px; font-size: 13px; }
.issue-dot    { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; margin-top: 4px; }
.issue-dot.err  { background: var(--red); box-shadow: 0 0 6px var(--red); }
.issue-dot.warn { background: var(--yellow); }
.ok-banner    { background: #1a2e1a; border: 1px solid var(--green); border-radius: 6px; padding: 12px 16px; color: var(--green); font-size: 13px; }

/* Table */
.tbl-wrap { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; margin-bottom: 16px; }
table    { width: 100%; border-collapse: collapse; font-size: 13px; }
thead th { background: var(--bg3); padding: 9px 14px; text-align: left; font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .5px; font-weight: 600; border-bottom: 1px solid var(--border); }
tbody td { padding: 9px 14px; border-bottom: 1px solid var(--bg3); vertical-align: middle; }
tbody tr:last-child td { border-bottom: none; }
tbody tr:hover td { background: var(--bg3); }

/* Status dots */
.dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; flex-shrink: 0; }
.dot.ok   { background: var(--green); box-shadow: 0 0 6px var(--green); }
.dot.err  { background: var(--red);   box-shadow: 0 0 6px var(--red); }
.dot.warn { background: var(--yellow); }

/* Tags / Badges */
.tag     { display: inline-block; background: var(--bg3); border: 1px solid var(--border); border-radius: 4px; padding: 1px 7px; font-size: 11px; margin: 1px; color: var(--muted); }
.err-tag { background: #2e1515; border-color: var(--red);    color: var(--red); }
.ok-tag  { background: #1a2e1a; border-color: var(--green);  color: var(--green); }
.badge   { display: inline-flex; align-items: center; gap: 5px; border-radius: 12px; padding: 3px 10px; font-size: 12px; font-weight: 500; }
.badge.ok       { background: #1a2e1a; color: var(--green); }
.badge.degraded { background: #2e2307; color: var(--yellow); }
.badge.critical { background: #2e1515; color: var(--red); }
.badge.warn     { background: #2e2307; color: var(--yellow); }

/* Buttons */
.btn { display: inline-flex; align-items: center; gap: 6px; border: none; border-radius: 6px; padding: 6px 14px; font-size: 13px; cursor: pointer; transition: all .15s; font-family: inherit; }
.btn-primary   { background: var(--blue); color: #0d1117; }
.btn-primary:hover { background: #79bdff; }
.btn-secondary { background: var(--bg3); color: var(--text); border: 1px solid var(--border); }
.btn-secondary:hover { background: var(--border); }
.btn-sm { padding: 4px 10px; font-size: 12px; }

/* Metric bar */
.metric-bar { height: 5px; background: var(--bg3); border-radius: 3px; overflow: hidden; margin-top: 8px; }
.metric-bar .fill { height: 100%; border-radius: 3px; }
.fill.ok   { background: var(--green); }
.fill.warn { background: var(--yellow); }
.fill.err  { background: var(--red); }

/* Collapsible */
.collapsible { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; margin-bottom: 10px; overflow: hidden; }
.collapsible summary {
  padding: 10px 16px; cursor: pointer; font-size: 13px; font-weight: 500;
  list-style: none; display: flex; align-items: center; gap: 8px;
  user-select: none;
}
.collapsible summary::-webkit-details-marker { display: none; }
.collapsible summary::before { content: '▶'; font-size: 10px; color: var(--muted); transition: transform .2s; }
.collapsible[open] summary::before { transform: rotate(90deg); }
.collapsible summary:hover { background: var(--bg3); }
.collapsible > *:not(summary) { padding: 0 16px 16px; }

/* Auth grid */
.auth-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px; margin-top: 12px; }
@media(max-width:1100px) { .auth-grid { grid-template-columns: 1fr 1fr; } }
@media(max-width:700px)  { .auth-grid { grid-template-columns: 1fr; } }
.auth-card { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
.auth-header { display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-bottom: 1px solid var(--border); background: var(--bg3); }
.auth-name   { font-weight: 600; font-size: 14px; }
.auth-hint   { font-size: 11px; color: var(--muted); padding: 6px 12px 4px; }

/* Log box */
.log-box { background: #0d1117; padding: 10px 12px; max-height: 350px; overflow-y: auto; font-family: monospace; font-size: 11px; line-height: 1.5; }
.log-line  { padding: 1px 0; }
.log-error { color: var(--red); }
.log-warn  { color: var(--yellow); }
.log-debug { color: var(--muted); }

/* Tip box */
.tip-box { background: var(--bg2); border-left: 3px solid var(--blue); border-radius: 0 6px 6px 0; padding: 10px 14px; font-size: 13px; color: var(--muted); margin-bottom: 12px; line-height: 1.6; }
.tip-box.warn { border-left-color: var(--yellow); }
.tip-box code { background: var(--bg3); padding: 1px 5px; border-radius: 3px; }

/* Code */
code { font-family: 'JetBrains Mono', monospace; background: var(--bg3); padding: 1px 5px; border-radius: 3px; font-size: 12px; }

/* Upload page */
.section-header { display: flex; align-items: center; gap: 12px; margin-bottom: 16px; }
.section-header h2 { font-size: 15px; font-weight: 600; }
.section-header .actions { margin-left: auto; }
.info-box { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 20px; margin-bottom: 24px; }
.info-box h3 { font-size: 14px; margin-bottom: 10px; color: var(--blue); }
.info-box p  { color: var(--muted); font-size: 13px; line-height: 1.6; margin-bottom: 16px; }
.info-box code { background: var(--bg3); padding: 2px 6px; border-radius: 3px; font-size: 12px; }
.steps { display: flex; flex-direction: column; gap: 8px; }
.step  { display: flex; align-items: center; gap: 10px; font-size: 13px; }
.step-num { background: var(--blue); color: #0d1117; border-radius: 50%; width: 22px; height: 22px; display: flex; align-items: center; justify-content: center; font-size: 11px; font-weight: 700; flex-shrink: 0; }
.upload-zone { border: 2px dashed var(--border); border-radius: 12px; padding: 48px; text-align: center; transition: all .2s; margin-bottom: 20px; }
.upload-zone.drag, .upload-zone:hover { border-color: var(--blue); background: rgba(88,166,255,.05); }
.upload-icon { font-size: 40px; margin-bottom: 12px; color: var(--muted); }
.upload-icon.ok { color: var(--green); }
.upload-text { font-size: 16px; font-weight: 600; margin-bottom: 6px; }
.upload-sub  { color: var(--muted); margin: 8px 0; }
.upload-hint { font-size: 12px; color: var(--muted); margin-top: 12px; }
.upload-done { display: flex; flex-direction: column; align-items: center; gap: 8px; }
.report-summary { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 16px 20px; display: flex; align-items: center; justify-content: space-between; gap: 16px; }
.rs-score { font-size: 16px; font-weight: 600; }
.rs-score.ok       { color: var(--green); }
.rs-score.degraded { color: var(--yellow); }
.rs-score.critical { color: var(--red); }
.rs-status { font-size: 12px; color: var(--muted); margin-left: 8px; }

/* Spinner / Loading */
.spinner { display: inline-block; width: 16px; height: 16px; border: 2px solid var(--border); border-top-color: var(--blue); border-radius: 50%; animation: spin .7s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }
.loading-overlay { display: flex; align-items: center; justify-content: center; gap: 10px; padding: 48px; color: var(--muted); }

/* Misc */
.ok   { color: var(--green); }
.warn { color: var(--yellow); }
.err  { color: var(--red); }

/* Scrollbar */
::-webkit-scrollbar       { width: 6px; height: 6px; }
::-webkit-scrollbar-track { background: var(--bg); }
::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
::-webkit-scrollbar-thumb:hover { background: var(--muted); }

/* Responsive */
@media (max-width: 768px) {
  #sidebar { display: none; }
  #main    { padding: 14px; }
  .stat-row { flex-direction: column; }
  .auth-grid { grid-template-columns: 1fr; }
}
</style>
</head>
<body>
<div id="app">
  <header id="header">
    <div class="logo">ELMA365 <span>Diagnostics</span></div>
    <div class="spacer"></div>
  </header>
  <div id="body">
    <nav id="sidebar"></nav>
    <main id="main"></main>
  </div>
</div>
<script>
HTML_HEAD

    # Часть 2: данные отчёта — вне heredoc, чтобы подставить переменную
    printf 'window.REPORT_DATA = %s;\n' "$json_data" >> "$html_file"

    # Часть 3: встроенный JS + вызов точки входа
    cat >> "$html_file" << 'HTML_FOOT'
// analyzeReport — порт из Go internal/api/upload.go.
// Статически анализирует JSON отчёта без сетевых запросов.
function analyzeReport(raw) {
  const a = {
    health_score:    100,
    status:          'ok',
    issues:          [],
    recommendations: [],
    pg_insights:     [],
    cert_warnings:   [],
    auth_issues:     [],
    log_anomalies:   [],
  };

  const cluster = raw.cluster || {};
  _analyzePods(cluster, a);
  _analyzeEvents(cluster, a);

  const dbs = raw.databases || {};
  if (dbs.postgres_rw) {
    _analyzePostgres(dbs.postgres_rw, a);
  }

  const infra = raw.infrastructure || {};
  if (Array.isArray(infra.certificates)) {
    _analyzeCerts(infra.certificates, a);
  }

  if (raw.auth) {
    _analyzeAuth(raw.auth, a);
  }

  if (raw.logs) {
    _analyzeLogs(raw.logs, a);
  }

  if (a.health_score >= 80)      a.status = 'ok';
  else if (a.health_score >= 50) a.status = 'degraded';
  else                           a.status = 'critical';

  if (a.issues.length === 0) {
    a.issues.push('Явных проблем не обнаружено');
  }

  return a;
}

// _analyzePods снижает счёт за CrashLoopBackOff (>5 рестартов) и OOMKilled.
function _analyzePods(cluster, a) {
  const pods = cluster.pods || [];
  let crashLoop = 0;
  let oomKilled = 0;

  for (const pod of pods) {
    const containers = pod.containers || [];
    for (const c of containers) {
      if (c.last_state === 'OOMKilled') oomKilled++;
      if ((c.restarts || 0) > 5)        crashLoop++;
    }
    // Также проверяем рестарты на уровне пода (поле restarts)
    if ((pod.restarts || 0) > 5) crashLoop++;
  }

  if (crashLoop > 0) {
    a.issues.push(`${crashLoop} подов в CrashLoopBackOff`);
    a.health_score -= 20;
  }
  if (oomKilled > 0) {
    a.issues.push(`${oomKilled} подов убиты OOMKiller`);
    a.recommendations.push('Увеличить memory limit в values-elma365.yaml');
    a.health_score -= 15;
  }
}

function _analyzeEvents(cluster, a) {
  const events = cluster.events || [];
  if (events.length > 10) {
    a.issues.push(`${events.length} Warning событий в кластере`);
    a.health_score -= 5;
  }
}

// _analyzePostgres проверяет блокировки, медленные запросы и bloat таблиц.
function _analyzePostgres(pg, a) {
  const locks = pg.locks || [];
  if (locks.length > 0) {
    a.issues.push(`PostgreSQL: ${locks.length} активных блокировок`);
    a.recommendations.push('SELECT pg_terminate_backend(blocking_pid) для разблокировки');
    a.health_score -= 15;
  }

  const slow = pg.slow_queries || [];
  if (slow.length > 0) {
    a.pg_insights.push(`${slow.length} запросов выполняются дольше 5 секунд`);
    a.health_score -= 10;
  }

  if (pg.has_pg_stat_statements === false) {
    a.pg_insights.push('pg_stat_statements не установлен — история запросов недоступна');
  }

  const bloat = pg.bloat_tables || [];
  for (const b of bloat) {
    if ((b.bloat_pct || 0) > 40) {
      const name = b.relname || b.table || '';
      a.pg_insights.push(`Таблица ${name}: bloat ${b.bloat_pct}% — нужен VACUUM`);
      a.recommendations.push(`VACUUM ANALYZE ${name};`);
    }
  }
}

function _analyzeCerts(certs, a) {
  for (const cert of certs) {
    const status   = cert.status   || '';
    const name     = cert.name || cert.host || '';
    const daysLeft = cert.days_left || 0;

    if (status === 'warn' || status === 'critical' || status === 'expired') {
      a.cert_warnings.push({ name, days_left: daysLeft, status });
      a.issues.push(`Сертификат ${name} истекает через ${daysLeft} дней`);
      a.health_score -= 10;
    }
  }
}

// _analyzeAuth ищет ошибки в логах auth/vahter/hydra и проверяет connectivity.
function _analyzeAuth(auth, a) {
  for (const [svc, data] of Object.entries(auth)) {
    if (svc === 'connectivity') continue;
    if (data && typeof data.errors === 'string' && data.errors.length > 100) {
      a.auth_issues.push(`${svc}: обнаружены ошибки авторизации в логах`);
      a.health_score -= 5;
    }
  }

  const conn = auth.connectivity || {};
  for (const [svc, ep] of Object.entries(conn)) {
    if (ep && ep.reachable === false) {
      a.auth_issues.push(`${svc} недоступен: ${ep.url || ''}`);
      a.health_score -= 10;
    }
  }
}

function _analyzeLogs(logs, a) {
  for (const [pod, logData] of Object.entries(logs)) {
    if (typeof logData === 'string' && logData.length > 500) {
      const lines = (logData.match(/\n/g) || []).length;
      a.log_anomalies.push(`${pod}: ${lines} строк с ошибками`);
    }
  }
}

// initReport — точка входа для standalone HTML.
// Читает window.REPORT_DATA, анализирует и рендерит отчёт без сервера.
function initReport() {
  const raw  = window.REPORT_DATA;
  const a    = analyzeReport(raw);
  const meta = raw.meta || {};

  const statusLabel = { ok: 'OK', degraded: 'Есть проблемы', critical: 'Критично' }[a.status] || a.status;

  document.getElementById('sidebar').innerHTML = buildTOC(a, raw);

  document.getElementById('main').innerHTML = `
    <div class="rp-header">
      <div class="rp-title">ELMA365 Diagnostics</div>
      <div class="rp-meta">
        <span class="tag">${meta.namespace || '—'}</span>
        <span class="tag">${meta.collected_at ? new Date(meta.collected_at).toLocaleString('ru') : '—'}</span>
        <span class="badge ${a.status}">${statusLabel} · ${a.health_score}/100</span>
      </div>
    </div>
    ${sectionSummary(a)}
    ${sectionCluster(a, raw)}
    ${sectionPostgres(a, raw)}
    ${sectionMongo(a, raw)}
    ${sectionRedis(a, raw)}
    ${sectionRmq(a, raw)}
    ${sectionS3(a, raw)}
    ${sectionCerts(a, raw)}
    ${sectionAuth(a, raw)}
    ${sectionLogs(raw)}
  `;
}

// buildTOC — навигация по разделам отчёта.
// Кнопка "← Новый отчёт" убрана: в standalone-режиме она не нужна.
function buildTOC(a, raw) {
  const dbs    = raw.databases || {};
  const issues = (a.issues || []).length;

  const items = [
    { id: 's-summary',  label: 'Итог',          badge: issues ? `<span class="nav-badge">${issues}</span>` : '' },
    { id: 's-cluster',  label: 'Кластер',        badge: '' },
    { id: 's-postgres', label: 'PostgreSQL',     badge: '', skip: !dbs.postgres_rw },
    { id: 's-mongo',    label: 'MongoDB',        badge: '', skip: !dbs.mongodb },
    { id: 's-redis',    label: 'Redis',          badge: '', skip: !dbs.redis },
    { id: 's-rmq',      label: 'RabbitMQ',       badge: '', skip: !dbs.rabbitmq },
    { id: 's-s3',       label: 'S3',             badge: '', skip: !raw.s3 || raw.s3 === null },
    { id: 's-certs',    label: 'Сертификаты',    badge: '' },
    { id: 's-auth',     label: 'Авторизация',    badge: '' },
    { id: 's-logs',     label: 'Логи сервисов',  badge: '' },
  ];

  return `
    <div class="nav-section">Навигация</div>
    ${items.filter(i => !i.skip).map(i => `
      <a class="nav-item toc-link" href="#${i.id}" onclick="scrollTo('${i.id}')">
        ${i.label}${i.badge}
      </a>`).join('')}`;
}

function scrollTo(id) {
  event.preventDefault();
  document.getElementById(id)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function sectionSummary(a) {
  const issues = a.issues || [];
  const crits  = issues.filter(i => /крит|OOM|блок|истек|истёк|нет доступ/i.test(i));
  const warns  = issues.filter(i => !crits.includes(i));

  return `
  <section id="s-summary" class="report-section">
    <h2 class="section-title">Итог</h2>

    <div class="summary-cards">
      <div class="sum-card ${crits.length ? 'err' : 'ok'}">
        <div class="sum-num">${crits.length}</div>
        <div class="sum-label">Критических проблем</div>
      </div>
      <div class="sum-card ${warns.length ? 'warn' : 'ok'}">
        <div class="sum-num">${warns.length}</div>
        <div class="sum-label">Предупреждений</div>
      </div>
      <div class="sum-card ok">
        <div class="sum-num">${a.health_score || 100}</div>
        <div class="sum-label">Health Score / 100</div>
      </div>
    </div>

    ${issues.length ? `
    <div class="issue-list">
      ${crits.map(i => `<div class="issue-row err"><span class="issue-dot err"></span>${i}</div>`).join('')}
      ${warns.map(i => `<div class="issue-row warn"><span class="issue-dot warn"></span>${i}</div>`).join('')}
    </div>` : `<div class="ok-banner">Явных проблем не обнаружено</div>`}
  </section>`;
}

function sectionCluster(a, raw) {
  const cluster = raw.cluster || {};
  const pods    = cluster.pods    || [];
  const events  = cluster.events  || [];
  const hpas    = cluster.hpas    || [];
  const nodes   = cluster.nodes   || [];
  const istio   = cluster.istio;
  const machine = raw.infrastructure?.machine_specs;
  const migr    = cluster.migration;

  const ready   = pods.filter(p => p.ready).length;
  const crashed = pods.filter(p => (p.restarts || 0) > 5 ||
    (p.containers || []).some(c => c.last_state === 'OOMKilled')).length;

  return `
  <section id="s-cluster" class="report-section">
    <h2 class="section-title">Кластер</h2>

    <div class="stat-row">
      <div class="stat-box ${crashed > 0 ? 'err' : 'ok'}">
        <div class="stat-val">${ready}/${pods.length}</div>
        <div class="stat-key">Подов готово</div>
        ${crashed > 0 ? `<div class="stat-sub">${crashed} с проблемами</div>` : ''}
      </div>
      <div class="stat-box">
        <div class="stat-val">${nodes.length}</div>
        <div class="stat-key">Нод</div>
        ${machine ? `<div class="stat-sub">${machine.cpu_cores} CPU · ${machine.ram_gb} GB RAM</div>` : ''}
      </div>
      <div class="stat-box ${events.length > 0 ? 'warn' : 'ok'}">
        <div class="stat-val">${events.length}</div>
        <div class="stat-key">Warning событий</div>
      </div>
      <div class="stat-box">
        <div class="stat-val">${hpas.length}</div>
        <div class="stat-key">HPA</div>
      </div>
    </div>

    ${migr ? `
    <h3 class="sub-title">Миграции БД</h3>
    ${renderMigration(migr)}` : ''}

    ${istio ? `
    <h3 class="sub-title">Istio Service Mesh</h3>
    <div class="tbl-wrap"><table><tbody>
      <tr><td>Istiod</td><td>${istio.istiod_ready ? '<span class="ok">Работает</span>' : '<span class="err">Не работает</span>'}</td></tr>
      <tr><td>Версия</td><td>${istio.version || '—'}</td></tr>
      <tr><td>Подов с sidecar</td><td>${istio.sidecar_injected_pods}</td></tr>
      ${(istio.warnings || []).map(w => `<tr><td colspan="2" class="warn">⚠ ${w}</td></tr>`).join('')}
    </tbody></table></div>` : ''}

    ${crashed > 0 ? `
    <h3 class="sub-title warn-title">Проблемные поды</h3>
    <div class="tbl-wrap"><table>
      <thead><tr><th>Под</th><th>Контейнер</th><th>Рестартов</th><th>Причина</th><th>CPU req/lim</th><th>CPU сейчас</th><th>RAM req/lim</th><th>RAM сейчас</th></tr></thead>
      <tbody>
        ${pods.filter(p => (p.restarts || 0) > 5 || (p.containers || []).some(c => c.last_state === 'OOMKilled'))
          .flatMap(p => (p.containers || []).map(c => ({ pod: p.name, c })))
          .map(({ pod, c }) => `<tr>
            <td><b>${pod}</b></td>
            <td>${c.name}</td>
            <td class="${(c.restarts || 0) > 5 ? 'err' : (c.restarts || 0) > 0 ? 'warn' : ''}">${c.restarts || 0}</td>
            <td class="${c.last_state === 'OOMKilled' ? 'err' : ''}">${c.last_state || '—'}</td>
            <td style="font-size:12px">${c.cpu_req || '—'} / ${c.cpu_lim || '—'}</td>
            <td style="font-size:12px">${c.cpu_now || '—'}</td>
            <td style="font-size:12px">${c.mem_req || '—'} / ${c.mem_lim || '—'}</td>
            <td style="font-size:12px">${c.mem_now || '—'}</td>
          </tr>`).join('')}
      </tbody>
    </table></div>` : ''}

    <h3 class="sub-title">Все поды</h3>
    <div class="tbl-wrap"><table>
      <thead><tr><th>Статус</th><th>Под</th><th>Контейнер</th><th>Рестартов</th><th>CPU req/lim</th><th>CPU сейчас</th><th>RAM req/lim</th><th>RAM сейчас</th><th>Нода</th></tr></thead>
      <tbody>
        ${pods.flatMap(p => (p.containers || []).map((c, i) => ({ p, c, i }))).map(({ p, c, i }) => {
          const ok = p.ready && (p.restarts || 0) <= 5;
          return `<tr>
            <td>${i === 0 ? `<span class="dot ${ok ? 'ok' : 'err'}"></span>` : ''}</td>
            <td>${i === 0 ? p.name : ''}</td>
            <td style="color:var(--muted)">${c.name}</td>
            <td class="${(c.restarts || 0) > 5 ? 'err' : (c.restarts || 0) > 0 ? 'warn' : ''}">${c.restarts || 0}</td>
            <td style="font-size:12px">${c.cpu_req || '—'} / ${c.cpu_lim || '—'}</td>
            <td style="font-size:12px">${c.cpu_now || '—'}</td>
            <td style="font-size:12px">${c.mem_req || '—'} / ${c.mem_lim || '—'}</td>
            <td style="font-size:12px">${c.mem_now || '—'}</td>
            <td style="font-size:12px;color:var(--muted)">${i === 0 ? (p.node || '—') : ''}</td>
          </tr>`;
        }).join('')}
      </tbody>
    </table></div>

    ${hpas.length ? `
    <h3 class="sub-title">Автомасштабирование (HPA)</h3>
    <p class="section-hint">HPA добавляет реплики при нагрузке. Если current = max — система на пределе.</p>
    <div class="tbl-wrap"><table>
      <thead><tr><th>Сервис</th><th>Сейчас</th><th>Желаемое</th><th>Мин</th><th>Макс</th><th>CPU %</th></tr></thead>
      <tbody>
        ${hpas.map(h => `<tr>
          <td><b>${h.target || h.name}</b></td>
          <td class="${(h.current_replicas || h.current) >= (h.max_replicas || h.max) ? 'warn' : ''}">${h.current_replicas || h.current}</td>
          <td>${h.desired_replicas || h.desired}</td>
          <td>${h.min_replicas || h.min}</td>
          <td>${h.max_replicas || h.max}</td>
          <td>${h.cpu_pct || '—'}</td>
        </tr>`).join('')}
      </tbody>
    </table></div>` : ''}

    ${events.length ? `
    <h3 class="sub-title">Warning события</h3>
    <p class="section-hint">Повторяющиеся события — сигнал о проблеме. Обрати внимание на count > 5.</p>
    <div class="tbl-wrap"><table>
      <thead><tr><th>Объект</th><th>Причина</th><th>Сообщение</th><th>Кол-во</th></tr></thead>
      <tbody>
        ${events.map(e => `<tr>
          <td><b>${e.object || ''}</b></td>
          <td class="warn">${e.reason || ''}</td>
          <td style="font-size:12px">${(e.message || '').substring(0, 120)}</td>
          <td>${e.count || 1}</td>
        </tr>`).join('')}
      </tbody>
    </table></div>` : ''}
  </section>`;
}

function renderMigration(migr) {
  if (migr === 'unavailable') {
    return `<div class="tip-box">Под deploy не найден или недоступен — статус миграций неизвестен.</div>`;
  }
  try {
    const data = typeof migr === 'string' ? JSON.parse(migr) : migr;

    // Формат /migration/states (массив) — версии 2024.10+
    if (Array.isArray(data)) {
      const failed  = data.filter(m => m.status === 'failed'  || m.state === 'failed');
      const running = data.filter(m => m.status === 'running' || m.state === 'running');
      const pending = data.filter(m => m.status === 'pending' || m.state === 'pending');
      return `
        <div class="stat-row" style="margin-bottom:12px">
          <div class="stat-box ${failed.length ? 'err' : 'ok'}"><div class="stat-val">${failed.length}</div><div class="stat-key">Ошибок</div></div>
          <div class="stat-box ${running.length ? 'warn' : 'ok'}"><div class="stat-val">${running.length}</div><div class="stat-key">Выполняется</div></div>
          <div class="stat-box"><div class="stat-val">${pending.length}</div><div class="stat-key">Ожидает</div></div>
          <div class="stat-box ok"><div class="stat-val">${data.length - failed.length - running.length - pending.length}</div><div class="stat-key">Завершено</div></div>
        </div>
        ${failed.length ? `
        <div class="tbl-wrap"><table>
          <thead><tr><th>Миграция</th><th>Статус</th><th>Ошибка</th></tr></thead>
          <tbody>
            ${failed.map(m => `<tr>
              <td><b>${m.name || m.id || '—'}</b></td>
              <td class="err">${m.status || m.state}</td>
              <td style="font-size:12px">${m.error || m.message || '—'}</td>
            </tr>`).join('')}
          </tbody>
        </table></div>` : ''}`;
    }

    // Формат /migration/state (объект) — версии < 2024.10
    const st = data.state || data.status || '—';
    const stClass = st === 'done' || st === 'completed' ? 'ok' : st === 'failed' ? 'err' : 'warn';
    return `<div class="tip-box">Статус миграций: <span class="${stClass}"><b>${st}</b></span>
      ${data.current ? ` · Текущая: ${data.current}` : ''}
      ${data.pending !== undefined ? ` · Ожидает: ${data.pending}` : ''}
    </div>`;
  } catch {
    return `<div class="tip-box">Не удалось разобрать статус миграций.</div>`;
  }
}

function pgInstance(label, pg) {
  const conns   = pg.connections || {};
  const svcLoad = pg.service_load || [];
  const slow    = pg.slow_queries || [];
  const locks   = pg.locks || [];
  const bloat   = pg.bloat_tables || [];
  const config  = pg.config || [];
  const tune    = pg.tune_recommendations;
  const connPct = conns.max ? Math.round((conns.total || 0) / conns.max * 100) : 0;

  return `
    <h3 class="sub-title">${label} <span class="tag">${pg.version ? pg.version.substring(0, 25) : ''}</span> <span class="tag">${pg.db_size || ''}</span></h3>

    <div class="stat-row">
      <div class="stat-box ${connPct > 85 ? 'err' : connPct > 70 ? 'warn' : 'ok'}">
        <div class="stat-val">${conns.total || 0}/${conns.max || 0}</div>
        <div class="stat-key">Соединений</div>
        <div class="stat-sub">${connPct}% от макс.</div>
        <div class="metric-bar"><div class="fill ${connPct > 85 ? 'err' : connPct > 70 ? 'warn' : 'ok'}" style="width:${connPct}%"></div></div>
      </div>
      <div class="stat-box ${locks.length ? 'err' : 'ok'}">
        <div class="stat-val">${locks.length}</div>
        <div class="stat-key">Блокировок</div>
      </div>
      <div class="stat-box ${slow.length ? 'warn' : 'ok'}">
        <div class="stat-val">${slow.length}</div>
        <div class="stat-key">Медленных запросов</div>
        <div class="stat-sub">&gt; 5 сек прямо сейчас</div>
      </div>
      <div class="stat-box ${bloat.filter(b => (b.bloat_pct || 0) > 40).length ? 'warn' : 'ok'}">
        <div class="stat-val">${bloat.filter(b => (b.bloat_pct || 0) > 40).length}</div>
        <div class="stat-key">Bloat таблиц &gt; 40%</div>
      </div>
    </div>

    ${!pg.has_pg_stat_statements ? `
    <div class="tip-box">
      pg_stat_statements не включён — история запросов недоступна.<br>
      Включить: Yandex Cloud → Managed PostgreSQL → Настройки СУБД → <code>shared_preload_libraries</code>
    </div>` : ''}

    ${svcLoad.length ? `
    <h4 class="sub-title-sm">Нагрузка по сервисам ELMA365</h4>
    <p class="section-hint">Показывает какой сервис создаёт нагрузку на базу. <b>Ожидают блокировку</b> — критичный признак.</p>
    <div class="tbl-wrap"><table>
      <thead><tr><th>Сервис</th><th>Соединений</th><th>Активных</th><th>Idle</th><th>Ждут блокировку</th><th>Макс. запрос, сек</th></tr></thead>
      <tbody>
        ${svcLoad.map(s => `<tr>
          <td><b>${s.service || 'unknown'}</b></td>
          <td>${s.total_connections || 0}</td>
          <td class="${(s.active || 0) > 5 ? 'warn' : ''}">${s.active || 0}</td>
          <td>${s.idle || 0}</td>
          <td class="${(s.waiting || 0) > 0 ? 'err' : ''}">${s.waiting || 0}</td>
          <td class="${(s.max_query_sec || 0) > 10 ? 'err' : (s.max_query_sec || 0) > 3 ? 'warn' : ''}">${s.max_query_sec || 0}</td>
        </tr>`).join('')}
      </tbody>
    </table></div>` : ''}

    ${locks.length ? `
    <h4 class="sub-title-sm warn-title">Блокировки (${locks.length})</h4>
    <p class="section-hint">Один запрос ждёт пока другой освободит данные — замедляет всю систему.</p>
    <div class="tbl-wrap"><table>
      <thead><tr><th>Заблокирован PID</th><th>Блокирует PID</th><th>Запрос</th></tr></thead>
      <tbody>
        ${locks.map(l => `<tr>
          <td>${l.blocked_pid || ''}</td>
          <td>${l.blocking_pid || ''}</td>
          <td style="font-size:12px">${(l.blocked_query || '').substring(0, 100)}</td>
        </tr>`).join('')}
      </tbody>
    </table></div>` : ''}

    ${slow.length ? `
    <h4 class="sub-title-sm">Медленные запросы прямо сейчас</h4>
    <div class="tbl-wrap"><table>
      <thead><tr><th>PID</th><th>Длительность</th><th>Состояние</th><th>Запрос</th></tr></thead>
      <tbody>
        ${slow.map(q => `<tr>
          <td>${q.pid || ''}</td>
          <td class="warn">${q.duration || q.duration_sec || ''} сек</td>
          <td>${q.state || ''}</td>
          <td style="font-size:12px">${(q.query || '').substring(0, 120)}</td>
        </tr>`).join('')}
      </tbody>
    </table></div>` : ''}

    ${pg.top_queries?.length ? `
    <h4 class="sub-title-sm">Топ запросов по суммарному времени</h4>
    <p class="section-hint">Из <code>pg_stat_statements</code>. Колонка <b>сервис</b> — кто выполняет этот запрос чаще всего.</p>
    <div class="tbl-wrap"><table>
      <thead><tr><th>Сервис</th><th>Вызовов</th><th>Среднее, мс</th><th>Макс, мс</th><th>Итого, мс</th><th>Запрос</th></tr></thead>
      <tbody>
        ${pg.top_queries.map(q => `<tr>
          <td><b>${q.service || '—'}</b></td>
          <td>${q.calls || 0}</td>
          <td class="${(q.mean_ms || 0) > 500 ? 'err' : (q.mean_ms || 0) > 100 ? 'warn' : ''}">${q.mean_ms || 0}</td>
          <td class="${(q.max_ms || 0) > 2000 ? 'err' : (q.max_ms || 0) > 500 ? 'warn' : ''}">${q.max_ms || 0}</td>
          <td>${q.total_ms || 0}</td>
          <td style="font-size:11px;max-width:280px;word-break:break-all">${(q.query || '').substring(0, 150)}</td>
        </tr>`).join('')}
      </tbody>
    </table></div>` : ''}

    ${bloat.filter(b => (b.bloat_pct || 0) > 10).length ? `
    <h4 class="sub-title-sm">Bloat таблиц (мёртвые строки)</h4>
    <p class="section-hint">Bloat &gt; 30% — нужен VACUUM. Накапливается после массовых UPDATE/DELETE.</p>
    <div class="tbl-wrap"><table>
      <thead><tr><th>Таблица</th><th>Bloat %</th><th>Мёртвых строк</th><th>Последний VACUUM</th></tr></thead>
      <tbody>
        ${bloat.filter(b => (b.bloat_pct || 0) > 10).map(b => `<tr>
          <td><b>${b.table || b.relname || ''}</b></td>
          <td class="${(b.bloat_pct || 0) > 40 ? 'err' : (b.bloat_pct || 0) > 20 ? 'warn' : ''}">${b.bloat_pct || 0}%</td>
          <td>${b.dead_rows || b.n_dead_tup || 0}</td>
          <td style="font-size:12px">${b.last_vacuum || 'никогда'}</td>
        </tr>`).join('')}
      </tbody>
    </table></div>` : ''}

    ${tune?.recommended ? `
    <details class="collapsible">
      <summary>Рекомендации по настройке PostgreSQL (PGTune)</summary>
      <p class="section-hint">Рассчитано под ${tune.based_on?.ram_gb || '?'} GB RAM, ${tune.based_on?.cpu_cores || '?'} CPU.</p>
      <div class="tbl-wrap"><table>
        <thead><tr><th>Параметр</th><th>Рекомендуется</th></tr></thead>
        <tbody>
          ${Object.entries(tune.recommended).map(([k, v]) => `<tr><td><code>${k}</code></td><td class="ok">${v}</td></tr>`).join('')}
        </tbody>
      </table></div>
    </details>` : ''}

    ${config.length ? `
    <details class="collapsible">
      <summary>Текущая конфигурация PostgreSQL</summary>
      <div class="tbl-wrap"><table>
        <thead><tr><th>Параметр</th><th>Значение</th><th>Описание</th></tr></thead>
        <tbody>
          ${config.map(c => `<tr>
            <td><code>${c.name || ''}</code></td>
            <td>${c.setting || ''} ${c.unit || ''}</td>
            <td style="font-size:12px;color:var(--muted)">${c.short_desc || ''}</td>
          </tr>`).join('')}
        </tbody>
      </table></div>
    </details>` : ''}`;
}

function sectionPostgres(a, raw) {
  const dbs = raw.databases || {};
  const instances = [];
  if (dbs.postgres_rw) instances.push({ label: 'Primary (RW)', data: dbs.postgres_rw });
  if (dbs.postgres_ro) instances.push({ label: 'Replica (RO)', data: dbs.postgres_ro });
  if (!instances.length) return '';

  return `
  <section id="s-postgres" class="report-section">
    <h2 class="section-title">PostgreSQL</h2>
    ${instances.map(inst => pgInstance(inst.label, inst.data)).join('')}
  </section>`;
}

function sectionMongo(a, raw) {
  const mongo = raw.databases?.mongodb;
  if (!mongo) return '';

  return `
  <section id="s-mongo" class="report-section">
    <h2 class="section-title">MongoDB</h2>
    ${mongo.error ? `<div class="tip-box warn">⚠ ${mongo.error}</div>` : `
      <div class="stat-row">
        <div class="stat-box"><div class="stat-val">${mongo.version || '—'}</div><div class="stat-key">Версия</div></div>
        <div class="stat-box"><div class="stat-val">${mongo.collections?.length || 0}</div><div class="stat-key">Коллекций</div></div>
        <div class="stat-box"><div class="stat-val">${mongo.db_size || '—'}</div><div class="stat-key">Размер БД</div></div>
      </div>
      ${mongo.replica_set ? `
      <h3 class="sub-title">Replica Set</h3>
      <div class="tbl-wrap"><table>
        <thead><tr><th>Хост</th><th>Роль</th><th>Статус</th></tr></thead>
        <tbody>
          ${(mongo.replica_set.members || []).map(m => `<tr>
            <td>${m.name || ''}</td>
            <td>${m.stateStr || ''}</td>
            <td class="${m.health === 1 ? 'ok' : 'err'}">${m.health === 1 ? 'OK' : 'FAIL'}</td>
          </tr>`).join('')}
        </tbody>
      </table></div>` : ''}
      ${mongo.collections?.length ? `
      <h3 class="sub-title">Коллекции</h3>
      <div class="tbl-wrap"><table>
        <thead><tr><th>Коллекция</th><th>Документов</th><th>Размер</th></tr></thead>
        <tbody>
          ${mongo.collections.slice(0, 20).map(c => `<tr>
            <td>${c.name || ''}</td>
            <td>${c.count || 0}</td>
            <td>${c.size || '—'}</td>
          </tr>`).join('')}
        </tbody>
      </table></div>` : ''}
    `}
  </section>`;
}

function sectionRedis(a, raw) {
  const redis = raw.databases?.redis;
  if (!redis) return '';

  return `
  <section id="s-redis" class="report-section">
    <h2 class="section-title">Redis / Valkey</h2>
    ${redis.error ? `<div class="tip-box warn">⚠ ${redis.error}</div>` : `
      <div class="stat-row">
        <div class="stat-box"><div class="stat-val">${redis.redis_version || redis.server_name || '—'}</div><div class="stat-key">Версия</div></div>
        <div class="stat-box"><div class="stat-val">${redis.used_memory_human || '—'}</div><div class="stat-key">Памяти используется</div></div>
        <div class="stat-box"><div class="stat-val">${redis.connected_clients || '—'}</div><div class="stat-key">Клиентов</div></div>
        <div class="stat-box ${redis.role === 'master' ? 'ok' : ''}"><div class="stat-val">${redis.role || '—'}</div><div class="stat-key">Роль</div></div>
      </div>
    `}
  </section>`;
}

function sectionRmq(a, raw) {
  const rmq = raw.databases?.rabbitmq;
  if (!rmq) return '';

  return `
  <section id="s-rmq" class="report-section">
    <h2 class="section-title">RabbitMQ</h2>
    ${rmq.error ? `<div class="tip-box warn">⚠ ${rmq.error}</div>` : `
      <div class="stat-row">
        <div class="stat-box"><div class="stat-val">${rmq.version || '—'}</div><div class="stat-key">Версия</div></div>
        <div class="stat-box ${(rmq.messages_ready || 0) > 1000 ? 'warn' : 'ok'}">
          <div class="stat-val">${rmq.messages_ready || 0}</div>
          <div class="stat-key">Очередь (готово)</div>
        </div>
        <div class="stat-box ${(rmq.messages_unacked || 0) > 100 ? 'warn' : 'ok'}">
          <div class="stat-val">${rmq.messages_unacked || 0}</div>
          <div class="stat-key">Не подтверждено</div>
        </div>
      </div>
    `}
  </section>`;
}

function sectionS3(a, raw) {
  const s3 = raw.s3;
  if (!s3 || s3 === null) return '';

  return `
  <section id="s-s3" class="report-section">
    <h2 class="section-title">S3 / Объектное хранилище</h2>
    ${s3.error ? `<div class="tip-box warn">⚠ ${s3.error}</div>` : `
      <div class="stat-row">
        <div class="stat-box ${s3.accessible ? 'ok' : 'err'}">
          <div class="stat-val">${s3.accessible ? 'Доступно' : 'Недоступно'}</div>
          <div class="stat-key">Хранилище</div>
        </div>
        ${s3.last_backup_hours !== undefined ? `
        <div class="stat-box ${s3.last_backup_hours > 48 ? 'err' : s3.last_backup_hours > 25 ? 'warn' : 'ok'}">
          <div class="stat-val">${s3.last_backup_hours}ч</div>
          <div class="stat-key">Последний бэкап</div>
        </div>` : ''}
        ${s3.bucket ? `<div class="stat-box"><div class="stat-val" style="font-size:14px">${s3.bucket}</div><div class="stat-key">Bucket</div></div>` : ''}
      </div>
    `}
  </section>`;
}

function sectionCerts(a, raw) {
  const certs = raw.infrastructure?.certificates || [];

  return `
  <section id="s-certs" class="report-section">
    <h2 class="section-title">Сертификаты</h2>
    ${!certs.length ? '<div class="tip-box">Сертификаты не найдены или скрипт запущен без прав на чтение секретов.</div>' : `
    <p class="section-hint">Истёкший сертификат = пользователи получают ошибку браузера. Нужно обновить за 7+ дней до истечения.</p>
    <div class="tbl-wrap"><table>
      <thead><tr><th>Сертификат</th><th>Осталось дней</th><th>Истекает</th><th>Статус</th><th>Самоподписанный</th></tr></thead>
      <tbody>
        ${certs.map(c => `<tr>
          <td><b>${c.name || ''}</b></td>
          <td class="${(c.days_left || 0) < 14 ? 'err' : (c.days_left || 0) < 30 ? 'warn' : 'ok'}">${c.days_left ?? '—'}</td>
          <td style="font-size:12px">${c.not_after || '—'}</td>
          <td><span class="badge ${c.status || 'ok'}">${c.status || 'ok'}</span></td>
          <td>${c.self_signed ? '<span class="warn">да</span>' : 'нет'}</td>
        </tr>`).join('')}
      </tbody>
    </table></div>`}
  </section>`;
}

function sectionAuth(a, raw) {
  const auth    = raw.auth          || {};
  const authSvc = auth.auth         || {};
  const vahter  = auth.vahter       || {};
  const hydra   = auth.hydra_adaptor || {};
  const conn    = auth.connectivity  || {};

  const cards = [
    { name: 'auth',          label: 'auth',          hint: 'Основной сервис авторизации — выдаёт токены',          data: authSvc },
    { name: 'vahter',        label: 'vahter',        hint: 'Проверяет токены при каждом запросе',                  data: vahter  },
    { name: 'hydra_adaptor', label: 'hydra-adaptor', hint: 'Нужен только для SSO, Keycloak, AD, SAML интеграции', data: hydra   },
  ];

  return `
  <section id="s-auth" class="report-section">
    <h2 class="section-title">Авторизация</h2>
    <p class="section-hint">Ошибки здесь = пользователи не могут войти в систему.</p>

    ${(a.auth_issues || []).length ? `
    <div class="issue-list" style="margin-bottom:16px">
      ${a.auth_issues.map(i => `<div class="issue-row warn"><span class="issue-dot warn"></span>${i}</div>`).join('')}
    </div>` : ''}

    ${Object.keys(conn).length ? `
    <h3 class="sub-title">Внешние системы авторизации</h3>
    <div class="tbl-wrap"><table>
      <thead><tr><th>Система</th><th>URL</th><th>Доступность</th><th>HTTP код</th></tr></thead>
      <tbody>
        ${Object.entries(conn).map(([k, v]) => `<tr>
          <td><b>${k}</b></td>
          <td style="font-size:12px">${v.url || ''}</td>
          <td>${v.reachable ? '<span class="ok">Доступен</span>' : '<span class="err">Недоступен</span>'}</td>
          <td>${v.http_code || '—'}</td>
        </tr>`).join('')}
      </tbody>
    </table></div>` : ''}

    <div class="auth-grid">
      ${cards.map(c => `
      <div class="auth-card">
        <div class="auth-header">
          <span class="auth-name">${c.label}</span>
          <span class="tag">${c.data.pod || 'под не найден'}</span>
        </div>
        <div class="auth-hint">${c.hint}</div>
        <div class="log-box">${fmtLogs(c.data.logs)}</div>
      </div>`).join('')}
    </div>
  </section>`;
}

function sectionLogs(raw) {
  const logs    = raw.logs || {};
  const elmaErr = logs.__elma_errors || '';
  const pods    = Object.keys(logs).filter(k => k !== '__elma_errors');

  return `
  <section id="s-logs" class="report-section">
    <h2 class="section-title">Логи сервисов</h2>

    ${elmaErr.trim() ? `
    <h3 class="sub-title warn-title">ELMA365 — error / fatal (tier=elma365)</h3>
    <p class="section-hint">Отфильтровано из всех подов с меткой <code>tier=elma365</code>.</p>
    <div class="log-box">${fmtLogs(elmaErr)}</div>` :
    `<div class="tip-box" style="margin-bottom:16px">Ошибок уровня error/fatal в подах <code>tier=elma365</code> не найдено.</div>`}

    <h3 class="sub-title">Последние строки по подам</h3>
    <p class="section-hint">
      Строки <span class="tag err-tag">error</span> и <span class="tag err-tag">fatal</span> — ошибки, требуют внимания.
      Строки <span class="tag">debug</span> — нормальная работа, можно игнорировать.
    </p>

    ${!pods.length ? '<div class="tip-box">Логи не собраны.</div>' :
    pods.map(pod => {
      const hasErr = hasLogErrors(logs[pod]);
      return `
        <details class="collapsible" ${hasErr ? 'open' : ''}>
          <summary>
            ${pod}
            ${hasErr ? '<span class="tag err-tag" style="margin-left:8px">есть ошибки</span>' : '<span class="tag ok-tag" style="margin-left:8px">нет ошибок</span>'}
          </summary>
          <div class="log-box">${fmtLogs(logs[pod])}</div>
        </details>`;
    }).join('')}
  </section>`;
}

function fmtLogs(text) {
  if (!text) return '<span style="color:var(--muted)">Нет записей</span>';
  return text.split('\n').map(line => {
    const l = line.toLowerCase();
    let cls = '';
    if (/\berror\b|\bfatal\b|\bpanic\b/.test(l)) cls = 'log-error';
    else if (/\bwarn\b|\bwarning\b/.test(l))      cls = 'log-warn';
    else if (/\bdebug\b|\btrace\b/.test(l))        cls = 'log-debug';
    const escaped = line.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    return `<div class="log-line ${cls}">${escaped}</div>`;
  }).join('');
}

function hasLogErrors(text) {
  if (!text) return false;
  return /\berror\b|\bfatal\b|\bpanic\b/i.test(text);
}
initReport();
</script>
</body>
</html>
HTML_FOOT

    echo "$html_file"
}

main() {
    check_deps
    detect_namespace

    REPORT_FILE="$OUTPUT_DIR/elma365-report-${TIMESTAMP}.json"
    log "Сбор диагностики ELMA365, namespace: $NAMESPACE"
    log "Файл отчёта: $REPORT_FILE"

    local psql_url psql_ro_url mongo_url redis_url amqp_url
    psql_url=$(read_dsn "PSQL_URL")
    psql_ro_url=$(read_dsn "RO_POSTGRES_URL")
    mongo_url=$(read_dsn "MONGO_URL")
    redis_url=$(read_dsn "REDIS_URL")
    amqp_url=$(read_dsn "AMQP_URL")

    if [[ -z "$psql_url" && -z "$mongo_url" ]]; then
        warn "Secret $DB_SECRET не найден или пуст в namespace $NAMESPACE"
        warn "Собираем только k8s данные"
    fi

    local k8s_data pg_rw pg_ro mongo_data redis_data rmq_data
    local certs_data auth_data logs_data machine_specs pg_tune

    k8s_data=$(collect_k8s)
    logs_data=$(collect_logs)
    certs_data=$(collect_certs)
    auth_data=$(collect_auth)
    machine_specs=$(collect_machine_specs)

    pg_rw="{}"
    pg_ro="{}"
    if [[ -n "$psql_url" ]]; then
        pg_rw=$(collect_postgres "$psql_url" "pg-rw")
        local pg_config
        pg_config=$(echo "$pg_rw" | jq '.config // []' 2>/dev/null || echo "[]")
        pg_tune=$(pg_tune_recommendations "$pg_config" "$machine_specs")
        pg_rw=$(echo "$pg_rw" | jq --argjson tune "$pg_tune" '. + {tune_recommendations: $tune}')
    fi
    if [[ -n "$psql_ro_url" && "$psql_ro_url" != "$psql_url" ]]; then
        pg_ro=$(collect_postgres "$psql_ro_url" "pg-ro")
    fi

    mongo_data="{}"
    [[ -n "$mongo_url" ]] && mongo_data=$(collect_mongo "$mongo_url")

    redis_data="{}"
    if [[ -n "$redis_url" ]]; then
        redis_data=$(collect_redis "$redis_url")
    fi

    rmq_data="{}"
    if [[ -n "$amqp_url" ]]; then
        rmq_data=$(collect_rabbitmq "$amqp_url")
    fi

    # S3 — читаем конфиг из values
    local s3_data="null"
    local s3_config_raw
    s3_config_raw=$(kubectl get secret "$DB_SECRET" -n "$NAMESPACE" \
        -o jsonpath='{.data.S3_BACKEND_ADDRESS}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [[ -n "$s3_config_raw" ]]; then
        local s3_bucket s3_key s3_secret s3_ssl
        s3_bucket=$(read_dsn "S3_BUCKET")
        s3_key=$(read_dsn "S3_KEY")
        s3_secret=$(read_dsn "S3_SECRET")
        s3_ssl=$(read_dsn "S3_SSL_ENABLED")
        s3_json=$(jq -n \
            --arg address "$s3_config_raw" \
            --arg bucket "$s3_bucket" \
            --arg key "$s3_key" \
            --arg ssl "$s3_ssl" \
            '{backend:{address:$address},bucket:$bucket,accesskeyid:$key,ssl:{enabled:$ssl}}')
        s3_data=$(collect_s3 "$s3_json")
    fi

    log "Формируем отчёт..."

    # Крупные строки через temp-файлы — обход лимита ARG_MAX
    local _t_k8s _t_auth _t_logs _t_certs _t_pg_rw _t_pg_ro
    _t_k8s=$(mktemp);   printf '%s' "$k8s_data"   > "$_t_k8s"
    _t_auth=$(mktemp);  printf '%s' "$auth_data"   > "$_t_auth"
    _t_logs=$(mktemp);  printf '%s' "$logs_data"   > "$_t_logs"
    _t_certs=$(mktemp); printf '%s' "$certs_data"  > "$_t_certs"
    _t_pg_rw=$(mktemp); printf '%s' "$pg_rw"       > "$_t_pg_rw"
    _t_pg_ro=$(mktemp); printf '%s' "$pg_ro"       > "$_t_pg_ro"

    jq -n \
        --arg collected_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg collector_version "2.0.0" \
        --arg namespace "$NAMESPACE" \
        --slurpfile k8s    "$_t_k8s" \
        --slurpfile pg_rw  "$_t_pg_rw" \
        --slurpfile pg_ro  "$_t_pg_ro" \
        --argjson mongo    "$mongo_data" \
        --argjson redis    "$redis_data" \
        --argjson rmq      "$rmq_data" \
        --slurpfile certs  "$_t_certs" \
        --slurpfile auth   "$_t_auth" \
        --slurpfile logs   "$_t_logs" \
        --argjson machine  "$machine_specs" \
        --argjson s3       "$s3_data" \
        '{
            meta: {
                collected_at: $collected_at,
                collector_version: $collector_version,
                namespace: $namespace,
                schema_version: "2.0"
            },
            cluster: $k8s[0],
            databases: {
                postgres_rw: $pg_rw[0],
                postgres_ro: $pg_ro[0],
                mongodb: $mongo,
                redis: $redis,
                rabbitmq: $rmq
            },
            infrastructure: {
                machine_specs: $machine,
                certificates: $certs[0]
            },
            s3: $s3,
            auth: $auth[0],
            logs: $logs[0]
        }' > "$REPORT_FILE"

    rm -f "$_t_k8s" "$_t_auth" "$_t_logs" "$_t_certs" "$_t_pg_rw" "$_t_pg_ro"

    gzip -f "$REPORT_FILE"
    REPORT_FILE="${REPORT_FILE}.gz"

    local archive_file="${OUTPUT_DIR}/diagnostics-${TIMESTAMP}.tar.gz"
    generate_diagnostics_archive "$archive_file"

    log "Готово:"
    log "  JSON для UI:           $REPORT_FILE ($(du -sh "$REPORT_FILE" | cut -f1))"

    local html_file
    html_file=$(generate_html_report "$REPORT_FILE")
    log "  HTML отчёт:             $html_file ($(du -sh "$html_file" | cut -f1))"
    log "  Диагностический архив: $archive_file ($(du -sh "$archive_file" | cut -f1))"
    log ""
    log "JSON → загрузи в веб-интерфейс:"
    log "  http://your-host/diagnostics  →  'Загрузить отчёт'"
    log ""
    log "Архив → передай инженеру для глубокого анализа"

    echo "$REPORT_FILE"
}

generate_diagnostics_archive() {
    local archive_file="$1"
    local work_dir
    work_dir=$(mktemp -d)
    local out="$work_dir/elma365-diagnostics-${TIMESTAMP}"
    mkdir -p "$out/pod_logs"

    log "Формируем диагностический архив..."

    local f_main="$out/main_info.txt"
    local f_desc="$out/describes.txt"
    local f_gen="$out/general_info.txt"

    _section() {
        local title="$1" cmd="$2" file="$3"
        printf '\n### %s\n$ %s\n' "$title" "$cmd" >> "$file"
        eval "$cmd" >> "$file" 2>&1 || echo "⚠ Command failed: $cmd" >> "$file"
    }

    _section "All resources in namespace ($NAMESPACE)" \
        "kubectl get all -n $NAMESPACE -o wide" "$f_main"

    _section "Horizontal Pod Autoscalers" \
        "kubectl get hpa -n $NAMESPACE" "$f_main"

    _section "ReplicaSets" \
        "kubectl get replicasets -n $NAMESPACE" "$f_main"

    {
        printf '\n### Container Resource Requests / Limits / Usage\n'
        declare -A _cpu_u _mem_u
        while read -r pod container cpu mem; do
            _cpu_u["$pod/$container"]=$cpu
            _mem_u["$pod/$container"]=$mem
        done < <(kubectl top pod -n "$NAMESPACE" --containers --no-headers 2>/dev/null)

        printf "%-45s %-20s %-10s %-10s %-10s %-10s %-10s %-10s\n" \
            "POD" "CONTAINER" "CPU_REQ" "MEM_REQ" "CPU_LIM" "MEM_LIM" "CPU_NOW" "MEM_NOW"
        printf '%s\n' "$(printf '─%.0s' {1..120})"

        kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null | jq -r '
            .items[] |
            .metadata.name as $p |
            .spec.containers[] |
            [$p, .name,
             (.resources.requests.cpu    // "-"),
             (.resources.requests.memory // "-"),
             (.resources.limits.cpu      // "-"),
             (.resources.limits.memory   // "-")] | @tsv
        ' | while IFS=$'\t' read -r pod ctr cpu_r mem_r cpu_l mem_l; do
            printf "%-45s %-20s %-10s %-10s %-10s %-10s %-10s %-10s\n" \
                "$pod" "$ctr" "$cpu_r" "$mem_r" "$cpu_l" "$mem_l" \
                "${_cpu_u["$pod/$ctr"]:-"—"}" "${_mem_u["$pod/$ctr"]:-"—"}"
        done
    } >> "$f_main"

    _section "Events (newest last)" \
        "kubectl get events -n $NAMESPACE --sort-by=.metadata.creationTimestamp" "$f_main"

    _section "ConfigMaps in namespace" \
        "kubectl get configmap -n $NAMESPACE" "$f_main"

    _section "Migration state" \
        "kubectl exec deploy/deploy -n $NAMESPACE -c deploy -- curl -sf -m 10 -H 'Accept: application/json' http://localhost:3000/migration/states" "$f_main"

    _section "Deployment logs (last 50)" \
        "kubectl logs deploy/deploy -n $NAMESPACE --tail=50" "$f_main"

    _section "Fatal logs (all ELMA365 pods)" \
        "kubectl logs -n $NAMESPACE -l tier=elma365 --all-containers --tail=500 2>/dev/null | grep '\"fatal\"'" "$f_main"

    _section "Error logs (all ELMA365 pods)" \
        "kubectl logs -n $NAMESPACE -l tier=elma365 --all-containers --tail=500 2>/dev/null | grep '\"error\"'" "$f_main"

    _section "Helm releases" \
        "helm list -n $NAMESPACE" "$f_main"

    _section "Helm status elma365" \
        "helm status elma365 -n $NAMESPACE" "$f_main"

    _section "Helm history elma365" \
        "helm history elma365 -n $NAMESPACE" "$f_main"

    _section "Node descriptions" \
        "kubectl describe nodes" "$f_desc"

    _section "Pod descriptions in namespace" \
        "kubectl describe pods -n $NAMESPACE" "$f_desc"

    _section "All resources (all namespaces)" \
        "kubectl get all -A -o wide" "$f_gen"

    _section "All ingresses" \
        "kubectl get ingress -A" "$f_gen"

    _section "All ConfigMaps" \
        "kubectl get configmap -A" "$f_gen"

    _section "All Secrets (names only)" \
        "kubectl get secret -A" "$f_gen"

    _section "All Namespaces" \
        "kubectl get ns" "$f_gen"

    _section "Nodes" \
        "kubectl get nodes -o wide" "$f_gen"

    _section "Node metrics" \
        "kubectl top nodes" "$f_gen"

    _section "Helm list (all namespaces)" \
        "helm list -A" "$f_gen"

    local pods_list
    pods_list=$(kubectl get pods -n "$NAMESPACE" \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null || echo "")

    for pod in $pods_list; do
        local containers
        containers=$(kubectl get pod "$pod" -n "$NAMESPACE" \
            -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || echo "")
        for ctr in $containers; do
            kubectl logs "$pod" -n "$NAMESPACE" -c "$ctr" \
                --timestamps 2>/dev/null \
                > "$out/pod_logs/${pod}__${ctr}.log" \
                || echo "failed to get logs" > "$out/pod_logs/${pod}__${ctr}.log"
        done
    done

    tar -czf "$archive_file" -C "$work_dir" "elma365-diagnostics-${TIMESTAMP}"
    rm -rf "$work_dir"
}

main "$@"
