#!/bin/bash
SOCKET="/var/run/docker.sock"
PORT=8090
WEB_ROOT="/tmp/metrics_www"
DATA_FILE="$WEB_ROOT/metrics.prom"
NGINX_STATUS_URL="${NGINX_STATUS_URL:-http://nginx/nginx_status}"

mkdir -p "$WEB_ROOT"

collect_data() {
    while true; do
        TMP_FILE="/tmp/stats_new.prom"
        > "$TMP_FILE"

        # =====================================================================
        # 1. HOST HARDWARE METRICS (NATIVE BASH)
        # =====================================================================

        # 1a. System Uptime
        if [[ -f /proc/uptime ]]; then
            uptime_seconds=$(awk '{print $1}' /proc/uptime)
            echo "# HELP node_uptime_seconds_total System uptime." >> "$TMP_FILE"
            echo "# TYPE node_uptime_seconds_total counter" >> "$TMP_FILE"
            echo "node_uptime_seconds_total $uptime_seconds" >> "$TMP_FILE"
        fi

        # 1b. CPU Package Power (Intel/AMD RAPL)
        for rapl in /sys/class/powercap/intel-rapl/intel-rapl:*; do
            if [[ -d "$rapl" ]] && grep -qi "package" "$rapl/name" 2>/dev/null; then
                e1=$(cat "$rapl/energy_uj" 2>/dev/null)
                sleep 0.1
                e2=$(cat "$rapl/energy_uj" 2>/dev/null)
                if [[ -n "$e1" && -n "$e2" ]]; then
                    power_watts=$(awk -v e1="$e1" -v e2="$e2" 'BEGIN {print ((e2 - e1) / 1000000.0) / 0.1}')
                    echo "# HELP node_cpu_power_watts CPU power draw." >> "$TMP_FILE"
                    echo "# TYPE node_cpu_power_watts gauge" >> "$TMP_FILE"
                    echo "node_cpu_power_watts $power_watts" >> "$TMP_FILE"
                fi
                break
            fi
        done

        # 1c. CPU Core Temperatures
        has_temp_header=0
        for hwmon in /sys/class/hwmon/hwmon*; do
            if [[ -f "$hwmon/name" ]] && grep -q "coretemp" "$hwmon/name"; then
                for label_path in "$hwmon"/temp*_label; do
                    [[ -e "$label_path" ]] || continue
                    label=$(cat "$label_path" 2>/dev/null)
                    if [[ "$label" == Core* ]]; then
                        core_id="${label##* }"
                        input_path="${label_path%_label}_input"
                        if [[ -f "$input_path" ]]; then
                            temp_raw=$(cat "$input_path" 2>/dev/null)
                            temp_celsius=$(awk -v r="$temp_raw" 'BEGIN {printf "%.1f", r/1000}')
                            if [[ $has_temp_header -eq 0 ]]; then
                                echo "# HELP node_cpu_core_temperature_celsius Core temperature." >> "$TMP_FILE"
                                echo "# TYPE node_cpu_core_temperature_celsius gauge" >> "$TMP_FILE"
                                has_temp_header=1
                            fi
                            echo "node_cpu_core_temperature_celsius{core=\"$core_id\"} $temp_celsius" >> "$TMP_FILE"
                        fi
                    fi
                done
            fi
        done

        # 1d. CPU Core Usages (Reads /proc/stat twice over 0.2 seconds)
        declare -A idle1 total1
        while read -r line; do
            if [[ "$line" =~ ^cpu[0-9]+ ]]; then
                read -r cpu_name user nice sys idle iowait irq softirq steal guest guest_nice <<< "$line"
                core_id="${cpu_name#cpu}"
                idle1[$core_id]=$((idle + iowait))
                total1[$core_id]=$((user + nice + sys + idle + iowait + irq + softirq + steal))
            fi
        done < /proc/stat

        sleep 0.2

        has_usage_header=0
        while read -r line; do
            if [[ "$line" =~ ^cpu[0-9]+ ]]; then
                read -r cpu_name user nice sys idle iowait irq softirq steal guest guest_nice <<< "$line"
                core_id="${cpu_name#cpu}"
                id2=$((idle + iowait))
                tot2=$((user + nice + sys + idle + iowait + irq + softirq + steal))
                id_delta=$((id2 - idle1[$core_id]))
                tot_delta=$((tot2 - total1[$core_id]))
                if [[ $tot_delta -gt 0 ]]; then
                    usage_pct=$(awk -v id="$id_delta" -v tot="$tot_delta" 'BEGIN {printf "%.1f", (1.0 - (id / tot)) * 100}')
                    if [[ $has_usage_header -eq 0 ]]; then
                        echo "# HELP node_cpu_core_usage_percent Core usage percentage." >> "$TMP_FILE"
                        echo "# TYPE node_cpu_core_usage_percent gauge" >> "$TMP_FILE"
                        has_usage_header=1
                    fi
                    echo "node_cpu_core_usage_percent{core=\"$core_id\"} $usage_pct" >> "$TMP_FILE"
                fi
            fi
        done < /proc/stat

        # 1e. CPU Total Usage (aggregate cpu line)
        read -r cpu_name user nice sys idle iowait irq softirq steal guest guest_nice < <(grep '^cpu ' /proc/stat)
        cpu_total_idle=$((idle + iowait))
        cpu_total_all=$((user + nice + sys + idle + iowait + irq + softirq + steal))
        sleep 0.2
        read -r cpu_name user nice sys idle iowait irq softirq steal guest guest_nice < <(grep '^cpu ' /proc/stat)
        cpu_total_idle2=$((idle + iowait))
        cpu_total_all2=$((user + nice + sys + idle + iowait + irq + softirq + steal))
        id_d=$((cpu_total_idle2 - cpu_total_idle))
        tot_d=$((cpu_total_all2  - cpu_total_all))
        if [[ $tot_d -gt 0 ]]; then
            cpu_total_pct=$(awk -v id="$id_d" -v tot="$tot_d" 'BEGIN {printf "%.1f", (1.0 - (id/tot)) * 100}')
            echo "# HELP node_cpu_total_usage_percent Total CPU usage across all cores." >> "$TMP_FILE"
            echo "# TYPE node_cpu_total_usage_percent gauge" >> "$TMP_FILE"
            echo "node_cpu_total_usage_percent $cpu_total_pct" >> "$TMP_FILE"
        fi

        # 1f. Load Average
        if [[ -f /proc/loadavg ]]; then
            read -r load1 load5 load15 _ < /proc/loadavg
            echo "# HELP node_load_average System load average." >> "$TMP_FILE"
            echo "# TYPE node_load_average gauge" >> "$TMP_FILE"
            echo "node_load_average{interval=\"1m\"}  $load1"  >> "$TMP_FILE"
            echo "node_load_average{interval=\"5m\"}  $load5"  >> "$TMP_FILE"
            echo "node_load_average{interval=\"15m\"} $load15" >> "$TMP_FILE"
        fi

        # 1g. Host Memory
        if [[ -f /proc/meminfo ]]; then
            mem_total=$(awk '/^MemTotal:/     {print $2 * 1024}' /proc/meminfo)
            mem_avail=$(awk '/^MemAvailable:/ {print $2 * 1024}' /proc/meminfo)
            mem_buffers=$(awk '/^Buffers:/    {print $2 * 1024}' /proc/meminfo)
            mem_cached=$(awk '/^Cached:/      {print $2 * 1024}' /proc/meminfo)
            echo "# HELP node_memory_total_bytes Total system RAM." >> "$TMP_FILE"
            echo "# TYPE node_memory_total_bytes gauge" >> "$TMP_FILE"
            echo "node_memory_total_bytes $mem_total" >> "$TMP_FILE"
            echo "# HELP node_memory_available_bytes Available system RAM." >> "$TMP_FILE"
            echo "# TYPE node_memory_available_bytes gauge" >> "$TMP_FILE"
            echo "node_memory_available_bytes $mem_avail" >> "$TMP_FILE"
            echo "# HELP node_memory_buffers_bytes Memory used by kernel buffers." >> "$TMP_FILE"
            echo "# TYPE node_memory_buffers_bytes gauge" >> "$TMP_FILE"
            echo "node_memory_buffers_bytes $mem_buffers" >> "$TMP_FILE"
            echo "# HELP node_memory_cached_bytes Memory used by page cache." >> "$TMP_FILE"
            echo "# TYPE node_memory_cached_bytes gauge" >> "$TMP_FILE"
            echo "node_memory_cached_bytes $mem_cached" >> "$TMP_FILE"
        fi

        # 1h. Host Network (per interface from /proc/net/dev)
        has_net_header=0
        while read -r line; do
            # skip header lines
            [[ "$line" == *"|"* ]] && continue
            iface=$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')
            [[ -z "$iface" ]] && continue
            rx_bytes=$(echo "$line" | awk '{print $2}')
            tx_bytes=$(echo "$line" | awk '{print $10}')
            if [[ $has_net_header -eq 0 ]]; then
                echo "# HELP node_network_receive_bytes_total Host interface received bytes." >> "$TMP_FILE"
                echo "# TYPE node_network_receive_bytes_total counter" >> "$TMP_FILE"
                echo "# HELP node_network_transmit_bytes_total Host interface transmitted bytes." >> "$TMP_FILE"
                echo "# TYPE node_network_transmit_bytes_total counter" >> "$TMP_FILE"
                has_net_header=1
            fi
            echo "node_network_receive_bytes_total{interface=\"$iface\"}  $rx_bytes" >> "$TMP_FILE"
            echo "node_network_transmit_bytes_total{interface=\"$iface\"} $tx_bytes" >> "$TMP_FILE"
        done < /proc/net/dev

        # 1i. Disk Space (per mount point)
        has_disk_header=0
        while IFS= read -r line; do
            mountpoint=$(echo "$line" | awk '{print $6}')
            # only real filesystems — skip pseudo mounts
            fstype=$(echo "$line" | awk '{print $1}')
            [[ "$fstype" == tmpfs || "$fstype" == devtmpfs || "$fstype" == sysfs || \
               "$fstype" == proc  || "$fstype" == cgroup*  || "$fstype" == overlay ]] && continue
            [[ -z "$mountpoint" ]] && continue

            read -r size_kb used_kb avail_kb _ < <(df -k --output=size,used,avail "$mountpoint" 2>/dev/null | tail -1)
            [[ -z "$size_kb" ]] && continue

            size_bytes=$((size_kb  * 1024))
            used_bytes=$((used_kb  * 1024))
            avail_bytes=$((avail_kb * 1024))
            mp_label="${mountpoint//\"/\\\"}"

            if [[ $has_disk_header -eq 0 ]]; then
                echo "# HELP node_disk_total_bytes Disk total size." >> "$TMP_FILE"
                echo "# TYPE node_disk_total_bytes gauge" >> "$TMP_FILE"
                echo "# HELP node_disk_used_bytes Disk used space." >> "$TMP_FILE"
                echo "# TYPE node_disk_used_bytes gauge" >> "$TMP_FILE"
                echo "# HELP node_disk_available_bytes Disk available space." >> "$TMP_FILE"
                echo "# TYPE node_disk_available_bytes gauge" >> "$TMP_FILE"
                has_disk_header=1
            fi
            echo "node_disk_total_bytes{mountpoint=\"$mp_label\"}     $size_bytes"  >> "$TMP_FILE"
            echo "node_disk_used_bytes{mountpoint=\"$mp_label\"}      $used_bytes"  >> "$TMP_FILE"
            echo "node_disk_available_bytes{mountpoint=\"$mp_label\"} $avail_bytes" >> "$TMP_FILE"
        done < /proc/mounts

        # 1j. Disk I/O (from /proc/diskstats — physical devices only)
        has_diskio_header=0
        while read -r _ _ dev reads _ sectors_read _ writes _ sectors_written _; do
            # skip loop, ram, dm devices; keep sd*, nvme*, vd*, xvd*
            [[ "$dev" =~ ^(loop|ram|dm) ]] && continue
            [[ "$dev" =~ ^(sd|nvme|vd|xvd) ]] || continue
            read_bytes=$((sectors_read    * 512))
            write_bytes=$((sectors_written * 512))
            if [[ $has_diskio_header -eq 0 ]]; then
                echo "# HELP node_disk_read_bytes_total Disk bytes read." >> "$TMP_FILE"
                echo "# TYPE node_disk_read_bytes_total counter" >> "$TMP_FILE"
                echo "# HELP node_disk_written_bytes_total Disk bytes written." >> "$TMP_FILE"
                echo "# TYPE node_disk_written_bytes_total counter" >> "$TMP_FILE"
                has_diskio_header=1
            fi
            echo "node_disk_read_bytes_total{device=\"$dev\"}    $read_bytes"  >> "$TMP_FILE"
            echo "node_disk_written_bytes_total{device=\"$dev\"} $write_bytes" >> "$TMP_FILE"
        done < /proc/diskstats

        # =====================================================================
        # 2. NGINX STUB_STATUS METRICS
        # =====================================================================
        nginx_body=$(curl -sf --max-time 2 "$NGINX_STATUS_URL" 2>/dev/null)
        if [[ -n "$nginx_body" ]]; then
            nginx_active=$(echo "$nginx_body"  | awk '/^Active connections:/ {print $3}')
            nginx_accepts=$(echo "$nginx_body" | awk 'NR==3 {print $1}')
            nginx_handled=$(echo "$nginx_body" | awk 'NR==3 {print $2}')
            nginx_requests=$(echo "$nginx_body"| awk 'NR==3 {print $3}')
            nginx_reading=$(echo "$nginx_body" | awk '/Reading:/ {print $2}')
            nginx_writing=$(echo "$nginx_body" | awk '/Reading:/ {print $4}')
            nginx_waiting=$(echo "$nginx_body" | awk '/Reading:/ {print $6}')

            cat >> "$TMP_FILE" <<'EOF'
# HELP nginx_connections_active Number of active client connections including waiting.
# TYPE nginx_connections_active gauge
EOF
            echo "nginx_connections_active $nginx_active"   >> "$TMP_FILE"
            cat >> "$TMP_FILE" <<'EOF'
# HELP nginx_connections_accepted_total Total accepted connections.
# TYPE nginx_connections_accepted_total counter
EOF
            echo "nginx_connections_accepted_total $nginx_accepts"  >> "$TMP_FILE"
            cat >> "$TMP_FILE" <<'EOF'
# HELP nginx_connections_handled_total Total handled connections.
# TYPE nginx_connections_handled_total counter
EOF
            echo "nginx_connections_handled_total $nginx_handled"   >> "$TMP_FILE"
            cat >> "$TMP_FILE" <<'EOF'
# HELP nginx_http_requests_total Total client requests.
# TYPE nginx_http_requests_total counter
EOF
            echo "nginx_http_requests_total $nginx_requests"        >> "$TMP_FILE"
            cat >> "$TMP_FILE" <<'EOF'
# HELP nginx_connections_reading Connections where nginx is reading the request header.
# TYPE nginx_connections_reading gauge
EOF
            echo "nginx_connections_reading $nginx_reading"         >> "$TMP_FILE"
            cat >> "$TMP_FILE" <<'EOF'
# HELP nginx_connections_writing Connections where nginx is writing a response.
# TYPE nginx_connections_writing gauge
EOF
            echo "nginx_connections_writing $nginx_writing"         >> "$TMP_FILE"
            cat >> "$TMP_FILE" <<'EOF'
# HELP nginx_connections_waiting Idle keepalive connections.
# TYPE nginx_connections_waiting gauge
EOF
            echo "nginx_connections_waiting $nginx_waiting"         >> "$TMP_FILE"
        fi

        # =====================================================================
        # 3. DOCKER CONTAINER METRICS
        # =====================================================================
        curl -s --unix-socket "$SOCKET" http://localhost/containers/json | \
            jq -r '.[] | [.Id, (.Names[0] | ltrimstr("/")), .Image, (.Id[:12])] | @tsv' \
            > /tmp/ids.tmp 2>/dev/null

        while IFS=$'\t' read -r clean_id name image short_id || [[ -n "$clean_id" ]]; do
            [[ -z "$clean_id" ]] && continue
            curl -s --unix-socket "$SOCKET" \
                "http://localhost/containers/${clean_id}/stats?stream=false" | \
            jq -r --arg id "$clean_id" --arg name "$name" --arg image "$image" --arg short_id "$short_id" '
                def labels: "{container=\"" + $name + "\",id=\"" + $id + "\",image=\"" + $image + "\"}";
                "container_memory_usage_bytes"              + labels + " " + (.memory_stats.usage // 0 | tostring),
                "container_memory_limit_bytes"             + labels + " " + (.memory_stats.limit // 0 | tostring),
                "container_cpu_usage_total_nanoseconds"    + labels + " " + (.cpu_stats.cpu_usage.total_usage // 0 | tostring),
                "container_cpu_system_usage_nanoseconds"   + labels + " " + (.cpu_stats.system_cpu_usage // 0 | tostring),
                "container_network_receive_bytes_total"    + labels + " " + (.networks.eth0.rx_bytes // 0 | tostring),
                "container_network_transmit_bytes_total"   + labels + " " + (.networks.eth0.tx_bytes // 0 | tostring),
                "container_blkio_io_service_bytes_total"   + labels + " " + (
                    [.blkio_stats.io_service_bytes_recursive[]?.value] | add // 0 | tostring
                )
            ' >> "$TMP_FILE" 2>/dev/null

            # 3a. Container restart count + OOM killed flag
            curl -s --unix-socket "$SOCKET" \
                "http://localhost/containers/${clean_id}/json" | \
            jq -r --arg name "$name" --arg image "$image" --arg id "$clean_id" '
                "container_restart_count{container=\"" + $name + "\",image=\"" + $image + "\"} " + (.RestartCount // 0 | tostring),
                "container_oom_killed{container=\""    + $name + "\",image=\"" + $image + "\"} " + (if .State.OOMKilled then "1" else "0" end),
                "container_running{container=\""       + $name + "\",image=\"" + $image + "\"} " + (if .State.Running  then "1" else "0" end),
                "container_started_at_seconds{container=\"" + $name + "\",image=\"" + $image + "\"} " + (.State.StartedAt | if . then (gsub("\\.[0-9]+Z$";"Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime | tostring) else "0" end)
            ' >> "$TMP_FILE" 2>/dev/null
        done < /tmp/ids.tmp

        cat >> "$TMP_FILE" <<'EOF'
# HELP container_restart_count Number of times the container has restarted.
# TYPE container_restart_count gauge
# HELP container_oom_killed 1 if container was OOM killed.
# TYPE container_oom_killed gauge
# HELP container_running 1 if container is currently running.
# TYPE container_running gauge
# HELP container_started_at_seconds Unix timestamp when container last started.
# TYPE container_started_at_seconds gauge
EOF

        # Atomic swap: write to a temp file inside the web root, then rename.
        # rename() is atomic on the same filesystem, so httpd never serves a
        # half-written file, and there's no listen/accept race like with `nc`.
        cp "$TMP_FILE" "$WEB_ROOT/.metrics.tmp"
        mv "$WEB_ROOT/.metrics.tmp" "$DATA_FILE"

        sleep 5
    done
}

# =====================================================================
# HTTP SERVER — busybox httpd instead of a hand-rolled `nc -l` loop.
#
# Why this fixes the data race:
#   `nc -l -p PORT` only binds, accepts ONE connection, then exits.
#   Looping it means there's a window after one `nc` exits and before
#   the next one re-binds the port where the socket isn't listening at
#   all (connection refused), and under concurrent scrapers two loop
#   iterations can race to bind the same port. There's no concurrency
#   control and no keep-alive support either.
#
#   busybox httpd is a proper forking HTTP daemon: it binds the port
#   once, stays listening, and handles each request in its own
#   connection without racing itself. Since we just want to serve a
#   single static file (Prometheus text-format metrics), we point it
#   at $WEB_ROOT and let it serve $DATA_FILE as a normal static GET.
# =====================================================================

serve() {
    cat > "$WEB_ROOT/httpd.conf" <<'EOF'
.prom:text/plain
EOF
    exec httpd -f -p "$PORT" -h "$WEB_ROOT" -c "$WEB_ROOT/httpd.conf"
}

collect_data &
COLLECTOR_PID=$!
trap "kill $COLLECTOR_PID 2>/dev/null; exit" SIGINT SIGTERM

echo "Waiting for initial data collection..."
sleep 6
echo "Metrics server running on port $PORT (busybox httpd, serving $DATA_FILE)"
echo "Scrape target should be configured as: http://<host>:$PORT/metrics.prom"
serve