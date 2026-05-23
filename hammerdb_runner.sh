#!/usr/bin/env bash
set -euo pipefail

# defaults
HAMMERDB_DIR=${HAMMERDB_DIR:-/opt/HammerDB-5.0}
ENGINE_SELECT=${ENGINE_SELECT:-both}
BENCH_SELECT=${BENCH_SELECT:-both}
MYSQL_USER=${MYSQL_USER:-root}
MYSQL_PASS=${MYSQL_PASS:-}
MYSQL_HOST=${MYSQL_HOST:-localhost}
MYSQL_PORT=${MYSQL_PORT:-3306}
MYSQL_SOCKET=${MYSQL_SOCKET:-/tmp/mariadb.sock}
SETTLE=${SETTLE:-60}
DEBUG_RUN=0
PERF_RECORD=${PERF_RECORD:-0}
PERF_FREQ=${PERF_FREQ:-99}
PLOT_ONLY=""
CSV_FILES_JOINED=""        # pipe-separated list of CSV paths for chart generation

# MyRocks tuning toggles
ROCKSDB_BULK_LOAD=${ROCKSDB_BULK_LOAD:-1}      # use rocksdb_bulk_load during schema build
ROCKSDB_PARTITION=${ROCKSDB_PARTITION:-0}      # 0=off (default for MyRocks), 1=on
INNODB_PARTITION_THRESHOLD=${INNODB_PARTITION_THRESHOLD:-200}  # auto-partition for InnoDB at >= this warehouses

# PostgreSQL defaults
PG_HOST=${PG_HOST:-localhost}
PG_PORT=${PG_PORT:-5432}
PG_SUPERUSER=${PG_SUPERUSER:-postgres}
PG_SUPERUSER_PASS=${PG_SUPERUSER_PASS:-}
PG_USER=${PG_USER:-tpcc}
PG_PASS=${PG_PASS:-tpcc}
PG_DEFAULTDBASE=${PG_DEFAULTDBASE:-postgres}
PG_TPCC_DBASE=${PG_TPCC_DBASE:-tpcc}
PG_TPCH_DBASE=${PG_TPCH_DBASE:-tpch}

if sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
elif [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

# TPC-C defaults
TPCC_WAREHOUSES=${TPCC_WAREHOUSES:-20}
TPCC_BUILD_VU=${TPCC_BUILD_VU:-4}
TPCC_VU=${TPCC_VU:-8}
TPCC_RAMPUP=${TPCC_RAMPUP:-2}
TPCC_DURATION=${TPCC_DURATION:-5}
TPCC_DBASE=${TPCC_DBASE:-tpcc}
TPCC_KEEP_SCHEMA=${TPCC_KEEP_SCHEMA:-0}        # 0=delete after run (default), 1=keep

# TPC-H defaults
TPCH_SCALE=${TPCH_SCALE:-1}
TPCH_BUILD_THREADS=${TPCH_BUILD_THREADS:-4}
TPCH_VU=${TPCH_VU:-1}
TPCH_QUERYSETS=${TPCH_QUERYSETS:-1}
TPCH_DEGREE=${TPCH_DEGREE:-2}
TPCH_DBASE=${TPCH_DBASE:-tpch}

HAMMERDBCLI="${HAMMERDB_DIR}/hammerdbcli"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
WORK_DIR="$(pwd)"
CSV_FILE="${WORK_DIR}/hammerdb_results_${TIMESTAMP}.csv"
LOG_DIR="${WORK_DIR}/hammerdb_logs_${TIMESTAMP}"
mkdir -p "$LOG_DIR"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -e, --engine       STR   Engine: tidesdb|rocksdb|innodb|postgres|both|all
                           (default: $ENGINE_SELECT)
                           "both" runs tidesdb and rocksdb
                           "all" runs tidesdb, rocksdb, innodb, and postgres
  -b, --bench        STR   Benchmark: tpcc|tpch|both       (default: $BENCH_SELECT)
  -H, --hammerdb-dir PATH  HammerDB install directory       (default: $HAMMERDB_DIR)
  -w, --settle       NUM   Post-build settle seconds        (default: $SETTLE)

  TPC-C options:
  --warehouses       NUM   Number of warehouses             (default: $TPCC_WAREHOUSES)
  --tpcc-vu          NUM   Virtual users for TPC-C run      (default: $TPCC_VU)
  --tpcc-build-vu    NUM   Virtual users for schema build   (default: $TPCC_BUILD_VU)
  --rampup           NUM   Rampup time in minutes           (default: $TPCC_RAMPUP)
  --duration         NUM   Test duration in minutes         (default: $TPCC_DURATION)
  --tpcc-db          STR   TPC-C database name              (default: $TPCC_DBASE)
  --keep-schema            Do NOT delete TPC-C schema after run (default: delete)

  MyRocks tuning:
  --rocksdb-no-bulk-load   Disable rocksdb_bulk_load during build
                           (default: bulk_load ON for faster load)
  --rocksdb-partition      Enable partitioning for RocksDB engine
                           (default: OFF - MyRocks partition handling adds overhead)

  TPC-H options:
  --scale            NUM   TPC-H scale factor               (default: $TPCH_SCALE)
  --tpch-vu          NUM   Virtual users for TPC-H run      (default: $TPCH_VU)
  --tpch-threads     NUM   Build threads                    (default: $TPCH_BUILD_THREADS)
  --querysets        NUM   Total query sets                 (default: $TPCH_QUERYSETS)
  --degree           NUM   Degree of parallelism            (default: $TPCH_DEGREE)
  --tpch-db          STR   TPC-H database name              (default: $TPCH_DBASE)

  MariaDB/MySQL Connection:
  -u, --user         STR   MySQL/MariaDB user               (default: $MYSQL_USER)
  --pass             STR   MySQL/MariaDB password           (default: empty)
  --host             STR   MySQL/MariaDB host               (default: $MYSQL_HOST)
  --port             NUM   MySQL/MariaDB port               (default: $MYSQL_PORT)
  -S, --socket       PATH  MySQL/MariaDB socket             (default: $MYSQL_SOCKET)

  PostgreSQL Connection:
  --pg-host          STR   PostgreSQL host                  (default: $PG_HOST)
  --pg-port          NUM   PostgreSQL port                  (default: $PG_PORT)
  --pg-superuser     STR   PostgreSQL superuser             (default: $PG_SUPERUSER)
  --pg-superuser-pass STR  PostgreSQL superuser password    (default: empty)
  --pg-user          STR   PostgreSQL benchmark user        (default: $PG_USER)
  --pg-pass          STR   PostgreSQL benchmark password    (default: $PG_PASS)
  --pg-defaultdbase  STR   PostgreSQL default database      (default: $PG_DEFAULTDBASE)
  --pg-tpcc-db       STR   PostgreSQL TPC-C database name   (default: $PG_TPCC_DBASE)
  --pg-tpch-db       STR   PostgreSQL TPC-H database name   (default: $PG_TPCH_DBASE)

  -P, --plot-only    FILE  Skip benchmarks, plot from CSV.  Pass a single
                           CSV, or comma-separated CSVs to merge multiple
                           runs (e.g. run1.csv,run2.csv,run3.csv).  When
                           merging, bars show the median across runs and
                           whiskers show min/max.
  -p, --perf               Enable perf record on DB server during run
  -F, --perf-freq    NUM   perf sampling frequency Hz       (default: $PERF_FREQ)
  --debug-run              Run a short diagnostic (2 VU, raiseerror=true)
                           before benchmarking to check for lock conflicts
  -h, --help               Show this help

Examples:
  # MyRocks recommended run: 1000 WH, 64 VU, 7 min ramp, 20 min duration
  ./tidesdb_rocksdb_hammerdb.sh -e rocksdb -b tpcc \\
      --warehouses 1000 --tpcc-build-vu 6 --tpcc-vu 64 \\
      --rampup 7 --duration 20 -w 120 -p

  # MyRocks repeatable: keep schema, run 3 times without rebuild
  ./tidesdb_rocksdb_hammerdb.sh -e rocksdb -b tpcc \\
      --warehouses 1000 --tpcc-vu 64 --rampup 7 --duration 20 \\
      --keep-schema

  # PostgreSQL only benchmark
  ./tidesdb_rocksdb_hammerdb.sh -e postgres --pg-superuser-pass mypass

  # Plot existing results
  ./tidesdb_rocksdb_hammerdb.sh --plot-only hammerdb_results_20260321.csv

  # Merge and plot multiple runs (median + min/max error bars)
  ./tidesdb_rocksdb_hammerdb.sh --plot-only run1.csv,run2.csv,run3.csv
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--engine)         ENGINE_SELECT="$2";    shift 2 ;;
        -b|--bench)          BENCH_SELECT="$2";     shift 2 ;;
        -H|--hammerdb-dir)   HAMMERDB_DIR="$2"; HAMMERDBCLI="${2}/hammerdbcli"; shift 2 ;;
        -w|--settle)         SETTLE="$2";           shift 2 ;;
        --warehouses)        TPCC_WAREHOUSES="$2";  shift 2 ;;
        --tpcc-vu)           TPCC_VU="$2";          shift 2 ;;
        --tpcc-build-vu)     TPCC_BUILD_VU="$2";    shift 2 ;;
        --rampup)            TPCC_RAMPUP="$2";      shift 2 ;;
        --duration)          TPCC_DURATION="$2";    shift 2 ;;
        --tpcc-db)           TPCC_DBASE="$2";       shift 2 ;;
        --keep-schema)       TPCC_KEEP_SCHEMA=1;    shift ;;
        --rocksdb-no-bulk-load) ROCKSDB_BULK_LOAD=0; shift ;;
        --rocksdb-partition) ROCKSDB_PARTITION=1;   shift ;;
        --scale)             TPCH_SCALE="$2";       shift 2 ;;
        --tpch-vu)           TPCH_VU="$2";          shift 2 ;;
        --tpch-threads)      TPCH_BUILD_THREADS="$2"; shift 2 ;;
        --querysets)         TPCH_QUERYSETS="$2";    shift 2 ;;
        --degree)            TPCH_DEGREE="$2";      shift 2 ;;
        --tpch-db)           TPCH_DBASE="$2";       shift 2 ;;
        -u|--user)           MYSQL_USER="$2";       shift 2 ;;
        --pass)              MYSQL_PASS="$2";       shift 2 ;;
        --host)              MYSQL_HOST="$2";       shift 2 ;;
        --port)              MYSQL_PORT="$2";       shift 2 ;;
        -S|--socket)         MYSQL_SOCKET="$2";     shift 2 ;;
        --pg-host)           PG_HOST="$2";          shift 2 ;;
        --pg-port)           PG_PORT="$2";          shift 2 ;;
        --pg-superuser)      PG_SUPERUSER="$2";     shift 2 ;;
        --pg-superuser-pass) PG_SUPERUSER_PASS="$2"; shift 2 ;;
        --pg-user)           PG_USER="$2";          shift 2 ;;
        --pg-pass)           PG_PASS="$2";          shift 2 ;;
        --pg-defaultdbase)   PG_DEFAULTDBASE="$2";  shift 2 ;;
        --pg-tpcc-db)        PG_TPCC_DBASE="$2";    shift 2 ;;
        --pg-tpch-db)        PG_TPCH_DBASE="$2";    shift 2 ;;
        --debug-run)         DEBUG_RUN=1;           shift ;;
        -p|--perf)           PERF_RECORD=1;         shift ;;
        -F|--perf-freq)      PERF_FREQ="$2";        shift 2 ;;
        -P|--plot-only)      PLOT_ONLY="$2";        shift 2 ;;
        -h|--help)           usage ;;
        *)                   echo "Unknown option: $1"; usage ;;
    esac
done

