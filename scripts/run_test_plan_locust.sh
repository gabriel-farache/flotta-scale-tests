#!/bin/bash

usage()
{
cat << EOF
Usage: $0 OPTIONS

This script runs test plan for project-flotta using locuset for testing flotta-operator.
OPTIONS:
   -c      Max concurrent reconcilers (default: 3)
   -d      Total of edge devices
   -e      Number of operator's replicas (default: 1)
   -f      HTTP server port (default: 80)
   -g      HTTP server address (as exposed via route or ingress)
   -h      Show this message
   -i      Number of iterations
   -k      K8s bearer token for accessing OCP API server
   -l      Log level (default: error)
   -m      Run must-gather to collect logs (default: false)
   -n      Test run ID
   -o      Edge deployment updates concurrency (default: 5)
   -p      Total of edge workloads per device
   -q      Number of namespaces (default: 10). Requires hacked version of flotta-operator and specific test plan.
   -r      Spawn rate of edge devices per second
   -s      Address of OCP API server
   -t      Test plan file
   -u      Expose pprof on port 6060 (default: false)
   -w      Address of OCP API port
   -v      Verbose
EOF
}

get_k8s_bearer_token()
{
secrets=$(kubectl get serviceaccount flotta-scale -o json | jq -r '.secrets[].name')
if [[ -z $secrets ]]; then
    echo "INFO: No secrets found for serviceaccount flotta-scale"
    return 1
fi

kubectl get secret $secrets -o json | jq -r '.items[] | select(.type == "kubernetes.io/service-account-token") | .data.token'| base64 -d
}

parse_args()
{
while getopts "c:d:e:f:g:h:i:x:k:l:m:n:o:p:q:r:s:t:u:w:v" option; do
    case "${option}"
    in
        c) MAX_CONCURRENT_RECONCILES=${OPTARG};;
        d) EDGE_DEVICES_COUNT=${OPTARG};;
        e) REPLICAS=${OPTARG};;
        f) HTTP_SERVER_PORT=${OPTARG};;
        g) HTTP_SERVER=${OPTARG};;
        i) ITERATIONS=${OPTARG};;
        k) K8S_BEARER_TOKEN=${OPTARG};;
        l) LOG_LEVEL=${OPTARG};;
        m) MUST_GATHER=${OPTARG};;
        n) TEST_ID=${OPTARG};;
        o) EDGEWORKLOAD_CONCURRENCY=${OPTARG};;
        p) EDGE_DEPLOYMENTS_PER_DEVICE=${OPTARG};;
        q) NAMESPACES_COUNT=${OPTARG};;
        r) RAMP_UP_TIME=${OPTARG};;
        s) OCP_API_SERVER=${OPTARG};;
        t) TEST_PLAN=${OPTARG};;
        v) VERBOSE=1;;
        u) EXPOSE_PPROF=1;;
        w) OCP_API_PORT=${OPTARG};;
        x) NB_WORKERS=${OPTARG};;
        h)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

if [[ -z $MAX_CONCURRENT_RECONCILES ]]; then
    MAX_CONCURRENT_RECONCILES=3
    echo "INFO: Max concurrent reconcilers not specified. Using default value: $MAX_CONCURRENT_RECONCILES"
fi

if [[ -z $REPLICAS ]]; then
    REPLICAS=1
    echo "INFO: Number of replicas not specified. Using default value: $REPLICAS"
fi

if [[ -z $NB_WORKERS ]]; then
    NB_WORKERS=10
    echo "INFO: Number of workers not specified. Using default value: $NB_WORKERS"
fi

if [[ -z $EDGEWORKLOAD_CONCURRENCY ]]; then
    EDGEWORKLOAD_CONCURRENCY=5
    echo "INFO: Edge deployment concurrency not specified. Using default value: $EDGEWORKLOAD_CONCURRENCY"
fi

if [[ -z $TEST_ID ]]; then
    echo "ERROR: Test ID is required"
    usage
    exit 1
fi

if [[ -z $EDGE_DEVICES_COUNT ]]; then
    echo "ERROR: Total of edge devices is required"
    usage
    exit 1
fi

if [[ -z $EDGE_DEPLOYMENTS_PER_DEVICE ]]; then
    echo "ERROR: edge workloads per device is required"
    usage
    exit 1
fi

if [[ -z $RAMP_UP_TIME ]]; then
    echo "ERROR: Ramp-up time is required"
    usage
    exit 1
fi

if [[ -z $ITERATIONS ]]; then
    echo "ERROR: Iterations is required"
    usage
    exit 1
