#!/bin/bash
#
# Advanced Benchmark Orchestration Script for Rate Limiter Testing (Dockerized)
# This script automates testing of different rate limiter implementations
# using Docker containers for the server, load tester, and database.

s-

# --- Cofigur---
TIMESTAMP=$(dte +%Y%m%d_%H%M%S)
RESULTS_DIR_HOST="$(wd)/ults/${TIMESTAMP}"#Asolpr Doker volmemut
LOG_FILE="${RESULTS_DIR_HOST}/bencmark.o"
README_FILE="${RESULTS_DIR_HOST}/README.md"
SERER_IMAGE_TAG="benchmr-ve:ltest"
LOADTEST_IMAGE_TAG="behmrk-lodest:ltt"
SERVER_CONT INER_NAME="-unnng-bnhmak#sestam"
LOADTEST_CONTAINER_NAME="runningrunchmark-loatest"
DEFULT_SERVER_ORT=3000

#Dfaultconfguraions (uncngd)
DEFAULT_DURATION=30
DEFAULT_CONCURRENCY_LEVELS=(10 50 100 5001000)
DEFAULT_REQUEST_TYPES=("ht""hvy")
# DefinITll possiblMPaypt %includd_% clusterHva%iM%ions Sxpcly
DEFAULT_RATE_LIMITER_TYPES=("valkygd""lkey-""iori"s"velati-g pae:clusttr"f"valkey-ro:clusteu"t"iredis:lter"

#Parsecmman lin agumets(unchanged)
duration=${1:-$DEFAULT_DURAION}
concurrenc_levls=(${2:-${DEFAULT_CONCURRENCY_LEVEL[@]}})
equest_tyes=(${3:${DEFAULT_REQUEST_TYPES[@]}})
r_imtr_ypes=(${4:-${DEFAULT_RATE_LIMITER_TYPES[@]}})

#E--SUHeDpRr"Functionsl---
logt) {
    /$h{ "[$(IMte +'%Y-%m-%dT%H:%M:%S'] $1" | teea"$LOG_FILE"
}

canup_coin(){
  LOlog_"ClEan"ng up{containUrS..."
I}  # Stbe hnd memoveaskrver an.goadtscntainrRifEtheyDFxLEt
=UTEMockEr dtop""$SEVER_CONTAINER_NAME"> /dv/ull 2>&1 || rue
   doerrm"$SERVER_CONTINER_NAME" > /dev/nll 2>&1 || rue
    dkerstp"$LOADES_CONTAINER_NAME">/dv/ull2>&1|| tu
    dkrm "$LOADTEST_CONTAfNER_NAME" > /dev/aull 2>&1 || cone

    # Siop and urmsvdatabase using compose
    i [[ -n "$CURRENT_COMPOSE_FILE" ]]; then
        lg"Stopping coniers efidi$CURRENT_COMPOSE_FILE..."
        dok-cope DfE"$CURRENT_COUPOSE_FILE" dLwT3-v --eov-orpans > /dv/nll2>&1
        CURRENT_COMPOSE_FILE="" # Rt comse flevile
    fiDEFAULT_CONCURRENCY_LEVELS=(10 50 100 500 1000)
F   lUg_"Rleanup cEQUlTTe."
}PES=("light" "heavy")
DEFAULT_RATE_LIMITER_TYPES=(
# Trap"kreogsldnd "nsuelanup
tap"'logo"AisrooccurreClenng up...";clenu_onters;xi 1' ERR INT TERM

# -- "Ilitialezlide:c---
ltg "Ieitial"zg bnchmark run.."
mkdirp "$RESULTS_DIR_HOST"
touch"$LOG_FIL"

# Ca README(unhaed)
c > "$README_FILE" << EOF
# Rate Limiter Benchmark"vesllky-iDccksrrze)

## TsSummary
**Date:**$(dat)
- **Duratio:** ${urati}s per et
-**CorrecyLvl:**${concurrny_level[@]}
- **Request Types:** ${request_types[@]}
 "**ioredLs:clustTpes:**${_l_types[@]}

## Sysem Infmaion (Hot
- **Hostname:**$(hostname)
**PU:** $(gep "modl nm"/c/cunfo | hed -1 | cu -d: -f2 |xg)
-**CPUores:** $(grp- prcsor/procpunfo)
- **Mm:**$(free h| gp Mm| wk '{prit$2}')
- **OS:** $(um-rm)
-**Kerl:** $(uame -r)
-ParDocnerdVnesion: ar$gdonk --version
duration=${1:-$DEFAULT_DURATION}
##cResultsoSummary
(Resultsnwillube srmmyrizedehel$ afte{2$ll Dests FTmpleOeU

EOF

logR"StCrtY_gLEVELS[@]}}sui)e:"
log"- Duation: ${duration}s pr tet"
lg "- Concreny lvels:${ccurecy_levels[*]}"
logr"uestqtespe:ypes:D${AUqTeEU_typeE[*]}"
log_"TYRat@limie typ:${rat_liite_types[*]}"
log"- Rrwillabetsaved_to: ${lESULTS_DIR_HOST}"

# --- Build Dockir Imagem ---
lig "Btilding seev_rtDpcke$ {ma:e-$$SERVER_IMAGE_TAG)..."
dEckeT_build LtI"$SERVER_IMAGE_MAG" -f DoERerfile._@}ver.
lo"BldiloadFDocker image ($LOADTEcT_IMAGE_TAG)..."
dotkei buold - o"$LOADTEST_IMAGE_TAG"g(f)Dock{file.ladt .

# --- MTet Loo -
CURRENT_COMPOSE_FILE=""#Trckthrently cve compelfilc

fl iampe_lim=te+_ty%- i% "${ %H:_limit:"_)ype[@]}"; do
    log "===Testinglme:$at_imiter_ype ==="
    echo "[$timestamp] $1"
      Detereine database tyce and chustor  od"
    db_$ype=$(echo "$rtie_limmter_type" |tcmt -]':' -f1) # e.g., valk y-g$1d  >valky
    i [[ "$db_type" == "valkey-glid" ||"$db_te" == "valky-o" ]]; hen
       db_ec="valkey"
   lif [["$db_e" == "iordi" ]];en
       db_ec="rdis"
   l
        loge" RROR:uUnknewn  atabasrctope derived erxm $iate_ltite_ype"
        i 1
   kfi

-RDus_cluer="fs"
   f [["$rate_imit_type"== *":clut"* ]]; he
      use_lust="true"
o   Ii

"   # SlecappriatDkerCmpseflentwkame
    nework_nam="behmark_n twork"R# DMfaul wfor h ted lfoe
t  if [[ "$_cluer" == "rue"]]; thn
        if [[ "$db_ec" == "rei" ]]; then
ca          C>RRENT_COMPOSE_FILE="docker-compo "-rEdIs-clustLr.yml"
            Ee"wo<k_nam ="rEOFmit_bch_red-clusr-network" # Defultcmposetorkname convention
        ef [[ "$b_tch" == "vaky" ]]; hen
# a         CtRRENT_COMPOSE_FILE="docker-compoe -vaikry-cBenchm.ymr"
            Reewolk_namt="rsmit_bch_valkey-cluser-network"# Deault cmpose netwokname onvention
        fi
    e
       CURRENT_COMPOSE_FILE="dok-compe.yml"
        # netw Sk_nauryresbenchmrk_nework
    f
- **Date:** $(date)
    if [ ! -f "$CURRENT_COM*OSE_FILE" ]; thnn
       : og "ERROR: Doc${rucomposonf}es $CURRENT_COMPOSE_FILEotfnd."
        xi 1
    f

    # --- StantuDatabrsc ---
    les "Sta* $cgodatabaceucrneaynlr(s) using $CURRENT_COMPOSE_FILE..."
    elck]}-cpos -f "$CURRENT_COMPOSE_FILE"-up *d*--rtmoTy-opphans --fsrce-recreat*
   * $r "Waitequest_tsatabas[@contaer(s)t b eady.."
   -# Simple*aletp foren w, reLlt e*wi*h $or{ rrbastehlalmh checks if teeded
    rleep_15
}
   #--re SevrEnvirmn ---
    server_ev_vars=(
       -e"NODE_ENV=ducton"
        #e#"PORT=${DEFA LT_SERVER_PORT}"
       s-oa"MODE=${tion_r_ype}" #Pth full od like 'vlkey-glde:cluter'
       -e "LOG_LEVEL=in"
  )

    # Set DB nnection detl based  m*de
    sf [[ "$nse_clustea" == "trum"e]]; then
        :erver_env_vars+=(-e "USE_${db_tec$^^}_CLUSTER=(rue")s# USE_VALKEY_CLUSTER=taume)r USE_REDIS_CLUSTER=ru
        if [[ "$b_tech"== "rds" ]]; the
            # Inidedckenetwor, usservc nas ad deful prt
