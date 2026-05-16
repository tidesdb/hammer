#!/usr/bin/env bash
#
# mariadb_engines_runner.sh
#
# Orchestrates a 3-iteration TPC-C sweep across InnoDB, MyRocks, and TidesDB
# using the HammerDB harness (hammerdb_runner.sh), then merges the
# per-iteration CSVs into a single set of paper-grade charts with min/max
# error bars.
#
# Layout per run:
#   ./results_<timestamp>/
#     preflight.log
#     journal.txt                       # records completed iterations for resume
#     <engine>/
#       iter1/                          # contains hammerdb_results_*.csv + logs
#       iter2/
#       iter3/
#     final/
#       merged/                         # combined min/max charts across all engines
#
# Usage:
#   ./mariadb_engines_runner.sh                            # full sweep, defaults
#   ./mariadb_engines_runner.sh --iterations 1 --duration 60    # one long run instead
#   ./mariadb_engines_runner.sh --engines tidesdb,rocksdb       # subset
#   ./mariadb_engines_runner.sh --resume results_20260516_120000  # resume aborted run
#

set -uo pipefail   # no -e: we want to keep going even if an iter fails

HARNESS="${HARNESS:-$HOME/hammerdb_runner.sh}"
HAMMERDB_DIR="${HAMMERDB_DIR:-$HOME/HammerDB-5.0}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASS="${MYSQL_PASS:-}"
MYSQL_SOCKET="${MYSQL_SOCKET:-/tmp/mariadb.sock}"
MARIADB_SERVICE="${MARIADB_SERVICE:-mariadb}"
# MARIADB_DATA_DIR is auto-detected from `SELECT @@datadir` during pre-flight
# when not explicitly set, so the disk-space check reports the right volume.
MARIADB_DATA_DIR="${MARIADB_DATA_DIR:-}"

ENGINES="tidesdb,rocksdb,innodb"
ITERATIONS=3
WAREHOUSES=1000
BUILD_VU=6
RUN_VU=64
RAMPUP=7
DURATION=20
SETTLE=120
PERF=1
PERF_HZ=99
RANDOMIZE_ORDER=0      # default: fixed order tidesdb -> rocksdb -> innodb
DROP_OS_CACHE=1
RESTART_MARIADB=1
KEEP_SCHEMA_WITHIN_ENGINE=1
CLEANUP_BETWEEN_ENGINES=1   # drop previous engine's schema before next engine starts
RESUME_DIR=""
DRY_RUN=0
SKIP_PREFLIGHT=0

usage() {
    cat <<'EOF'
Usage: mariadb_engines_runner.sh [options]

  --engines E1,E2,...      Engines to test (default: tidesdb,rocksdb,innodb)
  --iterations N           Iterations per engine (default: 3)
  --warehouses N           TPC-C warehouses (default: 1000)
  --duration N             Measured minutes per iteration (default: 20)
  --rampup N               Rampup minutes per iteration (default: 7)
  --run-vu N               Virtual users (default: 64)
  --build-vu N             Build virtual users (default: 6)
  --settle N               Settle seconds after build (default: 120)
  --harness PATH           Path to tidesdb_rocksdb_hammerdb.sh
  --hammerdb-dir PATH      HammerDB install dir (default: ~/HammerDB-5.0)
  --socket PATH            MariaDB socket
  --user NAME              MariaDB user
  --pass PASS              MariaDB password (or set MYSQL_PASS env)
  --no-perf                Skip perf record
  --no-restart             Don't restart mariadbd between iterations
                            (faster, but cache-warm bias)
  --no-drop-cache          Don't drop OS page cache between iterations
  --no-keep-schema         Rebuild schema for every iteration
                            (much slower, only useful for catastrophic schema bugs)
  --no-cleanup-between-engines
                           Don't drop previous engine's schema before next engine
                            (uses more disk, but lets you re-inspect prior data)
  --randomize              Random engine order each invocation
  --resume DIR             Resume a previous results_<ts>/ run
  --dry-run                Print what would run, don't actually do it
  --skip-preflight         Skip pre-flight checks (you should know why)
  -h, --help               This message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engines)      ENGINES="$2"; shift 2;;
        --iterations)   ITERATIONS="$2"; shift 2;;
        --warehouses)   WAREHOUSES="$2"; shift 2;;
        --duration)     DURATION="$2"; shift 2;;
        --rampup)       RAMPUP="$2"; shift 2;;
        --run-vu)       RUN_VU="$2"; shift 2;;
        --build-vu)     BUILD_VU="$2"; shift 2;;
        --settle)       SETTLE="$2"; shift 2;;
        --harness)      HARNESS="$2"; shift 2;;
        --hammerdb-dir) HAMMERDB_DIR="$2"; shift 2;;
        --socket)       MYSQL_SOCKET="$2"; shift 2;;
        --user)         MYSQL_USER="$2"; shift 2;;
        --pass)         MYSQL_PASS="$2"; shift 2;;
        --no-perf)      PERF=0; shift;;
        --no-restart)   RESTART_MARIADB=0; shift;;
        --no-drop-cache) DROP_OS_CACHE=0; shift;;
        --no-keep-schema) KEEP_SCHEMA_WITHIN_ENGINE=0; shift;;
        --no-cleanup-between-engines) CLEANUP_BETWEEN_ENGINES=0; shift;;
        --randomize)    RANDOMIZE_ORDER=1; shift;;
        --resume)       RESUME_DIR="$2"; shift 2;;
        --dry-run)      DRY_RUN=1; shift;;
        --skip-preflight) SKIP_PREFLIGHT=1; shift;;
        -h|--help)      usage;;
        *)              echo "Unknown option: $1" >&2; exit 2;;
    esac