fi

if [[ -z $LOG_LEVEL ]]; then
    LOG_LEVEL="error"
    echo "INFO: Log level not specified. Using default value: $LOG_LEVEL"
fi

if [[ -z $OCP_API_SERVER ]]; then
    echo "ERROR: OCP API server is required"
    usage
    exit 1
fi

if [[ -z $OCP_API_PORT ]]; then
    echo "INFO: OCP API PORT not provided, default to 6443"
    OCP_API_PORT=6443
fi

if [[ -z $OPERATOR_REPLICAS ]]; then
    echo "INFO: OPERATOR_REPLICAS not provided, default to 1"
    OPERATOR_REPLICAS=1
fi


if [[ -z $K8S_BEARER_TOKEN ]]; then
    echo "INFO: K8s bearer token is not provided. Trying to set it from cluster for flotta-scale service account"
    K8S_BEARER_TOKEN=$( get_k8s_bearer_token )
    if [ "$?" == "1" ]; then
      # Create a service account
      kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flotta-scale
EOF
      # Attach the service account to a privileged role
      kubectl create clusterrolebinding flotta-scale-cluster-admin --clusterrole=cluster-admin --serviceaccount=default:flotta-scale
      K8S_BEARER_TOKEN=$( get_k8s_bearer_token )
      if [ "$K8S_BEARER_TOKEN" == "" ]; then
        echo "ERROR: Failed to create token for flotta-scale service account"
        exit 1
      fi
    fi
fi

if [[ -z $HTTP_SERVER ]]; then
    echo "ERROR: HTTP server is required"
    usage
    exit 1
fi

if [[ -z $HTTP_SERVER_PORT ]]; then
    echo "HTTP port is not specified. Using default value: 3143"
    HTTP_SERVER_PORT=3143
fi

if [[ $HTTP_SERVER_PORT -lt 30000 ]]  || [[ $HTTP_SERVER_PORT -gt 32767 ]]; then
    echo "HTTP_SERVER_PORT shall be between 30000 - 32767 to allow NodePort service, given: $HTTP_SERVER_PORT"
    exit -1
fi

if [[ ! -f $TEST_PLAN ]]; then
    echo "ERROR: Test plan is required"
    usage
    exit 1
fi

if [[ -z $NAMESPACES_COUNT ]]; then
    RUN_WITHOUT_NAMESPACES=1
    NAMESPACES_COUNT="0"
    echo "INFO: Namespaces not specified. Using default value: $NAMESPACES_COUNT"
fi

if [[ -n $VERBOSE ]]; then
    set -xv
fi

export test_dir="$(pwd)/test-run-${TEST_ID}"
if [ -d "$test_dir" ]; then
    echo "ERROR: Test directory $test_dir already exists"
    exit 1
fi
}

log_run_details()
{
START_TIME=$SECONDS
echo "INFO: Running test-plan ${TEST_PLAN} as test run ${TEST_ID} with ${EDGE_DEVICES_COUNT} edge devices"
mkdir -p $test_dir/results
touch $test_dir/summary.txt
{
echo "Run by: ${0} with options:"
echo "Target folder: $test_dir"
echo "Test ID: ${TEST_ID}"
echo "Test plan: ${TEST_PLAN}"
echo "Total of edge devices: ${EDGE_DEVICES_COUNT}"
echo "edge workloads per device: ${EDGE_DEPLOYMENTS_PER_DEVICE}"
echo "Ramp-up time: ${RAMP_UP_TIME}"
echo "Iterations: ${ITERATIONS}"
echo "OCP API server: ${OCP_API_SERVER}"
echo "OCP API port: ${OCP_API_PORT}"
echo "K8s bearer token: ${K8S_BEARER_TOKEN}"
echo "HTTP server: ${HTTP_SERVER}"
echo "HTTP port: ${HTTP_SERVER_PORT}"
echo "Replicas: ${REPLICAS}"
echo "Max concurrent reconcilers: ${MAX_CONCURRENT_RECONCILES}"
echo "----------------------------------------------------"
} >> $test_dir/summary.txt

cp $TEST_PLAN $test_dir/
edgedevices=$(kubectl get edgedevices --all-namespaces | wc -l)
edgeworkload=$(kubectl get edgeworkloads --all-namespaces | wc -l)
echo "Before test: There are $edgedevices edge devices and $edgeworkload edge workloads" >> $test_dir/summary.txt
}