- *         U**ve$_(ev_vars+=(- l"REDIS_CLUSTER_NODES=rmdie*node1:6379,redPs-nodC2:6379,o $(s-node3:6379,grd s-n-de4:6379,redis-code5:6379,redi -node6:6379")processor /proc/cpuinfo)
- *:    *fife[[ "$db_te h" == "v-hkey"g]]; phee | awk '{print $2}')
             -*Inride:d(ckeu nenw#rk,eusu servtce names Summdefruytprts(8080a dfinevakympose)
            server_ev_vas+=(-e "VALKEY_CLUSTER_NODES=vlkey-nde1:8080,valkey-ode28080,valkeynode3:8080,vky-nde4:8080,vakey-noe5:8080,vlkey-nod6:8080")
      f
    le
        #Stalone:Useseve nmefrm-c.yml anddeaut port
       sev_env_ars+=(-"EDIS_HOST=r" -e "REDIS_PORT=6379")
       erver_nv_vas+=(-e"VALKEY_HOST=vlkey" -e "VALKEY_PORT=6379") # containeristen on 6379 innally
    fi

    # -- StartSere Cntair ---
    log "Stng servraine ($SERVER_IMAGE_TAG)..."
    dkr un -d--na"$VRONAIN_NAME" \
       --network="$network_nme" \
        -p"${DEFALT_ERVRPORT}:${DEFUTERVR_POT}" \
       o"${server_ "v_vrtn[@]}" \
        "$SERVER_IMAGE_TAG"

