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
    log "  JSON для сервиса:      $REPORT_FILE ($(du -sh "$REPORT_FILE" | cut -f1))"
    log "  Диагностический архив: $archive_file ($(du -sh "$archive_file" | cut -f1))"
    log ""
    log "Загрузи JSON в сервис диагностики:"
    log "  curl -F 'report=@$REPORT_FILE' http://diag.riva.elewise.local/api/upload"
    log ""
    log "Или через браузер: http://diag.riva.elewise.local/"
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