run_test()
{
SCRIPT=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT")
NB_TASKS=1
TASK_LIMIT=$(($NB_TASKS * $EDGE_DEVICES_COUNT))
USER_PER_WORKER=$((${EDGE_DEVICES_COUNT} / $NB_WORKERS))
TASK_LIMIT_PER_WORKER=$((${TASK_LIMIT} / $NB_WORKERS))
echo "INFO: Running test located in ${SCRIPT_DIR}"
echo "EDGE_DEVICES_COUNT=$EDGE_DEVICES_COUNT \
    EDGE_DEPLOYMENTS_PER_DEVICE=$EDGE_DEPLOYMENTS_PER_DEVICE \
    RAMP_UP_TIME=$RAMP_UP_TIME \
    TEST_ITERATIONS=$ITERATIONS \
    OCP_API_SERVER=$OCP_API_SERVER \
    OCP_API_PORT=$OCP_API_PORT \
    K8S_BEARER_TOKEN=$K8S_BEARER_TOKEN \
    HTTPS_SERVER=$HTTP_SERVER \
    HTTPS_SERVER_PORT=$HTTP_SERVER_PORT \
    CERTS_FOLDER=$CERTS_FOLDER \
    TARGET_NAMESPACE="default" \
    LOCUST_LOCUSTFILE=${TEST_PLAN} locust --headless --only-summary --user ${EDGE_DEVICES_COUNT} --spawn-rate ${RAMP_UP_TIME} \
    --csv=${test_dir}/locust_output --host localhost --logfile=${test_dir}/locust.log  \
    --html=${test_dir}/locust.html -i ${TASK_LIMIT_PER_WORKER} --expect-workers=${NB_WORKERS} --master &
"
EDGE_DEVICES_COUNT=$EDGE_DEVICES_COUNT \
    EDGE_DEPLOYMENTS_PER_DEVICE=$EDGE_DEPLOYMENTS_PER_DEVICE \
    RAMP_UP_TIME=$RAMP_UP_TIME \
    TEST_ITERATIONS=$ITERATIONS \
    OCP_API_SERVER=$OCP_API_SERVER \
    OCP_API_PORT=$OCP_API_PORT \
    K8S_BEARER_TOKEN=$K8S_BEARER_TOKEN \
    HTTPS_SERVER=$HTTP_SERVER \
    HTTPS_SERVER_PORT=$HTTP_SERVER_PORT \
    CERTS_FOLDER=$CERTS_FOLDER \
    TARGET_NAMESPACE="default" \
    LOCUST_LOCUSTFILE=${TEST_PLAN} locust --headless --only-summary --user ${EDGE_DEVICES_COUNT} --spawn-rate ${RAMP_UP_TIME}  \
    --csv=${test_dir}/locust_output --host localhost --logfile=${test_dir}/locust.log  \
    --html=${test_dir}/locust.html -i ${TASK_LIMIT_PER_WORKER} --expect-workers=${NB_WORKERS} --master &
echo "Creating ${NB_WORKERS} workers based on:"
echo "EDGE_DEVICES_COUNT=$EDGE_DEVICES_COUNT \
    EDGE_DEPLOYMENTS_PER_DEVICE=$EDGE_DEPLOYMENTS_PER_DEVICE \
    RAMP_UP_TIME=$RAMP_UP_TIME \
    TEST_ITERATIONS=$ITERATIONS \
    OCP_API_SERVER=$OCP_API_SERVER \
    OCP_API_PORT=$OCP_API_PORT \
    K8S_BEARER_TOKEN=$K8S_BEARER_TOKEN \
    HTTPS_SERVER=$HTTP_SERVER \
    HTTPS_SERVER_PORT=$HTTP_SERVER_PORT \
    CERTS_FOLDER=$CERTS_FOLDER \
    TARGET_NAMESPACE="default" \
    LOCUST_LOCUSTFILE=${TEST_PLAN} locust --headless \
    --csv=${test_dir}/locust_output --host localhost --only-summary --logfile=${test_dir}/locust.log -i ${TASK_LIMIT_PER_WORKER} \
    -u ${USER_PER_WORKER} --spawn-rate ${RAMP_UP_TIME} --html=${test_dir}/locust.html --worker &
"

for ((i=1; i <= NB_WORKERS; i++))
do
  EDGE_DEVICES_COUNT=$EDGE_DEVICES_COUNT \
    EDGE_DEPLOYMENTS_PER_DEVICE=$EDGE_DEPLOYMENTS_PER_DEVICE \
    RAMP_UP_TIME=$RAMP_UP_TIME \
    TEST_ITERATIONS=$ITERATIONS \
    OCP_API_SERVER=$OCP_API_SERVER \
    OCP_API_PORT=$OCP_API_PORT \
    K8S_BEARER_TOKEN=$K8S_BEARER_TOKEN \
    HTTPS_SERVER=$HTTP_SERVER \
    HTTPS_SERVER_PORT=$HTTP_SERVER_PORT \
    CERTS_FOLDER=$CERTS_FOLDER \
    TARGET_NAMESPACE="default" \
    LOCUST_LOCUSTFILE=${TEST_PLAN} locust --headless \
    --csv=${test_dir}/locust_output --host localhost --only-summary --logfile=${test_dir}/locust.log -i ${TASK_LIMIT_PER_WORKER} \
    -u ${USER_PER_WORKER} --spawn-rate ${RAMP_UP_TIME}  --html=${test_dir}/locust.html --worker &
done

sleep 30
cat ${test_dir}/locust.log | grep "Shutting down"
DONE=$?
while [ $DONE -ne 0 ]
do
  sleep 30
  cat ${test_dir}/locust.log | grep "Shutting down"
  DONE=$?
done

}