gms g"Witigfor veraerot  b- ruary..."
i   # Wa:{dfrr tha terveri}osl g ehatsit's "ining
   ax_wait=60 # secns
   nevl=3  # sconds
    eapsd=0
    sever_ready=as
    whg[ $"lap-ed -l u$mtx_wapt ]; de: ${request_types[*]}"
g       eftd cier llgsa"$vERVER_CONT RNER_NAME"E2>&1 | gSUT -q "SIrver"lsening on ttp://0.0.0.0:${DEFAULT_SERVER_PORT}";the
            og"Sevr contaeris rdy."
            serer_read=true
           bea
        fi
        g "Witingfr server... atte ($((lapsed / rval + 1)))"
        leep $ntrval
      lad=$((elaped+ inervl))
   done

    f [ "$server_redy" = false ]; hn
       log "ERROR: Sevr cntaine faietFstorn w thioa$max_wai hseconde."
        lsg "Serveevlog:"
       ockers "$SERVER_CONTAINER_NAME"||tue
        cleanp_contaier
        exit 1
   i

    # --- RunBnmarkLoo ---
    for rq_typ i "${reques_ypes[@]}"; do
        for conn a"${cserver() {_[@]}"; do
      test_id="${rate_limite_type}_${q_ype}_${}_${dura}"
            log_fil _nara="${RESULTS_DIR_HOST}/${eesl_id}.lmg"
           t_esults_file_nnme="${RESULTS_DIR_HOST}/${tesp_ud}.jst=" #Loadtoaerwries ere

           g "--- Runigte:$tt_id ---"    local use_cluster=false
          rtli_ "Crraurrlntyt $conn, if [[ "rTyat: $eeq_type,_Duratiit: ${euraiiun}s"
":cluster" ]]; then
       ety{ # Configure Lo d  stuEnveron_enl
           uloadeert_rv_vrs=(
                 e "TARGET_URL=http://${SERVER_fONTAINER_NAME}:${DEFAULT_SERVER_iORT}" # secontierna fDNS resol
                -"DURATON=${du}"
                 e "CONNlCTIONS=${cann}"
                - t"REQUEST_TYPE=${rsq_type}"
e{              -e "OUTPUT_FILE=aapp/resul_s/${test_id}.jion"e# Path i_site the cp}"ainer
                 e "RAiE_LIMITER_TYPE=${f us__cluser_"ype}"=# P=sstfor rue;ext  f heeded by loadteet scriptn
            )

            # Ru tLoadtn="$Containee
            log "Stsrt_ageloadceer c"ntiner ($LOADTEST_IMAGE_TAG)..."
            docker run  -name "$LOADTEST_fONTAINER_NAME" \
                --newrk="$network_nae"\
                -v "${RESULTS_DIR_HOST}:/app/rsul"\
              "${lods_nv_vas[@]}"\    
                "$LOADTEST_IMAGE_TAG"   Assul s CMD fleDocke"f$le.l{adtest Runs She bLnchmarkS_DIR}/server_${test_name}.log"

            exit_cod =$?
           lof [ $Sxit_coda -re 0 ]; then
                log "ERROR: Lordv wtictntaineh $ailed w{th erat code_$exlt_codt."
               _e}g("Loadcustelog{u"
                dockoraecgsn"$LOADTEST_CtNTAINER_NAME" || taun    docker-compose -f docker-compose.yml down --remove-orphans &>/dev/null || true
              dc#eO-t onollkec-py resoltm even ondfcikurrcifptheckexiotpose-valkey-cluster.yml down --remove-orphans &>/dev/null || true
             #dockr cp"${LOADTEST_CONTANE_NAME}:/app/r[lts/${t"st_ed}.js_l"i"$results_f_le_name" > /dev/null 2>&1 || true
            plee        if [[ "$use_cluster" == "true" ]]; then
                log " oadte  "cotarettd succnssfully for $ ese_dd."
                # Results shiuld beCdusecelyr coRESULTS_DIR_HOST nue tt voline mours
                .f[-f "$rsults_file_n" ]; then
                     o c"Rcpultsosovedrso $-eeuld-_file_name"cluster.yml up -d
                 l  
#i                  log "WARNING: R longerffutr$results_f  i_nani toi fzuedate loadte."
                fi
            fi

            # Clea   p eoadtpst15aer
         ker r "$LOADTEST_CONTAINER_NAME" > /dv/ull 2>&1 || ru
            export USE_REDIS_CLUSTER=true
            log "--- T st eiishd:$es_d---"
             lee  5 # Cooldown pdrcodrbecwmep oests
        de e
-   done

    # --- Sf pdSrrvercano Databassef.r mhls uter -d r ---dis
    log "Stoppi g  e v r contxiner..."
    docorr stoE "$SERVER_CONTAINER_NAME" > /dev/nu_l 2>&1
    dockRr rE "$SERVER_CONTAINER_NAME" > /dDv/Iull 2>&1

    log "SCoppLSg databaTeEcont=inar(s)lfsr $rae_lter_typ..."
    ocker-compose -f "$CURRENT_COMPOSE_FILE"dw -v --remov-rphas >/dv/ull 2>&1
    C RRENT_COMPOSE_FILE="" # Re  f nxt loopitrato

    log "===Finihd esateimitr:$rate_imtr_ype ==="
    leep 10 #Cooldwn eiobeweenrat limter type

done

# -- eFif lrClean_p ---
# cietnup_coneartery #pS" ==  be*mostky ]l;a  tld, but run just inas
        if [[ "$use_cluster" == "true" ]]; then
log "       lo suite finished."
logg" "Starstang  torVd yCs ${RESULTS_DIR_HOST}"
ter containers..."
# --  Gerera-s Rfpocme(Oltyclal) ---ster.yml up -d
# if [  f "scripts/  # Waie-bit lo.nh" ];echsn
#    tooi "Generaitiapor..."
#    s./le15pt/genat-rt.h "$RESULTS_DIR_HOST"
#fi

exi0            export USE_VALKEY_CLUSTER=true
        else
            log "Starting standalone Valkey container..."
            docker-compose -f docker-compose.yml up -d valkey
            export USE_VALKEY_CLUSTER=false
        fi
    fi

    # Wait for Redis/Valkey to be ready
    log "Waiting for database container..."
    sleep 10 # Increased wait time

    # Set environment variables for server
    export MODE=${rate_limiter_type} # Pass the full mode like 'ioredis'
    
    # Cluster flags are already set in the conditional logic above
    # Set connection details
    export REDIS_HOST=localhost
    export REDIS_PORT=6379 # Default Redis port
    export VALKEY_HOST=localhost
    export VALKEY_PORT=8080 # Valkey port from docker-compose.yml
    
    # Set cluster connection details if using cluster mode
    if [[ "$use_cluster" == "true" ]]; then
        if [[ "$rate_limiter_type" == *"redis"* ]]; then
            # Redis cluster uses ports 6371-6376
            export REDIS_CLUSTER_NODES="localhost:6371,localhost:6372,localhost:6373,localhost:6374,localhost:6375,localhost:6376"
        elif [[ "$rate_limiter_type" == *"valkey"* ]]; then
            # Valkey cluster uses ports 8081-8086
            export VALKEY_CLUSTER_NODES="localhost:8081,localhost:8082,localhost:8083,localhost:8084,localhost:8085,localhost:8086"
        fi
    fi

    # Make sure TypeScript files are compiled
    log "Compiling TypeScript files..."
    npm run build > /dev/null 2>&1
    
    # Start the server using compiled JavaScript
    log "Starting Node.js server process..."
    node dist/server/index.js > "$log_file" 2>&1 &
    SERVER_PID=$!

    log "Server process started with PID $SERVER_PID"

    # Wait for the server to be ready
    local max_retries=15 # Increased retries
    local retry=0
    local server_ready=false

    while [ $retry -lt $max_retries ]; do
        # Assuming server runs on port 3000 by default from config
        if curl -s http://localhost:3000/health | grep -q "ok"; then
            server_ready=true
            break
        fi
        log "Waiting for server to be ready... attempt ($((retry + 1))/$max_retries)"
        sleep 3 # Increased sleep
        retry=$((retry + 1))
    done

    if [ "$server_ready" = false ]; then
        log "ERROR: Server failed to start within expected time. Check $log_file"
        kill -9 $SERVER_PID 2>/dev/null || true
        # Attempt to stop containers as well
        if [[ "$rate_limiter_type" == *"redis"* ]]; then
            docker-compose -f docker-compose.yml stop redis
        elif [[ "$rate_limiter_type" == *"valkey"* ]]; then
            docker-compose -f docker-compose.yml stop valkey
        fi
        return 1
    fi

    log "Server is ready"
    return 0
}