done

IFS=',' read -ra ENGINE_LIST <<< "$ENGINES"
if [[ "$RANDOMIZE_ORDER" -eq 1 ]]; then
    n=${#ENGINE_LIST[@]}
    for ((i = n - 1; i > 0; i--)); do
        j=$((RANDOM % (i + 1)))
        tmp="${ENGINE_LIST[$i]}"
        ENGINE_LIST[$i]="${ENGINE_LIST[$j]}"
        ENGINE_LIST[$j]="$tmp"
    done
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
if [[ -n "$RESUME_DIR" ]]; then
    if [[ ! -d "$RESUME_DIR" ]]; then
        echo "Resume dir not found: $RESUME_DIR" >&2
        exit 1
    fi
    RESULTS_DIR="$RESUME_DIR"
    echo "[$(date +%H:%M:%S)] Resuming from $RESULTS_DIR"
else
    RESULTS_DIR="results_${TIMESTAMP}"
    mkdir -p "$RESULTS_DIR/final/merged"
fi

JOURNAL="$RESULTS_DIR/journal.txt"
MASTER_LOG="$RESULTS_DIR/master.log"
touch "$JOURNAL"

# Tee everything to master.log
exec > >(tee -a "$MASTER_LOG") 2>&1

# Capture Ctrl-C / SIGTERM so the journal records that we bailed.  Without
# this a long sweep that gets interrupted looks identical in the artefacts
# to one that finished cleanly until you eyeball the iter count.
on_signal() {
    local sig="$1"
    echo "interrupted_at=$(date +%Y-%m-%dT%H:%M:%S%z) signal=$sig" >> "$JOURNAL"
    warn "Caught $sig -- aborting; rerun with --resume $RESULTS_DIR to pick up."
    exit 130
}
trap 'on_signal SIGINT'  INT
trap 'on_signal SIGTERM' TERM

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
die()  { echo "[$(date +%H:%M:%S)] FATAL: $*" >&2; exit 1; }

journal_has() {
    local marker="$1"
    grep -qxF "$marker" "$JOURNAL" 2>/dev/null
}
journal_add() {
    local marker="$1"
    echo "$marker" >> "$JOURNAL"
}

# Detect which client binary is on PATH.  Modern MariaDB-only installs ship
# only `mariadb`; older / mixed installs still have `mysql`.  Prefer whichever
# is available so the script works on either.
MYSQL_CLI=""
for _cli in mariadb mysql; do
    if command -v "$_cli" >/dev/null 2>&1; then
        MYSQL_CLI="$_cli"
        break
    fi
done

mysql_query() {
    [[ -z "$MYSQL_CLI" ]] && return 1
    if [[ -n "$MYSQL_PASS" ]]; then
        "$MYSQL_CLI" -u "$MYSQL_USER" -p"$MYSQL_PASS" -S "$MYSQL_SOCKET" -BN -e "$1" 2>/dev/null
    else
        "$MYSQL_CLI" -u "$MYSQL_USER" -S "$MYSQL_SOCKET" -BN -e "$1" 2>/dev/null
    fi
}

restart_mariadb() {
    log "Restarting mariadbd..."
    if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl restart "$MARIADB_SERVICE" || die "systemctl restart failed"
    else
        sudo service "$MARIADB_SERVICE" restart || die "service restart failed"
    fi
    # Wait for socket to come back
    local tries=60
    while ! mysql_query "SELECT 1" >/dev/null 2>&1; do
        ((tries--))
        if [[ $tries -le 0 ]]; then
            die "mariadbd did not come back up within 60s"
        fi
        sleep 1
    done
    log "mariadbd is up"
}

drop_os_cache() {
    log "Dropping OS page cache (sync + drop_caches=3)..."
    sync
    if [[ -w /proc/sys/vm/drop_caches ]]; then
        echo 3 > /proc/sys/vm/drop_caches
    else
        echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    fi
}

preflight() {
    log "=== PRE-FLIGHT CHECKS ==="
    local fail=0

    # Harness exists and is executable
    if [[ ! -x "$HARNESS" ]]; then
        warn "Harness not executable: $HARNESS"
        fail=1
    fi

    # HammerDB dir
    if [[ ! -d "$HAMMERDB_DIR" ]]; then
        warn "HammerDB dir missing: $HAMMERDB_DIR"
        fail=1
    fi

    # Client binary
    if [[ -z "$MYSQL_CLI" ]]; then
        warn "neither 'mariadb' nor 'mysql' client on PATH"
        fail=1
    else
        log "Client binary: $MYSQL_CLI"
    fi

    # MariaDB reachable
    if ! mysql_query "SELECT VERSION()" >/dev/null; then
        warn "Cannot connect to MariaDB at $MYSQL_SOCKET as $MYSQL_USER"
        fail=1
    else
        log "MariaDB version: $(mysql_query 'SELECT VERSION()')"
        # Auto-detect data dir from the live server when not overridden.
        if [[ -z "$MARIADB_DATA_DIR" ]]; then
            MARIADB_DATA_DIR=$(mysql_query "SELECT @@datadir" | tr -d ' ')
            [[ -n "$MARIADB_DATA_DIR" ]] && log "Data dir (auto): $MARIADB_DATA_DIR"
        fi
    fi

    # All requested engines available
    local engines_avail
    engines_avail=$(mysql_query "SELECT LOWER(engine) FROM information_schema.engines WHERE support IN ('YES','DEFAULT')")
    for eng in "${ENGINE_LIST[@]}"; do
        local needle
        case "$eng" in
            rocksdb) needle="rocksdb" ;;
            tidesdb) needle="tidesdb" ;;
            innodb)  needle="innodb"  ;;
            *)       warn "Unknown engine: $eng"; fail=1; continue ;;
        esac
        if ! echo "$engines_avail" | grep -qxF "$needle"; then
            warn "Engine '$eng' not loaded in mariadbd"
            fail=1
        else
            log "Engine present: $eng"
        fi
    done

    # Disk space, 100GB warehouse + compaction headroom = need ~200GB free
    local free_gb
    free_gb=$(df -BG --output=avail "$MARIADB_DATA_DIR" 2>/dev/null | tail -1 | tr -d ' G')
    if [[ -n "$free_gb" && "$free_gb" -lt 200 ]]; then
        warn "Free disk space on $MARIADB_DATA_DIR is ${free_gb}G - recommended >= 200G"
        # not fatal, warn only
    else
        log "Free disk space: ${free_gb}G"
    fi

    # ulimit -n  (must be high for rocksdb_max_open_files=-1)
    local mdbpid
    mdbpid=$(pgrep -x mariadbd | head -1)
    if [[ -n "$mdbpid" && -r "/proc/$mdbpid/limits" ]]; then
        local nofile
        nofile=$(awk '/Max open files/ {print $4}' "/proc/$mdbpid/limits")
        if [[ -n "$nofile" && "$nofile" -lt 65536 ]]; then
            warn "mariadbd open-files limit is $nofile - recommended >= 65536"
        else
            log "mariadbd Max open files: $nofile"
        fi
    fi

    # CPU governor - warn if not performance
    if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        local gov
        gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
        if [[ "$gov" != "performance" ]]; then
            warn "CPU governor is '$gov' - recommend 'performance' for benchmarking"
            warn "  Fix:  sudo cpupower frequency-set -g performance"
        else
            log "CPU governor: $gov"
        fi
    fi

    # Transparent huge pages - warn if 'always'
    if [[ -r /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        local thp
        thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled)
        if [[ "$thp" == *"[always]"* ]]; then
            warn "Transparent huge pages: [always] - recommend [madvise] for benchmarking"
            warn "  Fix:  echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"
        else
            log "Transparent huge pages: $thp"
        fi
    fi

    # NUMA balancing - warn if on
    if [[ -r /proc/sys/kernel/numa_balancing ]]; then
        local nb
        nb=$(cat /proc/sys/kernel/numa_balancing)
        if [[ "$nb" == "1" ]]; then
            warn "NUMA balancing is ON (kernel.numa_balancing=1) - recommend 0 for benchmarking"
            warn "  Fix:  sudo sysctl kernel.numa_balancing=0"
        fi
    fi

    # Drop-caches needs root or sudo
    if [[ "$DROP_OS_CACHE" -eq 1 && ! -w /proc/sys/vm/drop_caches ]]; then
        if ! sudo -n true 2>/dev/null; then
            warn "DROP_OS_CACHE=1 but no password-less sudo available - cache drop will prompt for password"
        fi
    fi

    if [[ "$fail" -eq 1 ]]; then
        die "Pre-flight checks failed - fix the issues above or pass --skip-preflight"
    fi

    log "=== PRE-FLIGHT OK ==="
}