collect_results()
{
echo "INFO: Collecting results"
{
echo "----------------------------------------------------"
echo "After test:" >> $test_dir/summary.txt
} >> $test_dir/summary.txt

if [[ -z $RUN_WITHOUT_NAMESPACES ]]; then
    edgedevices=$(kubectl get edgedevices --all-namespaces | wc -l)
    edgeworkload=$(kubectl get edgeworkloads --all-namespaces | wc -l)
    echo "There are $edgedevices edge devices and $edgeworkload edge workloads" >> $test_dir/summary.txt
else
    for i in $(seq 1 $NAMESPACES_COUNT); do
        edgedevices=$(kubectl get edgedevices -n $i | wc -l)
        edgeworkload=$(kubectl get edgeworkloads -n $i | wc -l)
        echo "There are $edgedevices edge devices and $edgeworkload edge workloads in namespace $i" >> $test_dir/summary.txt
    done
fi

logs_dir=$test_dir/logs
mkdir -p $logs_dir

if [[ -n $MUST_GATHER ]]; then
  mkdir -p $logs_dir/must-gather
  oc adm must-gather --dest-dir=$logs_dir/must-gather 2>/dev/null 1>/dev/null
  tar --remove-files -cvzf $logs_dir/must-gather.tar.gz $logs_dir/must-gather 2>/dev/null 1>/dev/null
fi

# Collect additional logs
pods=$(kubectl get pod -n flotta -o name)
for p in $pods
do
  if [[ $p =~ "pod/flotta-controller-manager".* ]] || [[ $p =~ "pod/flotta-edge-api".* ]]; then
    pod_log=$logs_dir/${p#*/}.log
    kubectl logs -n flotta $p -c manager > $pod_log
    gzip $pod_log
  fi
done

gzip $test_dir/results.csv
ELAPSED_TIME=$(($SECONDS - $START_TIME))
echo "INFO: Test run completed in $((ELAPSED_TIME/60)) min $((ELAPSED_TIME%60)) sec" >> $test_dir/summary.txt
}

patch_flotta_operator()
{
echo "INFO: Patching flotta-manager-config"

kubectl patch cm -n flotta flotta-manager-config --type merge --patch '
{ "data": {
    "LOG_LEVEL": "'$LOG_LEVEL'",
    "OBC_AUTO_CREATE": "false",
     "MAX_CONCURRENT_RECONCILES": "'$MAX_CONCURRENT_RECONCILES'",
     "EDGEWORKLOAD_CONCURRENCY": "'$EDGEWORKLOAD_CONCURRENCY'",
     "NAMESPACES_COUNT": "'$NAMESPACES_COUNT'"}
}'
echo "INFO: Patching flotta-edge-api-config"
kubectl patch cm -n flotta flotta-edge-api-config --type merge --patch '
{ "data": {
    "LOG_LEVEL": "'$LOG_LEVEL'"}
}'

memory_per_10k_crs=300
memory_per_workload=$(( 256 + memory_per_10k_crs * ((EDGE_DEVICES_COUNT + EDGE_DEVICES_COUNT * EDGE_DEPLOYMENTS_PER_DEVICE) / 10000) ))
memory_with_spike=$(echo $memory_per_workload*1.25 | bc)
total_memory=${memory_with_spike%.*}Mi

# TODO: if total_cpu is bigger than 10000m, we need to increase the number of replicas
cpu_per_10k_crs=100
total_cpu=$(( 100 + cpu_per_10k_crs * EDGE_DEVICES_COUNT * EDGE_DEPLOYMENTS_PER_DEVICE / 10000 ))m

{
echo "Memory per 10k CRs: $memory_per_10k_crs"
echo "Total memory: $total_memory"
echo "Total CPU: $total_cpu"
echo "----------------------------------------------------"
} >> $test_dir/summary.txt

kubectl scale --replicas=0 deployment flotta-controller-manager -n flotta
kubectl scale --replicas=0 deployment flotta-edge-api -n flotta
kubectl patch deployment flotta-controller-manager -n flotta -p '
{ "spec": {
    "template": {
      "spec":
        { "containers":
          [{"name": "manager",
            "imagePullPolicy":"Always",
            "resources": {
              "limits": {
                "cpu":"'$total_cpu'",
                "memory":"'$total_memory'"
              }
            }
          }]
        }
      }
    }
}'
kubectl patch deployment flotta-edge-api -n flotta -p '
{ "spec": {
    "template": {
      "spec":
        { "containers":
          [{"name": "http",
            "imagePullPolicy":"Always",
            "resources": {
              "limits": {
                "cpu":"'$total_cpu'",
                "memory":"'$total_memory'"
              }
            }
          }]
        }
      }
    }
}'

kubectl patch service flotta-edge-api -n flotta --type='json' -p "[{\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"}]"