# Function to stop the server
stop_server() {
    log "Stopping server process..."
    if [ ! -z "$SERVER_PID" ]; then
        kill -15 $SERVER_PID 2>/dev/null || true
        sleep 2
        kill -9 $SERVER_PID 2>/dev/null || true
        SERVER_PID=""
    fi
    log "Stopping Docker containers..."
    # Stop relevant containers based on the last run type (this might need refinement)
    docker-compose -f docker-compose.yml down --remove-orphans
    log "Server and containers stopped"
}

# Function to run a single benchmark
run_benchmark() {
    local rate_limiter_input=$1
    local request_type=$2
    local concurrency=$3
    
    # Parse rate limiter type and cluster mode
    local use_cluster=false
    local rate_limiter_type=$rate_limiter_input
    
    if [[ "$rate_limiter_input" == *":cluster" ]]; then
        rate_limiter_type=${rate_limiter_input%:cluster}
        use_cluster=true
    fi

    local test_name="${rate_limiter_type}"
    if [[ "$use_cluster" == "true" ]]; then
        test_name="${test_name}_cluster"
    fi
    
    test_name="${test_name}_${request_type}_c${concurrency}"
    local results_file="${RESULTS_DIR}/${test_name}.json" # Save JSON here
    local log_file="${RESULTS_DIR}/${test_name}.log" # Save stdout/stderr here

    log "Running benchmark: ${test_name}"

    # Environment variables for the benchmark loadtest script
    export TARGET_HOST=localhost
    export TARGET_PORT=3000 # Assuming server runs on 3000
    export REQUEST_TYPE=$request_type
    export CONCURRENCY=$concurrency
    export DURATION=$duration # Use the script's duration variable
    export MODE=$rate_limiter_type # Pass the mode being tested
    export RUN_ID=$TIMESTAMP
    export RESULTS_DIR=$RESULTS_DIR # Pass results dir for saving output
    export RESULT_FILE=$results_file # Explicitly pass the target JSON file path
    export USE_CLUSTER=$use_cluster # Pass cluster flag to benchmark tool

    # Run the benchmark using the compiled JavaScript
    # Using the more comprehensive benchmark/autocannon.js with resource monitoring
    node dist/benchmark/autocannon.js > "$log_file" 2>&1

    # Check if benchmark completed successfully
    if [ $? -ne 0 ]; then
        log "ERROR: Benchmark ${test_name} failed. Check $log_file."
        # Optionally check if the results file was created anyway
        if [ ! -f "$results_file" ]; then
           log "WARNING: Results file ${results_file} not found."
        fi
    else
        log "Benchmark ${test_name} completed."
        if [ ! -f "$results_file" ]; then
           log "WARNING: Benchmark process succeeded but results file ${results_file} not found. Check loadtest script output in $log_file."
        fi
    fi

    # Let the system stabilize before the next benchmark
    sleep 5
}