# plot-only mode
if [[ -n "$PLOT_ONLY" ]]; then
    # Allow comma-separated list of CSVs.
    IFS=',' read -r -a _PLOT_CSV_ARRAY <<< "$PLOT_ONLY"
    _PLOT_RESOLVED=()
    for _csv in "${_PLOT_CSV_ARRAY[@]}"; do
        _csv="${_csv# }"; _csv="${_csv% }"  # trim spaces
        if [[ ! -f "$_csv" ]]; then
            echo "ERROR: CSV file not found: $_csv"
            exit 1
        fi
        _PLOT_RESOLVED+=( "$(cd "$(dirname "$_csv")" && pwd)/$(basename "$_csv")" )
    done

    if [[ ${#_PLOT_RESOLVED[@]} -eq 0 ]]; then
        echo "ERROR: no valid CSVs supplied to --plot-only"
        exit 1
    fi

    # First CSV is the reference for naming the chart output dir.
    CSV_FILE="${_PLOT_RESOLVED[0]}"
    if [[ ${#_PLOT_RESOLVED[@]} -gt 1 ]]; then
        CHART_DIR="$(dirname "$CSV_FILE")/charts_merged_$(basename "$CSV_FILE" .csv)"
    else
        CHART_DIR="$(dirname "$CSV_FILE")/charts_$(basename "$CSV_FILE" .csv)"
    fi
    mkdir -p "$CHART_DIR"

    # join with '|' for the python heredoc (commas may legitimately appear in pathnames)
    CSV_FILES_JOINED="$(IFS='|'; echo "${_PLOT_RESOLVED[*]}")"

    echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
    echo "  PLOT-ONLY MODE"
    echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
    if [[ ${#_PLOT_RESOLVED[@]} -eq 1 ]]; then
        echo "  CSV:    $CSV_FILE"
    else
        echo "  CSVs:   ${#_PLOT_RESOLVED[@]} files (merging)"
        for _csv in "${_PLOT_RESOLVED[@]}"; do
            echo "          $_csv"
        done
    fi
    echo "  Charts: $CHART_DIR/"
    echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
    echo ""
    for _csv in "${_PLOT_RESOLVED[@]}"; do
        echo "--- $(basename "$_csv") ---"
        column -t -s',' "$_csv" 2>/dev/null || cat "$_csv"
        echo ""
    done
    LOG_DIR="$CHART_DIR"
    SKIP_BENCH=1
fi

if [[ "${SKIP_BENCH:-0}" -ne 1 ]]; then

# validate
if [[ ! -x "$HAMMERDBCLI" ]]; then
    echo "ERROR: hammerdbcli not found at $HAMMERDBCLI"
    echo "Set HAMMERDB_DIR or use --hammerdb-dir"
    exit 1
fi

case "${ENGINE_SELECT,,}" in
    tidesdb)   ENGINES=("TidesDB") ;;
    rocksdb)   ENGINES=("RocksDB") ;;
    innodb)    ENGINES=("InnoDB") ;;
    postgres|postgresql|pg) ENGINES=("PostgreSQL") ;;
    both)      ENGINES=("TidesDB" "RocksDB") ;;
    all)       ENGINES=("TidesDB" "RocksDB" "InnoDB" "PostgreSQL") ;;
    *)         echo "ERROR: --engine must be tidesdb, rocksdb, innodb, postgres, both, or all"; exit 1 ;;
esac

# perf preflight
if [[ "$PERF_RECORD" -eq 1 ]]; then
    if ! command -v perf &>/dev/null; then
        echo "ERROR: perf not found. Install with: sudo apt install linux-tools-\$(uname -r)"
        exit 1
    fi
    if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        echo "WARNING: sudo requires a password. Caching credentials now..."
        sudo true
    fi
    echo "Perf preflight OK (sudo: ${SUDO:-root})"
    echo ""
fi

find_mariadbd_pid() {
    local pid
    pid=$(pgrep -x mariadbd || pgrep -x mysqld || true)
    if [[ -z "$pid" ]]; then
        echo "WARNING: Could not find mariadbd/mysqld PID for perf" >&2
        return 1
    fi
    echo "$pid"
}

find_postgres_pid() {
    local pid
    pid=$(pgrep -x postgres || pgrep -x postmaster || true)
    if [[ -z "$pid" ]]; then
        echo "WARNING: Could not find postgres PID for perf" >&2
        return 1
    fi
    echo "$pid" | head -1
}

is_pg_engine() {
    [[ "$1" == "PostgreSQL" ]]
}

is_rocksdb_engine() {
    [[ "$1" == "RocksDB" ]]
}

find_db_pid() {
    local engine="$1"
    if is_pg_engine "$engine"; then
        find_postgres_pid
    else
        find_mariadbd_pid
    fi
}

# decide partitioning for this engine + warehouse count
decide_partition() {
    local engine="$1"
    if is_rocksdb_engine "$engine"; then
        # RocksDB: respect explicit flag only - default OFF
        [[ "$ROCKSDB_PARTITION" -eq 1 ]] && echo "true" || echo "false"
    elif [[ "$engine" == "InnoDB" ]]; then
        # InnoDB: auto-partition at threshold
        [[ "$TPCC_WAREHOUSES" -ge "$INNODB_PARTITION_THRESHOLD" ]] && echo "true" || echo "false"
    else
        # TidesDB and others: off
        echo "false"
    fi
}

# MyRocks bulk-load session toggles (set before build, unset after)
rocksdb_bulk_load_on() {
    [[ "$ROCKSDB_BULK_LOAD" -eq 1 ]] || return 0
    echo "[$(date +%H:%M:%S)] Enabling rocksdb_bulk_load for schema build..."
    mysql -u "$MYSQL_USER" ${MYSQL_PASS:+-p"$MYSQL_PASS"} -S "$MYSQL_SOCKET" 2>/dev/null <<'SQL' || \
        echo "  (warning: could not set bulk_load - may not be MyRocks or insufficient privs)"
SET GLOBAL rocksdb_bulk_load_allow_unsorted=1;
SET GLOBAL rocksdb_bulk_load=1;
SQL
}

rocksdb_bulk_load_off() {
    [[ "$ROCKSDB_BULK_LOAD" -eq 1 ]] || return 0
    echo "[$(date +%H:%M:%S)] Disabling rocksdb_bulk_load after build..."
    mysql -u "$MYSQL_USER" ${MYSQL_PASS:+-p"$MYSQL_PASS"} -S "$MYSQL_SOCKET" 2>/dev/null <<'SQL' || true
SET GLOBAL rocksdb_bulk_load=0;
SET GLOBAL rocksdb_bulk_load_allow_unsorted=0;
SQL
}

# Check if TPC-C schema already exists (for --keep-schema mode)
tpcc_schema_exists() {
    local engine="$1"
    if is_pg_engine "$engine"; then
        PGPASSWORD="$PG_SUPERUSER_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d "$PG_DEFAULTDBASE" \
            -tAc "SELECT 1 FROM pg_database WHERE datname='$PG_TPCC_DBASE';" 2>/dev/null | grep -q 1
    else
        local count
        count=$(mysql -u "$MYSQL_USER" ${MYSQL_PASS:+-p"$MYSQL_PASS"} -S "$MYSQL_SOCKET" -N -e \
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$TPCC_DBASE' AND table_name='warehouse';" 2>/dev/null || echo "0")
        [[ "$count" -gt 0 ]]
    fi
}

BENCHMARKS=()
case "${BENCH_SELECT,,}" in
    tpcc|tpc-c)   BENCHMARKS=("TPC-C") ;;
    tpch|tpc-h)   BENCHMARKS=("TPC-H") ;;
    both)         BENCHMARKS=("TPC-C" "TPC-H") ;;
    *)            echo "ERROR: --bench must be tpcc, tpch, or both"; exit 1 ;;
esac

if [[ " ${BENCHMARKS[*]} " == *"TPC-H"* ]]; then
    case "$TPCH_SCALE" in
        1|10|30|100|300|1000|3000|10000|30000|100000) ;;
        *) echo "ERROR: --scale must be one of: 1, 10, 30, 100, 300, 1000, 3000, 10000, 30000, 100000"; exit 1 ;;
    esac
fi

export TMP="${LOG_DIR}/hammerdb_tmp"
mkdir -p "$TMP"

# conditional password lines for Tcl scripts
if [[ -n "$MYSQL_PASS" ]]; then
    DISET_TPCC_PASS="diset tpcc maria_pass $MYSQL_PASS"
    DISET_TPCH_PASS="diset tpch maria_tpch_pass $MYSQL_PASS"
else
    DISET_TPCC_PASS="# password not set"
    DISET_TPCH_PASS="# password not set"
fi

# PostgreSQL password lines
if [[ -n "$PG_SUPERUSER_PASS" ]]; then
    DISET_PG_SUPERUSER_PASS="diset tpcc pg_superuserpass $PG_SUPERUSER_PASS"
    DISET_PG_TPCH_SUPERUSER_PASS="diset tpch pg_tpch_superuserpass $PG_SUPERUSER_PASS"
else
    DISET_PG_SUPERUSER_PASS="# pg superuser password not set"
    DISET_PG_TPCH_SUPERUSER_PASS="# pg tpch superuser password not set"
fi
if [[ -n "$PG_PASS" ]]; then
    DISET_PG_PASS="diset tpcc pg_pass $PG_PASS"
    DISET_PG_TPCH_PASS="diset tpch pg_tpch_pass $PG_PASS"
else
    DISET_PG_PASS="# pg password not set"
    DISET_PG_TPCH_PASS="# pg tpch password not set"
fi

# CSV header
cat > "$CSV_FILE" <<EOF
benchmark,engine,nopm,tpm,warehouses,virtual_users,rampup_min,duration_min,scale_factor,querysets,build_sec,settle_sec,neword_avg_ms,neword_p95_ms,payment_avg_ms,payment_p95_ms,delivery_avg_ms,delivery_p95_ms,tpch_geomean_sec,tpch_total_sec
EOF