if [[ -n $EXPOSE_PPROF ]]; then
  kubectl patch deployment flotta-controller-manager -n flotta -p '
  { "spec": {
      "template": {
        "spec":
          { "containers":
            [{"name": "manager",
              "ports": [
                  {
                      "containerPort": 6060,
                      "name": "pprof",
                      "protocol": "TCP"
                  }
              ]
            }]
          }
        }
      }
  }'

  kubectl -n flotta expose deployment flotta-controller-manager --port=6060 --target-port=6060 --type=ClusterIP --name flotta-controller-manager-pprof-svc

  kubectl patch deployment -n flotta flotta-ontroller-manager -p '
   {
     "spec": {
       "template":{
         "metadata":{
           "annotations":{
             "pyroscope.io/scrape": "true",
             "pyroscope.io/application-name": "flotta-operator",
             "pyroscope.io/profile-cpu-enabled": "true",
             "pyroscope.io/profile-mem-enabled": "true",
             "pyroscope.io/port": "6060"
           }
         }
       }
     }
  }'
  kubectl patch service flotta-edge-api -n flotta --type='json' -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/2/nodePort\",\"value\":${HTTP_SERVER_PORT}}]"
else
  kubectl patch service flotta-edge-api -n flotta --type='json' -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/2/nodePort\",\"value\":${HTTP_SERVER_PORT}}]"
fi



kubectl scale --replicas=$REPLICAS deployment flotta-controller-manager -n flotta
kubectl scale --replicas=$REPLICAS deployment flotta-edge-api -n flotta
kubectl wait --for=condition=available -n flotta deployment.apps/flotta-controller-manager
kubectl wait --for=condition=available -n flotta deployment.apps/fflotta-edge-api

count=0
export CERTS_FOLDER="${test_dir}/certs"
DEVICE_ID='default'
DEVICE_ID=$DEVICE_ID sh generate_certs.sh 
echo "Waiting for HTTP server to be ready at $HTTP_SERVER"
until [[ count -gt 100 ]]
do
  curl \
    --cacert ${CERTS_FOLDER}/${DEVICE_ID}_ca.pem \
    --cert ${CERTS_FOLDER}/${DEVICE_ID}_cert.pem \
    --key ${CERTS_FOLDER}/${DEVICE_ID}_key.pem -v \
    -m 5 -s -i \
    https://${HTTP_SERVER}:${HTTP_SERVER_PORT} | grep 404 > /dev/null
  if [ "$?" == "1" ]; then
    echo -n "."
    count=$((count+1))
    sleep 5
  else
    echo $'\n'"HTTP server is ready"
    break
  fi
done

if [[ count -gt 100 ]]; then
  echo $'\n'"ERROR: HTTP server is not ready"
  exit 1
fi
}

log_pods_details()
{
{
echo "----------------------------------------------------"
kubectl get pods -n flotta -o wide
kubectl top pods -n flotta --use-protocol-buffers
} >> $test_dir/summary.txt
}



parse_args "$@"
log_run_details
sh setup.sh
patch_flotta_operator
log_pods_details
run_test
log_pods_details
collect_results