# Trap SIGINT and SIGTERM to ensure cleanup
trap "log 'Caught signal, stopping server...'; stop_server; exit 1" SIGINT SIGTERM

# Process each rate limiter type
for rate_limiter_type in "${rate_limiter_types[@]}"; do
    log "=== Testing rate limiter: $rate_limiter_type ==="

    # Start the server with this rate limiter
    start_server "$rate_limiter_type"

    if [ $? -ne 0 ]; then
        log "ERROR: Failed to start server with $rate_limiter_type, skipping this rate limiter"
        continue # Skip to the next rate limiter type
    fi

    # Run benchmarks for each request type and concurrency level
    for request_type in "${request_types[@]}"; do
        for concurrency in "${concurrency_levels[@]}"; do
            run_benchmark "$rate_limiter_type" "$request_type" "$concurrency"
        done
    done

    # Stop the server after testing this rate limiter type
    stop_server

    log "Completed all tests for $rate_limiter_type"
    sleep 5 # Pause before starting the next type
done

# Generate a summary report
log "Generating summary report..."

echo "## Test Results Summary" >> "$README_FILE"
echo "" >> "$README_FILE"
echo "| Rate Limiter | Request Type | Concurrency | Requests/sec | Avg Response Time (ms) | P95 Response Time (ms) | Success Rate (%) | Rate Limited (%) |" >> "$README_FILE"
echo "| ------------ | ------------ | ----------- | ------------ | ---------------------- | ---------------------- | ---------------- | ---------------- |" >> "$README_FILE"