if [[ "$SKIP_PREFLIGHT" -eq 0 ]]; then
    preflight | tee "$RESULTS_DIR/preflight.log"
fi

TOTAL_ITERS=$((${#ENGINE_LIST[@]} * ITERATIONS))
EST_MIN_PER_ITER=$((RAMPUP + DURATION + 3))  # +3 for restart/build query/etc overhead
EST_BUILD_MIN=30                              # rough estimate per engine
EST_TOTAL_MIN=$(( ${#ENGINE_LIST[@]} * EST_BUILD_MIN + TOTAL_ITERS * EST_MIN_PER_ITER ))

log ""
log "=== PLAN ==="
log "Results dir:  $RESULTS_DIR"
log "Engines:      ${ENGINE_LIST[*]}"
log "Iterations:   $ITERATIONS per engine"
log "Warehouses:   $WAREHOUSES"
log "Rampup:       ${RAMPUP}m  Duration: ${DURATION}m  Settle: ${SETTLE}s"
log "VUs:          build=$BUILD_VU run=$RUN_VU"
log "Perf:         $([[ $PERF -eq 1 ]] && echo on || echo off)"
log "Restart:      $([[ $RESTART_MARIADB -eq 1 ]] && echo on || echo off)"
log "Drop OS cache: $([[ $DROP_OS_CACHE -eq 1 ]] && echo on || echo off)"
log "Keep schema:  $([[ $KEEP_SCHEMA_WITHIN_ENGINE -eq 1 ]] && echo on || echo off)"
log "Cleanup between engines: $([[ $CLEANUP_BETWEEN_ENGINES -eq 1 ]] && echo on || echo off)"
log ""
log "Estimated total runtime: ~$EST_TOTAL_MIN minutes ($(printf '%.1f' "$(echo "scale=2; $EST_TOTAL_MIN/60" | bc)") hours)"
log ""

if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY RUN - exiting before executing benchmark"
    exit 0
fi

START_TIME=$(date +%s)

for ENG in "${ENGINE_LIST[@]}"; do
    log ""
    log "============================================================"
    log "  ENGINE: $ENG"
    log "============================================================"

    ENG_DIR="$RESULTS_DIR/$ENG"
    mkdir -p "$ENG_DIR"

    for ((ITER = 1; ITER <= ITERATIONS; ITER++)); do
        MARKER="${ENG}_iter${ITER}_done"
        if journal_has "$MARKER"; then
            log "Iteration $ITER/$ITERATIONS for $ENG already complete (journal) - skipping"
            continue
        fi

        ITER_DIR="$ENG_DIR/iter${ITER}"
        mkdir -p "$ITER_DIR"

        log ""
        log "--- Iteration $ITER/$ITERATIONS for $ENG ---"

        # Cold cache between iterations
        if [[ "$RESTART_MARIADB" -eq 1 ]]; then
            restart_mariadb
        fi
        if [[ "$DROP_OS_CACHE" -eq 1 ]]; then
            drop_os_cache
        fi

        # Pre-iter schema policy:
        #
        # KEEP_SCHEMA_WITHIN_ENGINE=1 + iter 1 of this engine:
        #   drop the previous engine's leftover tpcc (if any), then let the
        #   harness build a fresh one.
        # KEEP_SCHEMA_WITHIN_ENGINE=1 + iter N>1 AND the previous iter for
        #   this engine completed cleanly (journal marker present):
        #   leave tpcc alone -- the harness will detect it and skip the
        #   build, saving ~30 min.
        # KEEP_SCHEMA_WITHIN_ENGINE=1 + iter N>1 but previous iter FAILED
        #   (no journal marker, we're retrying via --resume):
        #   drop tpcc.  A failed iter may have left the schema in a partial
        #   state that --keep-schema would silently reuse otherwise.
        # KEEP_SCHEMA_WITHIN_ENGINE=0:
        #   harness rebuilds every iter; nothing to do here.
        if [[ "$KEEP_SCHEMA_WITHIN_ENGINE" -eq 1 ]]; then
            local _reuse=0
            if [[ "$ITER" -gt 1 ]] && journal_has "${ENG}_iter$((ITER - 1))_done"; then
                _reuse=1
            fi
            if [[ "$_reuse" -eq 0 ]]; then
                log "Dropping tpcc to start this iter from a clean schema"
                mysql_query "DROP DATABASE IF EXISTS tpcc" >/dev/null || \
                    warn "  DROP DATABASE failed (continuing; harness will retry)"
            else
                log "Previous iter for $ENG completed -- reusing tpcc schema"
            fi
        fi

        EXTRA_ARGS=()
        if [[ "$KEEP_SCHEMA_WITHIN_ENGINE" -eq 1 ]]; then
            EXTRA_ARGS+=(--keep-schema)
        fi

        if [[ "$PERF" -eq 1 ]]; then
            EXTRA_ARGS+=(-p -F "$PERF_HZ")
        fi

        if [[ -n "$MYSQL_PASS" ]]; then
            EXTRA_ARGS+=(--pass "$MYSQL_PASS")
        fi

        # Run the harness from inside ITER_DIR so it writes its CSV + logs there.
        ITER_START=$(date +%s)
        (
            cd "$ITER_DIR"
            "$HARNESS" \
                -b tpcc \
                -e "$ENG" \
                --warehouses "$WAREHOUSES" \
                --tpcc-build-vu "$BUILD_VU" \
                --tpcc-vu "$RUN_VU" \
                --rampup "$RAMPUP" \
                --duration "$DURATION" \
                -w "$SETTLE" \
                -H "$HAMMERDB_DIR" \
                -u "$MYSQL_USER" \
                -S "$MYSQL_SOCKET" \
                "${EXTRA_ARGS[@]}"
        ) 2>&1 | tee "$ITER_DIR/run.log"
        RC=${PIPESTATUS[0]}
        ITER_END=$(date +%s)
        ITER_ELAPSED=$((ITER_END - ITER_START))

        if [[ "$RC" -ne 0 ]]; then
            warn "Iteration $ITER for $ENG returned $RC after ${ITER_ELAPSED}s - logged but NOT journaled"
            warn "  Inspect $ITER_DIR/run.log; rerun with --resume $RESULTS_DIR to retry"
            continue
        fi

        # Find the CSV the harness produced
        CSV=$(find "$ITER_DIR" -maxdepth 2 -name 'hammerdb_results_*.csv' -print -quit)
        if [[ -z "$CSV" || ! -s "$CSV" ]]; then
            warn "No CSV found in $ITER_DIR after iteration $ITER - skipping journal mark"
            continue
        fi

        log "Iteration $ITER for $ENG complete in ${ITER_ELAPSED}s -> $CSV"
        journal_add "$MARKER"
    done

    # Done with this engine. If we still have more engines to test, drop this
    # engine's TPC-C schema so we free disk space before the next engine
    # builds its own ~100 GB schema.
    if [[ "$CLEANUP_BETWEEN_ENGINES" -eq 1 ]]; then
        # Find the next engine in the list (if any)
        NEXT_IDX=-1
        for i in "${!ENGINE_LIST[@]}"; do
            if [[ "${ENGINE_LIST[$i]}" == "$ENG" ]]; then
                NEXT_IDX=$((i + 1))
                break
            fi
        done
        if [[ "$NEXT_IDX" -lt "${#ENGINE_LIST[@]}" ]]; then
            NEXT_ENG="${ENGINE_LIST[$NEXT_IDX]}"
            log "Cleanup: dropping $ENG TPC-C schema before next engine ($NEXT_ENG)..."
            if mysql_query "DROP DATABASE IF EXISTS tpcc"; then
                log "  tpcc database dropped"
            else
                warn "  Failed to drop tpcc database - next engine may compete for disk space"
            fi
        else
            log "Last engine - leaving $ENG schema in place for post-hoc inspection"
        fi
    fi
done

log ""
log "============================================================"
log "  MERGING CSVs AND GENERATING CHARTS"
log "============================================================"

# Collect every CSV we produced across all engines and iterations
CSVS=()
for ENG in "${ENGINE_LIST[@]}"; do
    ENG_DIR="$RESULTS_DIR/$ENG"
    while IFS= read -r f; do
        CSVS+=("$f")
    done < <(find "$ENG_DIR" -name 'hammerdb_results_*.csv' 2>/dev/null | sort)
done

if [[ ${#CSVS[@]} -eq 0 ]]; then
    warn "No CSVs found across any engine - nothing to plot"
    exit 1
fi

log "Found ${#CSVS[@]} CSV files for merge:"
for f in "${CSVS[@]}"; do log "  $f"; done

# Copy them all to final/merged so the harness's plot-only mode can find aux logs
# alongside (it looks in the CSV's parent dir for hammerdb_logs_<ts>).
MERGED_DIR="$RESULTS_DIR/final/merged"
mkdir -p "$MERGED_DIR"
for f in "${CSVS[@]}"; do
    base=$(basename "$f")
    cp "$f" "$MERGED_DIR/$base"
    # Also copy the matching log directory so aux charts (timeline, hotspots) work
    src_logs_dir=$(dirname "$f")
    # The harness creates hammerdb_logs_<ts>/ as a sibling of the CSV
    ts=$(echo "$base" | sed -E 's/^hammerdb_results_(.+)\.csv$/\1/')
    if [[ -d "$src_logs_dir/hammerdb_logs_$ts" ]]; then
        cp -r "$src_logs_dir/hammerdb_logs_$ts" "$MERGED_DIR/"
    fi
done

# Build the comma-separated CSV list for --plot-only
CSV_JOINED=$(IFS=,; echo "${CSVS[*]}")

log ""
log "Invoking harness in --plot-only mode..."
(
    cd "$MERGED_DIR"
    # Use relative paths inside MERGED_DIR so the plot output goes here.
    csv_local=$(ls hammerdb_results_*.csv | tr '\n' ',' | sed 's/,$//')
    "$HARNESS" --plot-only "$csv_local"
) 2>&1 | tee "$MERGED_DIR/plot.log"

END_TIME=$(date +%s)
TOTAL_ELAPSED=$((END_TIME - START_TIME))

log ""
log "============================================================"
log "  DONE"
log "============================================================"
log "Total wall time: $((TOTAL_ELAPSED / 60))m $((TOTAL_ELAPSED % 60))s"
log "Results:    $RESULTS_DIR/"
log "Merged charts: $MERGED_DIR/charts_*/"
log "Master log: $MASTER_LOG"
log ""

# Surface the chart filenames at the end for convenience
CHARTS_DIR=$(find "$MERGED_DIR" -maxdepth 2 -type d -name 'charts_*' | head -1)
if [[ -n "$CHARTS_DIR" ]]; then
    log "Charts produced in $CHARTS_DIR :"
    ls -1 "$CHARTS_DIR"/*.png 2>/dev/null | sed 's/^/  /'
fi