TOTAL_RUNS=$(( ${#BENCHMARKS[@]} * ${#ENGINES[@]} ))
echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
echo "  HammerDB TPC-C / TPC-H bench"
echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
echo "  Benchmark(s): ${BENCHMARKS[*]}"
echo "  Engine(s):    ${ENGINES[*]}"
echo "  Total runs:   $TOTAL_RUNS"
if [[ " ${BENCHMARKS[*]} " == *"TPC-C"* ]]; then
    echo "  TPC-C:        ${TPCC_WAREHOUSES} warehouses, ${TPCC_VU} VU, ${TPCC_RAMPUP}m ramp, ${TPCC_DURATION}m run"
    echo "  Keep schema:  $([ "$TPCC_KEEP_SCHEMA" -eq 1 ] && echo "YES (reuse existing if present)" || echo "no (delete after run)")"
fi
if [[ " ${BENCHMARKS[*]} " == *"TPC-H"* ]]; then
    echo "  TPC-H:        SF${TPCH_SCALE}, ${TPCH_VU} VU, ${TPCH_QUERYSETS} querysets, degree=${TPCH_DEGREE}"
fi
HAS_ROCKSDB=0
for e in "${ENGINES[@]}"; do [[ "$e" == "RocksDB" ]] && HAS_ROCKSDB=1; done
if [[ "$HAS_ROCKSDB" -eq 1 ]]; then
    echo "  RocksDB:      bulk_load=$([ "$ROCKSDB_BULK_LOAD" -eq 1 ] && echo "ON" || echo "OFF"), partition=$([ "$ROCKSDB_PARTITION" -eq 1 ] && echo "ON" || echo "OFF")"
fi
echo "  Settle:       ${SETTLE}s"
echo "  Debug run:    $([ "$DEBUG_RUN" -eq 1 ] && echo "ON (raiseerror=true pre-check)" || echo "OFF")"
echo "  Perf:         $([ "$PERF_RECORD" -eq 1 ] && echo "ON (${PERF_FREQ} Hz)" || echo "OFF")"
echo "  Socket:       $MYSQL_SOCKET"
HAS_PG=0
for e in "${ENGINES[@]}"; do [[ "$e" == "PostgreSQL" ]] && HAS_PG=1; done
if [[ "$HAS_PG" -eq 1 ]]; then
    echo "  PG host:      $PG_HOST:$PG_PORT"
    echo "  PG superuser: $PG_SUPERUSER"
    echo "  PG user:      $PG_USER"
fi
echo "  HammerDB:     $HAMMERDB_DIR"
echo "  CSV output:   $CSV_FILE"
echo "  Logs:         $LOG_DIR/"
echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
echo ""

# helper: generate tcl scripts

gen_tpcc_build() {
    local engine="$1" outfile="$2"
    local partition
    partition=$(decide_partition "$engine")
    cat > "$outfile" <<TCLEOF
puts "SETTING CONFIGURATION"
dbset db maria
dbset bm TPC-C
diset connection maria_host $MYSQL_HOST
diset connection maria_port $MYSQL_PORT
diset connection maria_socket $MYSQL_SOCKET
diset tpcc maria_count_ware $TPCC_WAREHOUSES
diset tpcc maria_num_vu $TPCC_BUILD_VU
diset tpcc maria_user $MYSQL_USER
$DISET_TPCC_PASS
diset tpcc maria_dbase $TPCC_DBASE
diset tpcc maria_storage_engine [string tolower $engine]
diset tpcc maria_partition $partition
puts "SCHEMA BUILD STARTED"
buildschema
puts "SCHEMA BUILD COMPLETED"
TCLEOF
}

gen_tpcc_run() {
    local outfile="$1"
    cat > "$outfile" <<TCLEOF
set tmpdir \$::env(TMP)
puts "SETTING CONFIGURATION"
dbset db maria
dbset bm TPC-C
diset connection maria_host $MYSQL_HOST
diset connection maria_port $MYSQL_PORT
diset connection maria_socket $MYSQL_SOCKET
diset tpcc maria_user $MYSQL_USER
$DISET_TPCC_PASS
diset tpcc maria_dbase $TPCC_DBASE
diset tpcc maria_driver timed
diset tpcc maria_rampup $TPCC_RAMPUP
diset tpcc maria_duration $TPCC_DURATION
diset tpcc maria_allwarehouse true
diset tpcc maria_timeprofile true
vuset logtotemp 1
tcset refreshrate 10
tcset logtotemp 1
tcset timestamps 1
tcset unique 1
loadscript
puts "TEST STARTED"
vuset vu $TPCC_VU
vucreate
tcstart
tcstatus
set jobid [ vurun ]
vudestroy
tcstop
puts "TEST COMPLETE"
set of [ open \$tmpdir/maria_tprocc w ]
puts \$of \$jobid
close \$of
TCLEOF
}

gen_tpcc_result() {
    local outfile="$1"
    cat > "$outfile" <<TCLEOF
set tmpdir \$::env(TMP)
set ::outputfile \$tmpdir/maria_tprocc
source $HAMMERDB_DIR/scripts/tcl/generic/generic_tprocc_result.tcl
TCLEOF
}

gen_tpcc_delete() {
    local outfile="$1"
    cat > "$outfile" <<TCLEOF
puts "SETTING CONFIGURATION"
dbset db maria
dbset bm TPC-C
diset connection maria_host $MYSQL_HOST
diset connection maria_port $MYSQL_PORT
diset connection maria_socket $MYSQL_SOCKET
diset tpcc maria_user $MYSQL_USER
$DISET_TPCC_PASS
diset tpcc maria_dbase $TPCC_DBASE
puts "DROP SCHEMA STARTED"
deleteschema
puts "DROP SCHEMA COMPLETED"
TCLEOF
}

gen_tpch_build() {
    local outfile="$1"
    cat > "$outfile" <<TCLEOF
puts "SETTING CONFIGURATION"
dbset db maria
dbset bm TPC-H
diset connection maria_host $MYSQL_HOST
diset connection maria_port $MYSQL_PORT
diset connection maria_socket $MYSQL_SOCKET
diset tpch maria_scale_fact $TPCH_SCALE
diset tpch maria_num_tpch_threads $TPCH_BUILD_THREADS
diset tpch maria_tpch_user $MYSQL_USER
$DISET_TPCH_PASS
diset tpch maria_tpch_dbase $TPCH_DBASE
puts "SCHEMA BUILD STARTED"
buildschema
puts "SCHEMA BUILD COMPLETED"
TCLEOF
}

gen_tpch_run() {
    local outfile="$1"
    cat > "$outfile" <<TCLEOF
set tmpdir \$::env(TMP)
puts "SETTING CONFIGURATION"
dbset db maria
dbset bm TPC-H
diset connection maria_host $MYSQL_HOST
diset connection maria_port $MYSQL_PORT
diset connection maria_socket $MYSQL_SOCKET
diset tpch maria_tpch_user $MYSQL_USER
$DISET_TPCH_PASS
diset tpch maria_tpch_dbase $TPCH_DBASE
diset tpch maria_total_querysets $TPCH_QUERYSETS
diset tpch maria_raise_query_error true
diset tpch maria_verbose true
loadscript
puts "TEST STARTED"
vuset vu $TPCH_VU
vucreate
set jobid [ vurun ]
vudestroy
puts "TEST COMPLETE"
set of [ open \$tmpdir/tpch_jobid w ]
puts \$of \$jobid
close \$of
TCLEOF
}

gen_tpch_delete() {
    local outfile="$1"
    cat > "$outfile" <<TCLEOF
puts "SETTING CONFIGURATION"
dbset db maria
dbset bm TPC-H
diset connection maria_host $MYSQL_HOST
diset connection maria_port $MYSQL_PORT
diset connection maria_socket $MYSQL_SOCKET
diset tpch maria_tpch_user $MYSQL_USER
$DISET_TPCH_PASS
diset tpch maria_tpch_dbase $TPCH_DBASE
puts "DROP SCHEMA STARTED"
deleteschema
puts "DROP SCHEMA COMPLETED"
TCLEOF
}

# PostgreSQL Tcl script generators

gen_pg_tpcc_build() {
    local outfile="$1"
    cat > "$outfile" <<TCLEOF
puts "SETTING CONFIGURATION"
dbset db pg
dbset bm TPC-C
diset connection pg_host $PG_HOST
diset connection pg_port $PG_PORT
diset tpcc pg_superuser $PG_SUPERUSER
$DISET_PG_SUPERUSER_PASS
diset tpcc pg_defaultdbase $PG_DEFAULTDBASE
diset tpcc pg_user $PG_USER
$DISET_PG_PASS
diset tpcc pg_dbase $PG_TPCC_DBASE
diset tpcc pg_count_ware $TPCC_WAREHOUSES
diset tpcc pg_num_vu $TPCC_BUILD_VU
puts "SCHEMA BUILD STARTED"
buildschema
puts "SCHEMA BUILD COMPLETED"
TCLEOF
}

gen_pg_tpcc_run() {
    local outfile="$1"
    cat > "$outfile" <<TCLEOF
set tmpdir \$::env(TMP)
puts "SETTING CONFIGURATION"
dbset db pg
dbset bm TPC-C
diset connection pg_host $PG_HOST
diset connection pg_port $PG_PORT
diset tpcc pg_superuser $PG_SUPERUSER
$DISET_PG_SUPERUSER_PASS
diset tpcc pg_defaultdbase $PG_DEFAULTDBASE
diset tpcc pg_user $PG_USER
$DISET_PG_PASS
diset tpcc pg_dbase $PG_TPCC_DBASE
diset tpcc pg_driver timed
diset tpcc pg_rampup $TPCC_RAMPUP
diset tpcc pg_duration $TPCC_DURATION
diset tpcc pg_allwarehouse true
diset tpcc pg_timeprofile true
vuset logtotemp 1
tcset refreshrate 10
tcset logtotemp 1
tcset timestamps 1
tcset unique 1
loadscript
puts "TEST STARTED"
vuset vu $TPCC_VU
vucreate
tcstart
tcstatus
set jobid [ vurun ]
vudestroy
tcstop
puts "TEST COMPLETE"
set of [ open \$tmpdir/pg_tprocc w ]
puts \$of \$jobid
close \$of
TCLEOF
}

gen_pg_tpcc_result() {
    local outfile="$1"
    cat > "$outfile" <<TCLEOF
set tmpdir \$::env(TMP)
set ::outputfile \$tmpdir/pg_tprocc
source $HAMMERDB_DIR/scripts/tcl/generic/generic_tprocc_result.tcl
TCLEOF
}

gen_pg_tpcc_delete() {
    local outfile="$1"
    cat > "$outfile" <<TCLEOF
puts "SETTING CONFIGURATION"
dbset db pg
dbset bm TPC-C
diset connection pg_host $PG_HOST
diset connection pg_port $PG_PORT
diset tpcc pg_superuser $PG_SUPERUSER
$DISET_PG_SUPERUSER_PASS
diset tpcc pg_defaultdbase $PG_DEFAULTDBASE
diset tpcc pg_user $PG_USER
$DISET_PG_PASS
diset tpcc pg_dbase $PG_TPCC_DBASE
puts "DROP SCHEMA STARTED"
deleteschema
puts "DROP SCHEMA COMPLETED"
TCLEOF
}

gen_pg_tpch_build() {
    local outfile="$1"
    cat > "$outfile" <<TCLEOF
puts "SETTING CONFIGURATION"
dbset db pg
dbset bm TPC-H
diset connection pg_host $PG_HOST
diset connection pg_port $PG_PORT
diset tpch pg_tpch_superuser $PG_SUPERUSER
$DISET_PG_TPCH_SUPERUSER_PASS
diset tpch pg_tpch_defaultdbase $PG_DEFAULTDBASE
diset tpch pg_tpch_user $PG_USER
$DISET_PG_TPCH_PASS
diset tpch pg_tpch_dbase $PG_TPCH_DBASE
diset tpch pg_scale_fact $TPCH_SCALE
diset tpch pg_num_tpch_threads $TPCH_BUILD_THREADS
puts "SCHEMA BUILD STARTED"
buildschema
puts "SCHEMA BUILD COMPLETED"
TCLEOF
}

gen_pg_tpch_run() {
    local outfile="$1"
    cat > "$outfile" <<TCLEOF
set tmpdir \$::env(TMP)
puts "SETTING CONFIGURATION"
dbset db pg
dbset bm TPC-H
diset connection pg_host $PG_HOST
diset connection pg_port $PG_PORT
diset tpch pg_tpch_superuser $PG_SUPERUSER
$DISET_PG_TPCH_SUPERUSER_PASS
diset tpch pg_tpch_defaultdbase $PG_DEFAULTDBASE
diset tpch pg_tpch_user $PG_USER
$DISET_PG_TPCH_PASS
diset tpch pg_tpch_dbase $PG_TPCH_DBASE
diset tpch pg_total_querysets $TPCH_QUERYSETS
diset tpch pg_raise_query_error true
diset tpch pg_verbose true
loadscript
puts "TEST STARTED"
vuset vu $TPCH_VU
vucreate
set jobid [ vurun ]
vudestroy
puts "TEST COMPLETE"
set of [ open \$tmpdir/tpch_jobid w ]
puts \$of \$jobid
close \$of
TCLEOF
}

gen_pg_tpch_delete() {
    local outfile="$1"
    cat > "$outfile" <<TCLEOF
puts "SETTING CONFIGURATION"
dbset db pg
dbset bm TPC-H
diset connection pg_host $PG_HOST
diset connection pg_port $PG_PORT
diset tpch pg_tpch_superuser $PG_SUPERUSER
$DISET_PG_TPCH_SUPERUSER_PASS
diset tpch pg_tpch_defaultdbase $PG_DEFAULTDBASE
diset tpch pg_tpch_user $PG_USER
$DISET_PG_TPCH_PASS
diset tpch pg_tpch_dbase $PG_TPCH_DBASE
puts "DROP SCHEMA STARTED"
deleteschema
puts "DROP SCHEMA COMPLETED"
TCLEOF
}

# helper: parse TPC-C results
parse_tpcc() {
    local logfile="$1"
    local nopm tpm
    local line
    line=$(grep "TEST RESULT" "$logfile" | tail -1 || true)
    nopm=$(echo "$line" | grep -oP 'achieved \K[0-9]+' || echo "0")
    tpm=$(echo "$line" | grep -oP 'from \K[0-9]+' || echo "0")
    echo "${nopm},${tpm}"
}

# HammerDB time profile output: try JSON-style first, then plain "avg=" / "p95="
# This covers HammerDB 4.x and 5.x format variations.
parse_tpcc_timing() {
    local logfile="$1"
    local neword_avg neword_p95 pay_avg pay_p95 del_avg del_p95

    # Try JSON-style ({"avg_ms": "..."})
    neword_avg=$(grep -A20 '"NEWORD"' "$logfile" 2>/dev/null | grep '"avg_ms"' | head -1 | grep -oP ':\s*"\K[0-9.]+' || echo "")
    neword_p95=$(grep -A20 '"NEWORD"' "$logfile" 2>/dev/null | grep '"p95_ms"' | head -1 | grep -oP ':\s*"\K[0-9.]+' || echo "")

    # Fallback: HammerDB 5.x default format like:
    #   NEWORD ... CALLS: 12345  MIN: 1.234ms  AVG: 5.678ms  ... P95: 12.345ms ...
    if [[ -z "$neword_avg" ]]; then
        neword_avg=$(grep -iE '^NEWORD|"NEWORD"' "$logfile" 2>/dev/null | grep -ioP 'AVG[:=]\s*\K[0-9.]+' | head -1 || echo "")
    fi
    if [[ -z "$neword_p95" ]]; then
        neword_p95=$(grep -iE '^NEWORD|"NEWORD"' "$logfile" 2>/dev/null | grep -ioP 'P95[:=]\s*\K[0-9.]+' | head -1 || echo "")
    fi

    pay_avg=$(grep -A20 '"PAYMENT"' "$logfile" 2>/dev/null | grep '"avg_ms"' | head -1 | grep -oP ':\s*"\K[0-9.]+' || echo "")
    pay_p95=$(grep -A20 '"PAYMENT"' "$logfile" 2>/dev/null | grep '"p95_ms"' | head -1 | grep -oP ':\s*"\K[0-9.]+' || echo "")
    if [[ -z "$pay_avg" ]]; then
        pay_avg=$(grep -iE '^PAYMENT|"PAYMENT"' "$logfile" 2>/dev/null | grep -ioP 'AVG[:=]\s*\K[0-9.]+' | head -1 || echo "")
    fi
    if [[ -z "$pay_p95" ]]; then
        pay_p95=$(grep -iE '^PAYMENT|"PAYMENT"' "$logfile" 2>/dev/null | grep -ioP 'P95[:=]\s*\K[0-9.]+' | head -1 || echo "")
    fi

    del_avg=$(grep -A20 '"DELIVERY"' "$logfile" 2>/dev/null | grep '"avg_ms"' | head -1 | grep -oP ':\s*"\K[0-9.]+' || echo "")
    del_p95=$(grep -A20 '"DELIVERY"' "$logfile" 2>/dev/null | grep '"p95_ms"' | head -1 | grep -oP ':\s*"\K[0-9.]+' || echo "")
    if [[ -z "$del_avg" ]]; then
        del_avg=$(grep -iE '^DELIVERY|"DELIVERY"' "$logfile" 2>/dev/null | grep -ioP 'AVG[:=]\s*\K[0-9.]+' | head -1 || echo "")
    fi
    if [[ -z "$del_p95" ]]; then
        del_p95=$(grep -iE '^DELIVERY|"DELIVERY"' "$logfile" 2>/dev/null | grep -ioP 'P95[:=]\s*\K[0-9.]+' | head -1 || echo "")
    fi

    # default any blanks to 0
    : "${neword_avg:=0}" "${neword_p95:=0}" "${pay_avg:=0}" "${pay_p95:=0}" "${del_avg:=0}" "${del_p95:=0}"
    echo "${neword_avg},${neword_p95},${pay_avg},${pay_p95},${del_avg},${del_p95}"
}

parse_tpch() {
    local logfile="$1"
    local -a qtimes=()
    local total=0 count=0 geomean=0
    while IFS= read -r line; do
        local secs
        secs=$(echo "$line" | grep -oP 'completed in \K[0-9.]+' || true)
        if [[ -n "$secs" ]]; then
            qtimes+=("$secs")
            total=$(echo "$total + $secs" | bc -l)
            count=$((count + 1))
        fi
    done < <(grep "query.*completed in" "$logfile" || true)

    if [[ $count -gt 0 ]]; then
        local log_sum=0
        for t in "${qtimes[@]}"; do
            log_sum=$(echo "$log_sum + l($t)" | bc -l)
        done
        geomean=$(echo "e($log_sum / $count)" | bc -l)
        geomean=$(printf "%.3f" "$geomean")
        total=$(printf "%.3f" "$total")
    fi
    echo "${geomean},${total}"
}

# settle helper
do_settle() {
    if [[ "$SETTLE" -gt 0 ]]; then
        echo "[$(date +%H:%M:%S)] Settling ${SETTLE}s..."
        for ((i=SETTLE; i>0; i-=10)); do
            remaining=$((i < 10 ? i : 10))
            sleep "$remaining"
            left=$((i - remaining))
            if [[ "$left" -gt 0 ]]; then
                echo "  ... ${left}s remaining"
            fi
        done
        echo "[$(date +%H:%M:%S)] Settle complete"
    fi
}

# set default storage engine
set_default_engine() {
    local engine="$1"
    if is_pg_engine "$engine"; then
        echo "[$(date +%H:%M:%S)] PostgreSQL engine - no default_storage_engine to set"
        return 0
    fi
    local engine_lower
    engine_lower=$(echo "$engine" | tr '[:upper:]' '[:lower:]')
    echo "[$(date +%H:%M:%S)] Setting default_storage_engine=$engine_lower..."
    mysql -u "$MYSQL_USER" ${MYSQL_PASS:+-p"$MYSQL_PASS"} -S "$MYSQL_SOCKET" \
        -e "SET GLOBAL default_storage_engine='$engine_lower';" 2>/dev/null || true
}

# ============================================================
#  DEBUG RUN (optional)
# ============================================================
if [[ "$DEBUG_RUN" -eq 1 ]]; then
    DEBUG_VU=2

    echo "######################################################"
    echo "  DEBUG RUN - checking for lock conflicts"
    echo "  VUs: $DEBUG_VU  |  Duration: 1 min (0 ramp)"
    echo "  raiseerror: TRUE  |  driver: timed"
    echo "######################################################"
    echo ""

    for ENGINE in "${ENGINES[@]}"; do
        DBG_PREFIX="${LOG_DIR}/debug_${ENGINE}"

        echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
        echo "  DEBUG: $ENGINE"
        echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"

        set_default_engine "$ENGINE"

        # bulk_load on for RocksDB build
        if is_rocksdb_engine "$ENGINE"; then
            rocksdb_bulk_load_on
        fi

        # build small schema
        if is_pg_engine "$ENGINE"; then
            gen_pg_tpcc_build "${DBG_PREFIX}_build.tcl"
        else
            gen_tpcc_build "$ENGINE" "${DBG_PREFIX}_build.tcl"
        fi
        echo "[$(date +%H:%M:%S)] Building debug schema ($ENGINE, ${TPCC_WAREHOUSES} warehouses)..."
        (cd "$HAMMERDB_DIR" && "$HAMMERDBCLI" auto "${DBG_PREFIX}_build.tcl") 2>&1 | tee "${DBG_PREFIX}_build.log" || true
        echo ""

        # turn bulk_load off before running
        if is_rocksdb_engine "$ENGINE"; then
            rocksdb_bulk_load_off
        fi

        sleep 5

        # run with raiseerror=true, timed driver (short)
        if is_pg_engine "$ENGINE"; then
            cat > "${DBG_PREFIX}_run.tcl" <<TCLEOF
puts "DEBUG RUN CONFIGURATION"
dbset db pg
dbset bm TPC-C
diset connection pg_host $PG_HOST
diset connection pg_port $PG_PORT
diset tpcc pg_superuser $PG_SUPERUSER
$DISET_PG_SUPERUSER_PASS
diset tpcc pg_defaultdbase $PG_DEFAULTDBASE
diset tpcc pg_user $PG_USER
$DISET_PG_PASS
diset tpcc pg_dbase $PG_TPCC_DBASE
diset tpcc pg_driver timed
diset tpcc pg_rampup 0
diset tpcc pg_duration 1
diset tpcc pg_raiseerror true
diset tpcc pg_allwarehouse true
diset tpcc pg_timeprofile false
loadscript
puts "DEBUG TEST STARTED"
vuset vu $DEBUG_VU
vucreate
tcstart
tcstatus
set jobid [ vurun ]
vudestroy
tcstop
puts "DEBUG TEST COMPLETE"
TCLEOF
        else
            cat > "${DBG_PREFIX}_run.tcl" <<TCLEOF
puts "DEBUG RUN CONFIGURATION"
dbset db maria
dbset bm TPC-C
diset connection maria_host $MYSQL_HOST
diset connection maria_port $MYSQL_PORT
diset connection maria_socket $MYSQL_SOCKET
diset tpcc maria_user $MYSQL_USER
$DISET_TPCC_PASS
diset tpcc maria_dbase $TPCC_DBASE
diset tpcc maria_driver timed
diset tpcc maria_rampup 0
diset tpcc maria_duration 1
diset tpcc maria_raiseerror true
diset tpcc maria_allwarehouse true
diset tpcc maria_timeprofile false
loadscript
puts "DEBUG TEST STARTED"
vuset vu $DEBUG_VU
vucreate
tcstart
tcstatus
set jobid [ vurun ]
vudestroy
tcstop
puts "DEBUG TEST COMPLETE"
TCLEOF
        fi

        echo "[$(date +%H:%M:%S)] Running debug test ($ENGINE, $DEBUG_VU VU, 1 min timed, raiseerror=true)..."
        (cd "$HAMMERDB_DIR" && TMP="$TMP" "$HAMMERDBCLI" auto "${DBG_PREFIX}_run.tcl") 2>&1 | tee "${DBG_PREFIX}_run.log" || true
        echo ""

        DEADLOCKS=$(grep -ciE "deadlock|lock wait timeout|Error 1213|Error 1180" "${DBG_PREFIX}_run.log" 2>/dev/null) || DEADLOCKS=0
        PROC_ERRORS=$(grep -ciE "Procedure Error" "${DBG_PREFIX}_run.log" 2>/dev/null) || PROC_ERRORS=0
        ABORTS=$(grep -ciE "FINISHED FAILED" "${DBG_PREFIX}_run.log" 2>/dev/null) || ABORTS=0

        echo "  ========================================="
        echo "  DEBUG RESULTS: $ENGINE"
        echo "  ========================================="
        echo "  Deadlock/lock-wait hits:  $DEADLOCKS"
        echo "  Procedure errors:         $PROC_ERRORS"
        echo "  VUs finished failed:      $ABORTS"
        if [[ "$DEADLOCKS" -gt 0 || "$PROC_ERRORS" -gt 0 || "$ABORTS" -gt 0 ]]; then
            echo ""
            echo "  Issues detected for $ENGINE."
            echo "  Relevant lines:"
            grep -iE "deadlock|lock wait|Error 1213|Error 1180|Procedure Error|FINISHED FAILED" "${DBG_PREFIX}_run.log" | head -10 || true
        else
            echo "  No lock conflicts detected - clean run."
        fi
        echo "  ========================================="
        echo ""

        # cleanup
        if is_pg_engine "$ENGINE"; then
            gen_pg_tpcc_delete "${DBG_PREFIX}_delete.tcl"
        else
            gen_tpcc_delete "${DBG_PREFIX}_delete.tcl"
        fi
        echo "[$(date +%H:%M:%S)] Cleaning up debug schema..."
        (cd "$HAMMERDB_DIR" && "$HAMMERDBCLI" auto "${DBG_PREFIX}_delete.tcl") 2>&1 | tee "${DBG_PREFIX}_delete.log" || true
        echo ""

        sleep 3
    done

    echo "######################################################"
    echo "  DEBUG RUN COMPLETE - proceeding to benchmark"
    echo "######################################################"
    echo ""
fi

# ============================================================
#  MAIN BENCHMARK LOOP
# ============================================================
RUN_NUM=0
for BENCH in "${BENCHMARKS[@]}"; do
    for ENGINE in "${ENGINES[@]}"; do
        RUN_NUM=$((RUN_NUM + 1))
        LOG_PREFIX="${LOG_DIR}/${BENCH}_${ENGINE}"

        echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
        echo "  [$RUN_NUM/$TOTAL_RUNS] $BENCH + $ENGINE"
        echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
        echo ""

        set_default_engine "$ENGINE"

        if [[ "$BENCH" == "TPC-C" ]]; then
            # check whether to skip build (keep-schema mode + schema exists)
            SKIP_BUILD=0
            BUILD_ELAPSED=0
            if [[ "$TPCC_KEEP_SCHEMA" -eq 1 ]] && tpcc_schema_exists "$ENGINE"; then
                echo "[$(date +%H:%M:%S)] Existing TPC-C schema detected (--keep-schema): SKIPPING BUILD"
                SKIP_BUILD=1
            fi

            if [[ "$SKIP_BUILD" -eq 0 ]]; then
                # TPC-C BUILD
                if is_rocksdb_engine "$ENGINE"; then
                    rocksdb_bulk_load_on
                fi
                if is_pg_engine "$ENGINE"; then
                    gen_pg_tpcc_build "${LOG_PREFIX}_build.tcl"
                else
                    gen_tpcc_build "$ENGINE" "${LOG_PREFIX}_build.tcl"
                fi
                echo "[$(date +%H:%M:%S)] Building TPC-C schema ($ENGINE, ${TPCC_WAREHOUSES} warehouses)..."
                BUILD_START=$(date +%s)
                (cd "$HAMMERDB_DIR" && "$HAMMERDBCLI" auto "${LOG_PREFIX}_build.tcl") 2>&1 | tee "${LOG_PREFIX}_build.log" || true
                BUILD_END=$(date +%s)
                BUILD_ELAPSED=$((BUILD_END - BUILD_START))
                echo "[$(date +%H:%M:%S)] Build completed in ${BUILD_ELAPSED}s"
                echo ""

                if is_rocksdb_engine "$ENGINE"; then
                    rocksdb_bulk_load_off
                fi

                # ANALYZE TABLE so optimizer has stats (MyRocks especially benefits)
                if ! is_pg_engine "$ENGINE"; then
                    echo "[$(date +%H:%M:%S)] Running ANALYZE TABLE on TPC-C tables..."
                    for tbl in warehouse district customer history new_orders orders order_line item stock; do
                        mysql -u "$MYSQL_USER" ${MYSQL_PASS:+-p"$MYSQL_PASS"} -S "$MYSQL_SOCKET" \
                            -e "ANALYZE TABLE $TPCC_DBASE.$tbl;" 2>/dev/null || true
                    done
                else
                    echo "[$(date +%H:%M:%S)] Running VACUUM ANALYZE on TPC-C database..."
                    PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_TPCC_DBASE" \
                        -c "VACUUM ANALYZE;" 2>/dev/null || true
                fi
            fi

            do_settle

            # PERF START
            PERF_PID=""
            if [[ "$PERF_RECORD" -eq 1 ]]; then
                DB_PID=$(find_db_pid "$ENGINE") || true
                if [[ -n "$DB_PID" ]]; then
                    if is_pg_engine "$ENGINE"; then db_label="postgres"; else db_label="mariadbd"; fi
                    echo "[$(date +%H:%M:%S)] Starting perf record on $db_label (PID $DB_PID, ${PERF_FREQ} Hz)..."
                    $SUDO perf record \
                        -F "$PERF_FREQ" \
                        -p "$DB_PID" \
                        -g \
                        --call-graph fp \
                        -o "${LOG_PREFIX}_perf.data" &
                    PERF_PID=$!
                    sleep 1
                    echo "[$(date +%H:%M:%S)] perf recording (background PID $PERF_PID)"
                else
                    echo "[$(date +%H:%M:%S)] WARNING: Skipping perf - DB server PID not found"
                fi
            fi

            # TPC-C RUN
            if is_pg_engine "$ENGINE"; then
                gen_pg_tpcc_run "${LOG_PREFIX}_run.tcl"
            else
                gen_tpcc_run "${LOG_PREFIX}_run.tcl"
            fi
            echo "[$(date +%H:%M:%S)] Running TPC-C ($ENGINE, ${TPCC_DURATION}m, ${TPCC_VU} VU)..."
            # Clear any HammerDB sample logs from prior engines so we only capture this run's data.
            rm -f "$TMP"/hdbtcount*.log "$TMP"/hammerdb*.log 2>/dev/null || true
            (cd "$HAMMERDB_DIR" && TMP="$TMP" "$HAMMERDBCLI" auto "${LOG_PREFIX}_run.tcl") 2>&1 | tee "${LOG_PREFIX}_run.log" || true
            echo ""

            # PERF STOP
            if [[ -n "$PERF_PID" ]] && kill -0 "$PERF_PID" 2>/dev/null; then
                echo "[$(date +%H:%M:%S)] Stopping perf..."
                $SUDO kill -INT "$PERF_PID"
                wait "$PERF_PID" 2>/dev/null || true

                echo "[$(date +%H:%M:%S)] Generating perf report..."

                $SUDO perf report \
                    -i "${LOG_PREFIX}_perf.data" \
                    --stdio \
                    --no-children \
                    --sort=dso,symbol \
                    --percent-limit=1 \
                    > "${LOG_PREFIX}_perf_report.txt" 2>/dev/null || true

                $SUDO perf report \
                    -i "${LOG_PREFIX}_perf.data" \
                    --stdio \
                    -g graph,0.5,caller \
                    --percent-limit=0.5 \
                    > "${LOG_PREFIX}_perf_callers.txt" 2>/dev/null || true

                if command -v stackcollapse-perf.pl &>/dev/null; then
                    echo "[$(date +%H:%M:%S)] Generating flamegraph..."
                    $SUDO perf script -i "${LOG_PREFIX}_perf.data" | stackcollapse-perf.pl > "${LOG_PREFIX}_perf.folded" 2>/dev/null || true
                    if command -v flamegraph.pl &>/dev/null && [[ -s "${LOG_PREFIX}_perf.folded" ]]; then
                        flamegraph.pl "${LOG_PREFIX}_perf.folded" > "${LOG_PREFIX}_flamegraph.svg" 2>/dev/null || true
                        echo "  Flamegraph: ${LOG_PREFIX}_flamegraph.svg"
                    fi
                else
                    echo "  TIP: Install FlameGraph tools for SVG flamegraphs:"
                    echo "    git clone https://github.com/brendangregg/FlameGraph.git"
                    echo "    export PATH=\$PATH:\$(pwd)/FlameGraph"
                fi

                $SUDO chown "$(id -u):$(id -g)" "${LOG_PREFIX}_perf.data" "${LOG_PREFIX}_perf_report.txt" \
                    "${LOG_PREFIX}_perf_callers.txt" 2>/dev/null || true
                [[ -f "${LOG_PREFIX}_perf.folded" ]] && $SUDO chown "$(id -u):$(id -g)" "${LOG_PREFIX}_perf.folded" 2>/dev/null || true
                [[ -f "${LOG_PREFIX}_flamegraph.svg" ]] && $SUDO chown "$(id -u):$(id -g)" "${LOG_PREFIX}_flamegraph.svg" 2>/dev/null || true

                echo "  perf data:    ${LOG_PREFIX}_perf.data"
                echo "  perf report:  ${LOG_PREFIX}_perf_report.txt"
                echo "  perf callers: ${LOG_PREFIX}_perf_callers.txt"
                echo ""
            fi

            # capture HammerDB transaction-counter samples and per-VU xtprof logs
            # so the chart code can produce throughput-over-time and latency-over-time plots.
            echo "[$(date +%H:%M:%S)] Capturing HammerDB sample logs..."
            shopt -s nullglob
            for f in "$TMP"/hdbtcount*.log; do
                cp "$f" "${LOG_PREFIX}_$(basename "$f")" 2>/dev/null || true
            done
            # HammerDB writes per-VU xtprof percentiles to its own log (hammerdb.log)
            # and may also stream them to stdout - both end up in run.log via tee.
            # Copy hammerdb.log if it exists so we have a clean source.
            for f in "$TMP"/hammerdb*.log; do
                cp "$f" "${LOG_PREFIX}_$(basename "$f")" 2>/dev/null || true
            done
            shopt -u nullglob

            # collect RocksDB compaction stats post-run
            if is_rocksdb_engine "$ENGINE"; then
                echo "[$(date +%H:%M:%S)] Collecting RocksDB post-run stats..."
                mysql -u "$MYSQL_USER" ${MYSQL_PASS:+-p"$MYSQL_PASS"} -S "$MYSQL_SOCKET" -e \
                    "SHOW ENGINE ROCKSDB STATUS\G" > "${LOG_PREFIX}_rocksdb_status.txt" 2>/dev/null || true
                mysql -u "$MYSQL_USER" ${MYSQL_PASS:+-p"$MYSQL_PASS"} -S "$MYSQL_SOCKET" -e \
                    "SHOW GLOBAL STATUS LIKE 'rocksdb_%';" > "${LOG_PREFIX}_rocksdb_globalstatus.txt" 2>/dev/null || true
                echo "  ${LOG_PREFIX}_rocksdb_status.txt"
                echo "  ${LOG_PREFIX}_rocksdb_globalstatus.txt"
            fi

            # TPC-C RESULT
            if is_pg_engine "$ENGINE"; then
                gen_pg_tpcc_result "${LOG_PREFIX}_result.tcl"
            else
                gen_tpcc_result "${LOG_PREFIX}_result.tcl"
            fi
            echo "[$(date +%H:%M:%S)] Querying TPC-C results..."
            (cd "$HAMMERDB_DIR" && TMP="$TMP" "$HAMMERDBCLI" auto "${LOG_PREFIX}_result.tcl") 2>&1 | tee "${LOG_PREFIX}_result.log" || true
            echo ""

            # PARSE
            NOPM_TPM=$(parse_tpcc "${LOG_PREFIX}_run.log")
            TIMING=$(parse_tpcc_timing "${LOG_PREFIX}_result.log" 2>/dev/null) || TIMING="0,0,0,0,0,0"
            # also try parsing from run.log if result.log was empty
            if [[ "$TIMING" == "0,0,0,0,0,0" ]]; then
                TIMING=$(parse_tpcc_timing "${LOG_PREFIX}_run.log" 2>/dev/null) || TIMING="0,0,0,0,0,0"
            fi

            echo "${BENCH},${ENGINE},${NOPM_TPM},${TPCC_WAREHOUSES},${TPCC_VU},${TPCC_RAMPUP},${TPCC_DURATION},,,${BUILD_ELAPSED},${SETTLE},${TIMING},,," >> "$CSV_FILE"

            # TPC-C DELETE - skip in keep-schema mode
            if [[ "$TPCC_KEEP_SCHEMA" -eq 1 ]]; then
                echo "[$(date +%H:%M:%S)] --keep-schema: leaving TPC-C schema in place"
            else
                if is_pg_engine "$ENGINE"; then
                    gen_pg_tpcc_delete "${LOG_PREFIX}_delete.tcl"
                else
                    gen_tpcc_delete "${LOG_PREFIX}_delete.tcl"
                fi
                echo "[$(date +%H:%M:%S)] Deleting TPC-C schema..."
                (cd "$HAMMERDB_DIR" && "$HAMMERDBCLI" auto "${LOG_PREFIX}_delete.tcl") 2>&1 | tee "${LOG_PREFIX}_delete.log" || true
            fi
            echo ""

        elif [[ "$BENCH" == "TPC-H" ]]; then
            # TPC-H BUILD
            if is_rocksdb_engine "$ENGINE"; then
                rocksdb_bulk_load_on
            fi
            if is_pg_engine "$ENGINE"; then
                gen_pg_tpch_build "${LOG_PREFIX}_build.tcl"
            else
                gen_tpch_build "${LOG_PREFIX}_build.tcl"
            fi
            echo "[$(date +%H:%M:%S)] Building TPC-H schema ($ENGINE, SF${TPCH_SCALE})..."
            BUILD_START=$(date +%s)
            (cd "$HAMMERDB_DIR" && "$HAMMERDBCLI" auto "${LOG_PREFIX}_build.tcl") 2>&1 | tee "${LOG_PREFIX}_build.log" || true
            BUILD_END=$(date +%s)
            BUILD_ELAPSED=$((BUILD_END - BUILD_START))
            echo "[$(date +%H:%M:%S)] Build completed in ${BUILD_ELAPSED}s"
            echo ""

            if is_rocksdb_engine "$ENGINE"; then
                rocksdb_bulk_load_off
            fi

            do_settle

            # TPC-H RUN
            if is_pg_engine "$ENGINE"; then
                gen_pg_tpch_run "${LOG_PREFIX}_run.tcl"
            else
                gen_tpch_run "${LOG_PREFIX}_run.tcl"
            fi
            echo "[$(date +%H:%M:%S)] Running TPC-H ($ENGINE, SF${TPCH_SCALE}, ${TPCH_VU} VU)..."
            (cd "$HAMMERDB_DIR" && TMP="$TMP" "$HAMMERDBCLI" auto "${LOG_PREFIX}_run.tcl") 2>&1 | tee "${LOG_PREFIX}_run.log" || true
            echo ""

            TPCH_METRICS=$(parse_tpch "${LOG_PREFIX}_run.log")

            echo "${BENCH},${ENGINE},,,,,,,${TPCH_SCALE},${TPCH_QUERYSETS},${BUILD_ELAPSED},${SETTLE},,,,,,${TPCH_METRICS}" >> "$CSV_FILE"

            # TPC-H DELETE
            if is_pg_engine "$ENGINE"; then
                gen_pg_tpch_delete "${LOG_PREFIX}_delete.tcl"
            else
                gen_tpch_delete "${LOG_PREFIX}_delete.tcl"
            fi
            echo "[$(date +%H:%M:%S)] Deleting TPC-H schema..."
            (cd "$HAMMERDB_DIR" && "$HAMMERDBCLI" auto "${LOG_PREFIX}_delete.tcl") 2>&1 | tee "${LOG_PREFIX}_delete.log" || true
            echo ""
        fi

        echo "[$(date +%H:%M:%S)] Cooldown (5s)..."
        sleep 5
        echo ""
    done
done

echo ""
echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
echo "  RESULTS SUMMARY"
echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
column -t -s',' "$CSV_FILE" 2>/dev/null || cat "$CSV_FILE"
echo ""
echo "CSV saved to: $CSV_FILE"
echo "Full logs in: $LOG_DIR/"
if [[ "$PERF_RECORD" -eq 1 ]]; then
    echo ""
    echo ">> Perf outputs >>"
    for ENGINE in "${ENGINES[@]}"; do
        for BENCH in "${BENCHMARKS[@]}"; do
            prefix="${LOG_DIR}/${BENCH}_${ENGINE}"
            if [[ -f "${prefix}_perf.data" ]]; then
                echo "  ${BENCH} + ${ENGINE}:"
                echo "    Raw:        ${prefix}_perf.data"
                [[ -f "${prefix}_perf_report.txt" ]]  && echo "    Report:     ${prefix}_perf_report.txt"
                [[ -f "${prefix}_perf_callers.txt" ]] && echo "    Callers:    ${prefix}_perf_callers.txt"
                [[ -f "${prefix}_flamegraph.svg" ]]   && echo "    Flamegraph: ${prefix}_flamegraph.svg"
            fi
        done
    done
    echo ""
    echo "Quick analysis:"
    echo "  perf report -i ${LOG_DIR}/<BENCH>_<ENGINE>_perf.data"
    echo "  perf annotate -i ${LOG_DIR}/<BENCH>_<ENGINE>_perf.data -s <symbol>"
fi
echo ""

fi  # end SKIP_BENCH

# ============================================================
#  CHART GENERATION
# ============================================================
echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
echo "  GENERATING CHARTS"
echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
echo ""

if command -v python3 &>/dev/null; then
    # If we got here via a normal benchmark run, CSV_FILES_JOINED is empty - default to CSV_FILE.
    if [[ -z "$CSV_FILES_JOINED" ]]; then
        CSV_FILES_JOINED="$CSV_FILE"
    fi
    python3 - "$CSV_FILES_JOINED" "$LOG_DIR" <<'PYEOF'
import sys, os, csv, math, warnings

# argv: csv_paths_joined_by_PIPE  out_dir
csv_paths = sys.argv[1].split("|")
out_dir   = sys.argv[2]

try:
    import matplotlib
    matplotlib.use("Agg")
    warnings.filterwarnings("ignore", message=r".*hatch must consist.*")
    import matplotlib.pyplot as plt
    import matplotlib.patheffects as path_effects
    import matplotlib.hatch as mhatch
    from matplotlib.path import Path
    from matplotlib.ticker import FuncFormatter, MaxNLocator
    import numpy as np
except ImportError:
    print("  WARNING: matplotlib not found, skipping charts")
    print("  Install with: pip install matplotlib")
    sys.exit(0)

# ============================================================
#  CUSTOM HATCH: WAVE (for TidesDB)
# ============================================================
class WaveHatch(mhatch.HatchPatternBase):
    """Horizontal sine-wave hatch ('~') for TidesDB - evokes water/tides."""
    def __init__(self, hatch, density):
        self.num_lines = int(hatch.count("~") * density)
        self.num_vertices = self.num_lines * 41 if self.num_lines else 0

    def set_vertices_and_codes(self, vertices, codes):
        if self.num_lines == 0:
            return
        steps = np.linspace(0, 1, 41, endpoint=True)
        spacing = 1.0 / self.num_lines
        idx = 0
        for i in range(self.num_lines):
            y_base = (i + 0.5) * spacing
            ys = y_base + 0.20 * spacing * np.sin(steps * 2 * np.pi * 2)
            for j in range(41):
                vertices[idx + j, 0] = steps[j]
                vertices[idx + j, 1] = ys[j]
                codes[idx + j] = Path.MOVETO if j == 0 else Path.LINETO
            idx += 41

mhatch._hatch_types.append(WaveHatch)

# ============================================================
#  LOAD + MERGE CSVs
# ============================================================
all_rows = []
for path in csv_paths:
    path = path.strip()
    if not path or not os.path.exists(path):
        if path:
            print(f"  WARNING: CSV not found: {path}", file=sys.stderr)
        continue
    with open(path) as f:
        for r in csv.DictReader(f):
            if r.get("benchmark"):
                r["_source"] = os.path.basename(path)
                all_rows.append(r)

if not all_rows:
    print("  No data rows found across input CSVs, skipping charts")
    sys.exit(0)

def safe_float(v):
    try: return float(v) if v not in (None, "") else 0.0
    except: return 0.0

from collections import defaultdict
groups = defaultdict(list)
for r in all_rows:
    groups[(r["benchmark"], r["engine"])].append(r)

NUMERIC_COLS = ["nopm","tpm","build_sec",
                "neword_avg_ms","neword_p95_ms",
                "payment_avg_ms","payment_p95_ms",
                "delivery_avg_ms","delivery_p95_ms",
                "tpch_geomean_sec","tpch_total_sec"]

def median(xs):
    xs = sorted(xs)
    n = len(xs)
    if n == 0: return 0
    if n % 2: return xs[n//2]
    return 0.5*(xs[n//2 - 1] + xs[n//2])

rows = []
for (bench, eng), rs in groups.items():
    merged = dict(rs[0])
    merged["_n_runs"] = len(rs)
    for col in NUMERIC_COLS:
        vals = [safe_float(r.get(col, 0)) for r in rs]
        vals = [v for v in vals if v > 0]
        if vals:
            merged[col] = median(vals)
            merged[col + "_min"] = min(vals)
            merged[col + "_max"] = max(vals)
        else:
            merged[col] = 0
            merged[col + "_min"] = 0
            merged[col + "_max"] = 0
    rows.append(merged)

multi_run = any(r.get("_n_runs", 1) > 1 for r in rows)
if multi_run:
    print(f"  Merging {len(csv_paths)} CSV(s) -> {len(rows)} (benchmark, engine) groups")
    for r in rows:
        if r.get("_n_runs", 1) > 1:
            print(f"    {r['benchmark']} + {r['engine']}: median of {r['_n_runs']} runs (whiskers = min/max)")

# ============================================================
#  PAPER-GRADE STYLE
# ============================================================
preferred_fonts = ["CMU Serif", "Computer Modern Roman", "STIX Two Text",
                   "DejaVu Serif", "Liberation Serif", "serif"]

plt.rcParams.update({
    "font.family":         "serif",
    "font.serif":          preferred_fonts,
    "font.size":           10.5,
    "axes.titlesize":      12,
    "axes.titleweight":    "semibold",
    "axes.labelsize":      10.5,
    "axes.labelweight":    "regular",
    "xtick.labelsize":     10,
    "ytick.labelsize":     9.5,
    "legend.fontsize":     9.5,
    "legend.title_fontsize": 10,
    "figure.titlesize":    13,
    "figure.titleweight":  "semibold",
    "mathtext.fontset":    "stix",
    "axes.linewidth":      0.9,
    "axes.edgecolor":      "#222222",
    "axes.labelcolor":     "#1a1a1a",
    "axes.spines.top":     False,
    "axes.spines.right":   False,
    "axes.grid":           True,
    "axes.grid.axis":      "y",
    "grid.color":          "#cfcfcf",
    "grid.linestyle":      "-",
    "grid.linewidth":      0.55,
    "grid.alpha":          0.7,
    "axes.axisbelow":      True,
    "xtick.direction":     "out",
    "ytick.direction":     "out",
    "xtick.color":         "#333333",
    "ytick.color":         "#333333",
    "xtick.major.size":    3.5,
    "ytick.major.size":    3.5,
    "xtick.major.width":   0.8,
    "ytick.major.width":   0.8,
    "legend.frameon":      True,
    "legend.framealpha":   0.96,
    "legend.edgecolor":    "#bdbdbd",
    "legend.fancybox":     False,
    "legend.borderpad":    0.6,
    "legend.handlelength": 1.8,
    "legend.handleheight": 1.0,
    "legend.labelspacing": 0.45,
    "figure.facecolor":    "white",
    "savefig.facecolor":   "white",
    "savefig.dpi":         300,
    "savefig.bbox":        "tight",
    "savefig.pad_inches":  0.08,
    "pdf.fonttype":        42,
    "ps.fonttype":         42,
    "hatch.linewidth":     0.9,
})

# Thematic palette:
#   TidesDB - waves (custom '~') for tides
#   RocksDB - stars ('*') packed densely as tiger spots
#   InnoDB  - vertical lines ('|') for stacked indexes
PALETTE = {
    "TidesDB":    {"face": "#193EDB", "edge": "#0E257F", "hatch": "~~~"},
    "RocksDB":    {"face": "#F7B801", "edge": "#9C7300", "hatch": "**"},
    "InnoDB":     {"face": "#E17510", "edge": "#8A460A", "hatch": "|||"},
    "PostgreSQL": {"face": "#336791", "edge": "#1E3D58", "hatch": "..."},
}

def face(e):  return PALETTE.get(e, {"face": "#888"})["face"]
def edge(e):  return PALETTE.get(e, {"edge": "#444"})["edge"]
def hatch(e): return PALETTE.get(e, {"hatch": ""})["hatch"]

def fmt_compact(v, _pos=None):
    if v == 0: return "0"
    av = abs(v)
    if av >= 1e9:  return f"{v/1e9:.1f}B"
    if av >= 1e6:  return f"{v/1e6:.1f}M"
    if av >= 1e3:  return f"{v/1e3:.1f}k"
    if av >= 10:   return f"{v:.0f}"
    return f"{v:.2f}"

def fmt_value_label(v):
    if v == 0: return ""
    av = abs(v)
    if av >= 1e6:  return f"{v/1e6:.2f}M"
    if av >= 1e4:  return f"{v/1e3:.1f}k"
    if av >= 1e3:  return f"{v:,.0f}"
    if av >= 10:   return f"{v:.1f}"
    return f"{v:.2f}"

def style_axes(ax, y_label=None, title=None, subtitle=None):
    if title is not None and subtitle is not None:
        ax.text(0.0, 1.10, title, transform=ax.transAxes,
                fontsize=12, fontweight="semibold", color="#1a1a1a",
                ha="left", va="bottom")
        ax.text(0.0, 1.02, subtitle, transform=ax.transAxes,
                fontsize=9.5, color="#555555", style="italic",
                ha="left", va="bottom")
    elif title is not None:
        ax.text(0.0, 1.02, title, transform=ax.transAxes,
                fontsize=12, fontweight="semibold", color="#1a1a1a",
                ha="left", va="bottom")
    elif subtitle is not None:
        ax.text(0.0, 1.02, subtitle, transform=ax.transAxes,
                fontsize=9.5, color="#555555", style="italic",
                ha="left", va="bottom")
    if y_label is not None:
        ax.set_ylabel(y_label, labelpad=6)
    ax.yaxis.set_major_formatter(FuncFormatter(fmt_compact))
    ax.yaxis.set_major_locator(MaxNLocator(nbins=6))
    ax.axhline(0, color="#222222", linewidth=0.9, zorder=2)

def add_value_labels(ax, bars, vals, fmt=fmt_value_label, fontsize=9, dy_frac=0.012):
    ymax = ax.get_ylim()[1]
    dy = ymax * dy_frac
    for bar, v in zip(bars, vals):
        if v <= 0: continue
        txt = ax.text(
            bar.get_x() + bar.get_width()/2,
            bar.get_height() + dy,
            fmt(v),
            ha="center", va="bottom",
            fontsize=fontsize, fontweight="semibold",
            color="#1a1a1a",
        )
        txt.set_path_effects([
            path_effects.Stroke(linewidth=2.2, foreground="white"),
            path_effects.Normal(),
        ])

def add_footnote(fig, text):
    fig.text(0.005, -0.01, text, fontsize=8, color="#666666",
             style="italic", ha="left", va="top")

def headroom(values, factor=1.22):
    m = max(values) if values else 1
    return m * factor if m > 0 else 1

def draw_bars(ax, x, vals, engines, width=0.55,
              err_lo=None, err_hi=None):
    faces  = [face(e) for e in engines]
    edges  = [edge(e) for e in engines]
    hatches= [hatch(e) for e in engines]
    bars = ax.bar(x, vals, width,
                  color=faces, edgecolor=edges,
                  linewidth=1.1, zorder=3)
    for b, h in zip(bars, hatches):
        if h:
            b.set_hatch(h)
    if err_lo is not None and err_hi is not None and any((lo or hi) for lo, hi in zip(err_lo, err_hi)):
        yerr_lo = [max(0, v - lo) for v, lo in zip(vals, err_lo)]
        yerr_hi = [max(0, hi - v) for v, hi in zip(vals, err_hi)]
        ax.errorbar(x, vals, yerr=[yerr_lo, yerr_hi],
                    fmt="none", ecolor="#1a1a1a", elinewidth=1.0,
                    capsize=4, capthick=1.0, zorder=4)
    return bars

def engine_legend(ax, engines, loc="best", ncol=1, title=None):
    from matplotlib.patches import Patch
    handles = []
    for e in engines:
        p = Patch(facecolor=face(e), edgecolor=edge(e),
                  linewidth=1.0, hatch=hatch(e), label=e)
        handles.append(p)
    leg = ax.legend(handles=handles, loc=loc, ncol=ncol, title=title,
                    borderaxespad=0.6)
    leg.get_frame().set_linewidth(0.7)
    return leg

tpcc_rows = [r for r in rows if r["benchmark"] == "TPC-C"]
tpch_rows = [r for r in rows if r["benchmark"] == "TPC-H"]

def ordered_engines(rs):
    canonical = ["TidesDB", "RocksDB", "InnoDB", "PostgreSQL"]
    present = set(r["engine"] for r in rs)
    ordered = [e for e in canonical if e in present]
    extra = [e for e in present if e not in canonical]
    return ordered + sorted(extra)

def get_val(rs, engine, col):
    r = next((r for r in rs if r["engine"] == engine), None)
    if r is None: return 0, 0, 0
    return safe_float(r.get(col, 0)), safe_float(r.get(col+"_min", 0)), safe_float(r.get(col+"_max", 0))

merge_note = ""
if multi_run:
    runs = max(r.get("_n_runs", 1) for r in rows)
    merge_note = f"  Aggregated across {runs} runs (bar = median, whiskers = min/max)."

# ============================================================
#  TPC-C: NOPM
# ============================================================
if tpcc_rows:
    engines = ordered_engines(tpcc_rows)
    wh  = tpcc_rows[0].get("warehouses", "?")
    vu  = tpcc_rows[0].get("virtual_users", "?")
    dur = tpcc_rows[0].get("duration_min", "?")

    fig, ax = plt.subplots(figsize=(max(4.4, len(engines) * 1.55), 4.4))
    x = np.arange(len(engines))
    nopm_vals = []; nopm_lo = []; nopm_hi = []
    for e in engines:
        v, lo, hi = get_val(tpcc_rows, e, "nopm")
        nopm_vals.append(v); nopm_lo.append(lo); nopm_hi.append(hi)
    bars = draw_bars(ax, x, nopm_vals, engines,
                     err_lo=nopm_lo if multi_run else None,
                     err_hi=nopm_hi if multi_run else None)
    ax.set_xticks(x)
    ax.set_xticklabels(engines)
    ax.set_ylim(0, headroom([max(v, h) for v, h in zip(nopm_vals, nopm_hi)]))
    style_axes(ax,
        y_label="New-order transactions per minute",
        title="TPC-C throughput (NOPM)",
        subtitle=f"{wh} warehouses, {vu} virtual users, {dur} min measured  -  higher is better")
    add_value_labels(ax, bars, nopm_vals)
    add_footnote(fig, "Source: HammerDB TPROC-C." + merge_note)
    fig.tight_layout()
    for ext in ("png", "pdf"):
        p = os.path.join(out_dir, f"chart_tpcc_nopm.{ext}")
        fig.savefig(p); print(f"  Chart: {p}")
    plt.close(fig)

    # TPM
    fig, ax = plt.subplots(figsize=(max(4.4, len(engines) * 1.55), 4.4))
    tpm_vals = []; tpm_lo = []; tpm_hi = []
    for e in engines:
        v, lo, hi = get_val(tpcc_rows, e, "tpm")
        tpm_vals.append(v); tpm_lo.append(lo); tpm_hi.append(hi)
    bars = draw_bars(ax, x, tpm_vals, engines,
                     err_lo=tpm_lo if multi_run else None,
                     err_hi=tpm_hi if multi_run else None)
    ax.set_xticks(x)
    ax.set_xticklabels(engines)
    ax.set_ylim(0, headroom([max(v, h) for v, h in zip(tpm_vals, tpm_hi)]))
    style_axes(ax,
        y_label="Transactions per minute",
        title="TPC-C total transaction rate (TPM)",
        subtitle=f"{wh} warehouses, {vu} virtual users, {dur} min measured  -  higher is better")
    add_value_labels(ax, bars, tpm_vals)
    add_footnote(fig, "Source: HammerDB TPROC-C.  Includes NewOrder, Payment, OrderStatus, Delivery, StockLevel." + merge_note)
    fig.tight_layout()
    for ext in ("png", "pdf"):
        p = os.path.join(out_dir, f"chart_tpcc_tpm.{ext}")
        fig.savefig(p); print(f"  Chart: {p}")
    plt.close(fig)

    # Latency
    tx_types  = ["neword", "payment", "delivery"]
    tx_labels = ["New Order", "Payment", "Delivery"]
    has_timing = any(safe_float(r.get("neword_avg_ms", 0)) > 0 for r in tpcc_rows)
    if has_timing:
        fig, axes = plt.subplots(1, 2, figsize=(10.5, 4.6), sharey=False)
        for ax_idx, (metric_suffix, subtitle) in enumerate([
                ("avg_ms", "Mean latency"),
                ("p95_ms", "95th-percentile latency")]):
            ax = axes[ax_idx]
            lx = np.arange(len(tx_types))
            n = len(engines)
            width = min(0.78 / n, 0.30)
            offsets = np.linspace(-(n-1)*width/2, (n-1)*width/2, n)
            local_max = 0
            bar_groups = []
            for i, eng in enumerate(engines):
                row = next((r for r in tpcc_rows if r["engine"] == eng), {})
                vals = [safe_float(row.get(f"{t}_{metric_suffix}", 0)) for t in tx_types]
                his  = [safe_float(row.get(f"{t}_{metric_suffix}_max", 0)) for t in tx_types]
                los  = [safe_float(row.get(f"{t}_{metric_suffix}_min", 0)) for t in tx_types]
                local_max = max(local_max, max(vals + his) if (vals or his) else 0)
                bars = ax.bar(lx + offsets[i], vals, width,
                              color=face(eng), edgecolor=edge(eng),
                              linewidth=1.0, zorder=3, label=eng)
                if hatch(eng):
                    for b in bars:
                        b.set_hatch(hatch(eng))
                bar_groups.append((bars, vals))
                if multi_run and any(hi > 0 for hi in his):
                    yerr_lo = [max(0, v-lo) for v, lo in zip(vals, los)]
                    yerr_hi = [max(0, hi-v) for v, hi in zip(vals, his)]
                    ax.errorbar(lx + offsets[i], vals, yerr=[yerr_lo, yerr_hi],
                                fmt="none", ecolor="#1a1a1a", elinewidth=0.8,
                                capsize=3, capthick=0.8, zorder=4)
            ax.set_xticks(lx)
            ax.set_xticklabels(tx_labels)
            ax.set_ylim(0, headroom([local_max], factor=1.32))
            style_axes(ax,
                y_label="Response time (ms)" if ax_idx == 0 else None,
                title=subtitle,
                subtitle="lower is better")
            ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _p: f"{v:.0f}" if v >= 10 else f"{v:.1f}"))
            for bars, vals in bar_groups:
                for rect, v in zip(bars, vals):
                    if v > 0:
                        t = ax.text(rect.get_x() + rect.get_width()/2,
                                    v + local_max * 0.012,
                                    f"{v:.1f}" if v < 100 else f"{v:.0f}",
                                    ha="center", va="bottom",
                                    fontsize=7.5, fontweight="semibold",
                                    color="#1a1a1a")
                        t.set_path_effects([
                            path_effects.Stroke(linewidth=1.8, foreground="white"),
                            path_effects.Normal()])
            if ax_idx == 0:
                engine_legend(ax, engines, loc="upper left", title="Engine")
        fig.suptitle(f"TPC-C transaction response times  -  {wh} warehouses, {vu} VUs",
                     x=0.01, ha="left", y=1.02)
        add_footnote(fig, "Source: HammerDB TPROC-C time profile.  Lower bars are faster." + merge_note)
        fig.tight_layout()
        for ext in ("png", "pdf"):
            p = os.path.join(out_dir, f"chart_tpcc_latency.{ext}")
            fig.savefig(p); print(f"  Chart: {p}")
        plt.close(fig)

# ============================================================
#  TPC-H
# ============================================================
if tpch_rows:
    engines = ordered_engines(tpch_rows)
    sf = tpch_rows[0].get("scale_factor", "?")
    qs = tpch_rows[0].get("querysets", "?")

    fig, axes = plt.subplots(1, 2, figsize=(10.5, 4.6))
    x = np.arange(len(engines))

    ax = axes[0]
    geo_vals = []; geo_lo = []; geo_hi = []
    for e in engines:
        v, lo, hi = get_val(tpch_rows, e, "tpch_geomean_sec")
        geo_vals.append(v); geo_lo.append(lo); geo_hi.append(hi)
    bars = draw_bars(ax, x, geo_vals, engines,
                     err_lo=geo_lo if multi_run else None,
                     err_hi=geo_hi if multi_run else None)
    ax.set_xticks(x)
    ax.set_xticklabels(engines)
    ax.set_ylim(0, headroom([max(v, h) for v, h in zip(geo_vals, geo_hi)]))
    style_axes(ax,
        y_label="Time (seconds)",
        title="Geometric mean query time",
        subtitle="lower is better")
    add_value_labels(ax, bars, geo_vals, fmt=lambda v: f"{v:.2f}s")

    ax = axes[1]
    tot_vals = []; tot_lo = []; tot_hi = []
    for e in engines:
        v, lo, hi = get_val(tpch_rows, e, "tpch_total_sec")
        tot_vals.append(v); tot_lo.append(lo); tot_hi.append(hi)
    bars = draw_bars(ax, x, tot_vals, engines,
                     err_lo=tot_lo if multi_run else None,
                     err_hi=tot_hi if multi_run else None)
    ax.set_xticks(x)
    ax.set_xticklabels(engines)
    ax.set_ylim(0, headroom([max(v, h) for v, h in zip(tot_vals, tot_hi)]))
    style_axes(ax,
        y_label="Time (seconds)",
        title="Total query-set execution time",
        subtitle="lower is better")
    add_value_labels(ax, bars, tot_vals, fmt=lambda v: f"{v:.1f}s")

    fig.suptitle(f"TPC-H query performance  -  scale factor {sf}, {qs} query set(s)",
                 x=0.01, ha="left", y=1.02)
    add_footnote(fig, "Source: HammerDB TPROC-H.  Geometric mean across the 22 queries." + merge_note)
    fig.tight_layout()
    for ext in ("png", "pdf"):
        p = os.path.join(out_dir, f"chart_tpch.{ext}")
        fig.savefig(p); print(f"  Chart: {p}")
    plt.close(fig)

# ============================================================
#  BUILD TIME
# ============================================================
if len(rows) >= 2:
    labels = [f"{r['benchmark']}\n{r['engine']}" for r in rows]
    build_vals = [safe_float(r.get("build_sec", 0)) for r in rows]
    engines_per_row = [r["engine"] for r in rows]

    fig, ax = plt.subplots(figsize=(max(5.5, len(rows) * 1.45), 4.4))
    x = np.arange(len(rows))
    bars = ax.bar(x, build_vals, 0.55,
                  color=[face(e) for e in engines_per_row],
                  edgecolor=[edge(e) for e in engines_per_row],
                  linewidth=1.1, zorder=3)
    for b, e in zip(bars, engines_per_row):
        if hatch(e):
            b.set_hatch(hatch(e))
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_ylim(0, headroom(build_vals))
    style_axes(ax,
        y_label="Build time (seconds)",
        title="Schema build time",
        subtitle="lower is better")
    add_value_labels(ax, bars, build_vals,
                     fmt=lambda v: f"{v/60:.1f}m" if v >= 120 else f"{v:.0f}s")
    add_footnote(fig, "Source: end-to-end HammerDB schema build (table create + data load + index/primary key).")
    fig.tight_layout()
    for ext in ("png", "pdf"):
        p = os.path.join(out_dir, f"chart_build_time.{ext}")
        fig.savefig(p); print(f"  Chart: {p}")
    plt.close(fig)



# ============================================================
#  SAMPLE-BASED CHARTS (throughput-over-time, latency-over-time, perf hotspots)
# ============================================================
import re, glob

def find_log_dir_for_csv(csv_path):
    """A CSV at <dir>/hammerdb_results_<ts>.csv has logs at <dir>/hammerdb_logs_<ts>/.
    In plot-only mode the user may also pass the log dir itself as out_dir.
    Returns list of candidate directories to scan."""
    candidates = [out_dir]  # always try the chart output dir
    base = os.path.basename(csv_path)
    parent = os.path.dirname(csv_path)
    m = re.match(r"hammerdb_results_(.+)\.csv$", base)
    if m:
        ts = m.group(1)
        sib = os.path.join(parent, f"hammerdb_logs_{ts}")
        if os.path.isdir(sib):
            candidates.append(sib)
    # also try the csv's parent itself (in case files were copied)
    candidates.append(parent)
    # dedupe
    seen = set(); out = []
    for c in candidates:
        c = os.path.abspath(c)
        if c not in seen:
            seen.add(c); out.append(c)
    return out

def collect_engine_files(pattern_glob):
    """Scan all candidate log dirs across all input CSVs. Return dict {engine: filepath}.
    pattern_glob takes the form 'TPC-C_{engine}_<...>.<...>' - we accept either:
        TPC-C_<Engine>_hdbtcount*.log
        TPC-C_<Engine>_perf_report.txt
        TPC-C_<Engine>_run.log
        TPC-C_<Engine>_rocksdb_status.txt
    and return the FIRST match per engine."""
    found = {}
    search_dirs = set()
    for path in csv_paths:
        for d in find_log_dir_for_csv(path):
            search_dirs.add(d)
    for d in search_dirs:
        for fp in glob.glob(os.path.join(d, pattern_glob)):
            base = os.path.basename(fp)
            # parse engine name out of "TPC-C_<Engine>_..."
            mm = re.match(r"TPC-C_([A-Za-z]+)_", base)
            if mm:
                eng = mm.group(1)
                if eng not in found:
                    found[eng] = fp
    return found

# ============================================================
#  THROUGHPUT-OVER-TIME (from hdbtcount*.log)
# ============================================================
def parse_hdbtcount(path):
    """Parse HammerDB transaction counter log:
        <tpm> <DBname> tpm @ <timestamp>
       Returns list of (seconds_from_start, tpm). First sample is 0 tpm at t=0
       and represents the rampup boundary; we keep it for context."""
    samples = []
    if not os.path.exists(path):
        return samples
    t0 = None
    with open(path, errors="replace") as f:
        for line in f:
            line = line.strip()
            # expected: "<tpm> <dbname> tpm @ <timestamp>"
            #   or:    "<tpm> <dbname> tpm"
            m = re.match(r"^(\d+)\s+\S+\s+tpm(?:\s*@\s*(.+))?$", line)
            if not m:
                continue
            tpm = int(m.group(1))
            ts_str = (m.group(2) or "").strip()
            import time
            if ts_str:
                # HammerDB timestamps look like "Fri May 07 15:31:33 BST 2021"
                # Try a couple of strptime formats; fall back to ordinal counter.
                parsed = None
                for fmt in ("%a %b %d %H:%M:%S %Z %Y",
                            "%a %b %d %H:%M:%S %Y"):
                    try:
                        parsed = time.mktime(time.strptime(ts_str, fmt))
                        break
                    except (ValueError, OverflowError):
                        continue
                if parsed is not None:
                    if t0 is None:
                        t0 = parsed
                    samples.append((parsed - t0, tpm))
                    continue
            # no usable timestamp - fall back to 10-second-interval assumption
            samples.append((len(samples) * 10, tpm))
    return samples

tx_logs = collect_engine_files("TPC-C_*_hdbtcount*.log")
if tx_logs:
    fig, ax = plt.subplots(figsize=(9.5, 4.8))
    engines = sorted(tx_logs.keys(),
                     key=lambda e: ["TidesDB","RocksDB","InnoDB","PostgreSQL"].index(e)
                                   if e in ["TidesDB","RocksDB","InnoDB","PostgreSQL"] else 99)
    for eng in engines:
        samples = parse_hdbtcount(tx_logs[eng])
        if not samples:
            continue
        xs = [s[0] / 60.0 for s in samples]  # minutes
        ys = [s[1] for s in samples]
        ax.plot(xs, ys,
                color=face(eng), linewidth=1.6,
                marker="o", markersize=4, markerfacecolor=face(eng),
                markeredgecolor=edge(eng), markeredgewidth=0.7,
                label=eng, zorder=3)
    style_axes(ax,
        y_label="Transactions per minute",
        title="TPC-C throughput over time",
        subtitle="10-second sampling intervals during the measured run  -  dips reveal compaction stalls and contention")
    ax.set_xlabel("Elapsed time (minutes from start of measurement)")
    ax.set_ylim(bottom=0)
    # disable matplotlib scientific notation - we use the compact fmt instead
    ax.yaxis.get_major_formatter().set_scientific(False) if hasattr(ax.yaxis.get_major_formatter(), 'set_scientific') else None
    ax.yaxis.set_major_formatter(FuncFormatter(fmt_compact))
    leg = ax.legend(loc="lower right", title="Engine",
                    frameon=True, framealpha=0.96, edgecolor="#bdbdbd")
    leg.get_frame().set_linewidth(0.7)
    add_footnote(fig, "Source: HammerDB transaction counter log (hdbtcount.log).  Smooth curves indicate steady-state performance; troughs typically correspond to LSM compaction or write-stall events.")
    fig.subplots_adjust(top=0.85)
    fig.tight_layout()
    for ext in ("png", "pdf"):
        p = os.path.join(out_dir, f"chart_tpcc_throughput_timeline.{ext}")
        fig.savefig(p); print(f"  Chart: {p}")
    plt.close(fig)

# ============================================================
#  LATENCY-OVER-TIME (from xtprof PERCENTILES blocks in run.log)
# ============================================================
def parse_xtprof_percentiles(path, tx_name="neword"):
    """Parse xtprof PERCENTILES windows from a HammerDB run log.
    Format:
       Vuser N:|PERCENTILES 2019-07-05 09:55:46 to 2019-07-05 09:55:56
       Vuser N:|neword|MIN-391|P50%-685|P95%-1286|P99%-3298|MAX-246555|SAMPLES-3603
       ...
    Returns list of (window_idx, p50_us, p95_us, p99_us) aggregated across all VUs
    (median across VUs within the same window)."""
    if not os.path.exists(path):
        return []
    import collections
    # Map window_start_str -> list of (p50,p95,p99) tuples, one per VU
    windows = collections.OrderedDict()
    current_window = None
    cur_perc_re = re.compile(
        r"Vuser\s+\d+:\|PERCENTILES\s+(\S+\s+\S+)\s+to\s+"
    )
    line_re = re.compile(
        r"Vuser\s+\d+:\|" + re.escape(tx_name) +
        r"\|MIN-\d+\|P50%-(\d+)\|P95%-(\d+)\|P99%-(\d+)\|MAX-\d+\|SAMPLES-\d+",
        re.IGNORECASE
    )
    with open(path, errors="replace") as f:
        for line in f:
            m = cur_perc_re.search(line)
            if m:
                current_window = m.group(1)
                windows.setdefault(current_window, [])
                continue
            m = line_re.search(line)
            if m and current_window:
                p50, p95, p99 = int(m.group(1)), int(m.group(2)), int(m.group(3))
                windows[current_window].append((p50, p95, p99))
    # aggregate per window: take median across VUs
    out = []
    for i, (_, vu_list) in enumerate(windows.items()):
        if not vu_list:
            continue
        p50s = sorted(v[0] for v in vu_list)
        p95s = sorted(v[1] for v in vu_list)
        p99s = sorted(v[2] for v in vu_list)
        def med(xs):
            n = len(xs)
            if n == 0: return 0
            return xs[n//2] if n % 2 else 0.5*(xs[n//2-1]+xs[n//2])
        out.append((i, med(p50s), med(p95s), med(p99s)))
    return out

run_logs = collect_engine_files("TPC-C_*_run.log")
if run_logs:
    # collect data per engine; only plot if any engine has parseable percentiles
    series = {}
    for eng, path in run_logs.items():
        s = parse_xtprof_percentiles(path, "neword")
        if s:
            series[eng] = s
    if series:
        fig, ax = plt.subplots(figsize=(9.5, 4.6))
        engines = sorted(series.keys(),
                         key=lambda e: ["TidesDB","RocksDB","InnoDB","PostgreSQL"].index(e)
                                       if e in ["TidesDB","RocksDB","InnoDB","PostgreSQL"] else 99)
        for eng in engines:
            samples = series[eng]
            # 10-second windows -> minutes (xtprof samples every 10s by default)
            xs = [s[0] * 10 / 60.0 for s in samples]
            p95s = [s[2] / 1000.0 for s in samples]  # us -> ms
            ax.plot(xs, p95s,
                    color=face(eng), linewidth=1.6,
                    marker="o", markersize=4, markerfacecolor=face(eng),
                    markeredgecolor=edge(eng), markeredgewidth=0.7,
                    label=eng, zorder=3)
        style_axes(ax,
            y_label="New Order p95 latency (ms)",
            title="TPC-C tail latency over time",
            subtitle="10-second windows, median across virtual users  -  spikes correlate with stalls / compaction")
        ax.set_xlabel("Elapsed time (minutes from start of measurement)")
        ax.set_ylim(bottom=0)
        leg = ax.legend(loc="upper right", title="Engine",
                        frameon=True, framealpha=0.96, edgecolor="#bdbdbd")
        leg.get_frame().set_linewidth(0.7)
        add_footnote(fig, "Source: HammerDB xtprof time profile (PERCENTILES blocks).  Lower and flatter is better.")
        fig.tight_layout()
        for ext in ("png", "pdf"):
            p = os.path.join(out_dir, f"chart_tpcc_latency_timeline.{ext}")
            fig.savefig(p); print(f"  Chart: {p}")
        plt.close(fig)

# ============================================================
#  PERF HOTSPOTS - top symbols per engine
# ============================================================
def parse_perf_report(path, top_n=8):
    """Parse 'perf report --stdio --no-children --sort=dso,symbol --percent-limit=1' output.
    Returns list of (pct, dso, symbol) for top N entries."""
    if not os.path.exists(path):
        return []
    rows = []
    # data lines look like:
    #     5.42%  mariadbd       [.] my_function_name
    line_re = re.compile(r"^\s*(\d+\.\d+)%\s+(\S+)\s+\[.\]\s+(.+?)\s*$")
    with open(path, errors="replace") as f:
        for line in f:
            line = line.rstrip()
            if not line or line.startswith("#"):
                continue
            m = line_re.match(line)
            if m:
                pct = float(m.group(1))
                dso = m.group(2)
                sym = m.group(3)
                rows.append((pct, dso, sym))
            if len(rows) >= top_n:
                break
    return rows

perf_reports = collect_engine_files("TPC-C_*_perf_report.txt")
if perf_reports:
    hotspots = {}
    for eng, path in perf_reports.items():
        h = parse_perf_report(path, top_n=8)
        if h:
            hotspots[eng] = h
    if hotspots:
        engines = sorted(hotspots.keys(),
                         key=lambda e: ["TidesDB","RocksDB","InnoDB","PostgreSQL"].index(e)
                                       if e in ["TidesDB","RocksDB","InnoDB","PostgreSQL"] else 99)
        n = len(engines)
        fig, axes = plt.subplots(1, n, figsize=(4.8 * n, 5.0), sharex=False)
        if n == 1:
            axes = [axes]
        for ax, eng in zip(axes, engines):
            rows_e = hotspots[eng]
            # bottom = highest %, top = lowest -> reverse so top of chart is hottest
            rows_e = list(reversed(rows_e))
            pcts = [r[0] for r in rows_e]
            labels = []
            for _, dso, sym in rows_e:
                # truncate long symbols
                if len(sym) > 38:
                    sym = sym[:35] + "..."
                labels.append(sym)
            y = np.arange(len(rows_e))
            bars = ax.barh(y, pcts,
                           color=face(eng), edgecolor=edge(eng),
                           linewidth=1.0, zorder=3)
            if hatch(eng):
                for b in bars:
                    b.set_hatch(hatch(eng))
            ax.set_yticks(y)
            ax.set_yticklabels(labels, fontsize=8.5, family="monospace")
            ax.set_xlim(0, max(pcts) * 1.20 if pcts else 1)
            ax.set_xlabel("CPU time (%)", fontsize=10)
            # value labels at end of bars
            for bar, p in zip(bars, pcts):
                ax.text(bar.get_width() + max(pcts)*0.01, bar.get_y() + bar.get_height()/2,
                        f"{p:.1f}%", va="center", ha="left",
                        fontsize=8.5, fontweight="semibold", color="#1a1a1a")
            ax.text(0.0, 1.03, eng, transform=ax.transAxes,
                    fontsize=12, fontweight="semibold", color="#1a1a1a",
                    ha="left", va="bottom")
            ax.grid(axis="x", color="#cfcfcf", linewidth=0.55, alpha=0.7)
            ax.set_axisbelow(True)
            for spine in ("top", "right"):
                ax.spines[spine].set_visible(False)
        fig.suptitle("CPU hotspots during TPC-C  -  top symbols by sampled CPU time",
                     x=0.01, ha="left", y=1.02)
        add_footnote(fig, "Source: perf record (call-graph fp) on the database server.  Symbols sorted by exclusive (self) CPU time.")
        fig.tight_layout()
        for ext in ("png", "pdf"):
            p = os.path.join(out_dir, f"chart_perf_hotspots.{ext}")
            fig.savefig(p); print(f"  Chart: {p}")
        plt.close(fig)

print("")
print("  All charts saved to: " + out_dir)
print("  Formats: PNG (300 dpi, presentations/web) + PDF (vector, papers)")
PYEOF
    echo ""
else
    echo "  WARNING: python3 not found, skipping chart generation"
    echo "  Install with: sudo apt install python3 python3-matplotlib"
fi

echo "Done."