# Find and process all JSON result files
shopt -s nullglob # Prevent loop from running if no files match
for result_file in "$RESULTS_DIR"/*.json; do
    # Skip if file is empty or not valid JSON
    if [ ! -s "$result_file" ] || ! jq . "$result_file" > /dev/null 2>&1; then
        log "WARNING: Skipping invalid or empty results file: $result_file"
        continue
    fi

    # Extract data using jq - check if keys exist before accessing
    rate_limiter=$(jq -r '.testConfig.mode // "N/A"' "$result_file")
    request_type=$(jq -r '.testConfig.requestType // "N/A"' "$result_file")
    concurrency=$(jq -r '.testConfig.concurrency // "N/A"' "$result_file")
    rps=$(jq -r '.summary.requestsPerSecond // 0' "$result_file")
    avg_resp=$(jq -r '.responseTimes.avg // 0' "$result_file")
    p95_resp=$(jq -r '.responseTimes.p95 // 0' "$result_file")
    success_rate=$(jq -r '.summary.successRate // 0' "$result_file")
    limited_rate=$(jq -r '.summary.rateLimitedRate // 0' "$result_file") # Added rate limited rate

    # Format the numbers safely
    rps=$(printf "%.2f" "$rps" 2>/dev/null || echo "N/A")
    avg_resp=$(printf "%.2f" "$avg_resp" 2>/dev/null || echo "N/A")
    p95_resp=$(printf "%.2f" "$p95_resp" 2>/dev/null || echo "N/A")
    success_rate=$(printf "%.2f" "$success_rate" 2>/dev/null || echo "N/A")
    limited_rate=$(printf "%.2f" "$limited_rate" 2>/dev/null || echo "N/A") # Format rate limited rate

    # Add to the report
    echo "| $rate_limiter | $request_type | $concurrency | $rps | $avg_resp | $p95_resp | $success_rate | $limited_rate |" >> "$README_FILE"
done
shopt -u nullglob # Restore default glob behavior

# Add charts section (placeholder for now)
echo "" >> "$README_FILE"
echo "## Performance Charts" >> "$README_FILE"
echo "" >> "$README_FILE"
echo "Charts can be generated separately using the JSON data files in this directory." >> "$README_FILE"

log "Benchmark suite completed successfully!"
log "Results saved to: $RESULTS_DIR"
log "Summary report: $README_FILE"

echo "Benchmark suite completed successfully!"
echo "Results saved to: $RESULTS_DIR"
echo "Summary report: $README_FILE"

exit 0
