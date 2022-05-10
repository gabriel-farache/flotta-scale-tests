#!/bin/bash

usage()
{
cat << EOF
Usage: $0 OPTIONS

This script runs test plan for project-flotta using jmeter for testing flotta-operator.
OPTIONS:
   -c      Max concurrent reconcilers (default: 3)
   -d      Total of edge devices
   -e      Number of operator's replicas (default: 1)
   -f      HTTP server port (default: 80)
   -g      HTTP server address (as exposed via route or ingress)
   -h      Show this message
   -i      Number of iterations
   -j      Jmeter home directory
   -k      K8s bearer token for accessing OCP API server
   -l      Log level (default: error)
   -m      Run must-gather to collect logs (default: false)
   -n      Test run ID
   -o      Edge deployment updates concurrency (default: 5)
   -p      Total of edge workloads per device
   -q      Number of namespaces (default: 10). Requires hacked version of flotta-operator and specific test plan.
   -r      Ramp-up time in seconds to create all edge devices
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
while getopts "c:d:e:f:g:h:i:j:k:l:m:n:o:p:q:r:s:t:u:w:v" option; do
    case "${option}"
    in
        c) MAX_CONCURRENT_RECONCILES=${OPTARG};;
        d) EDGE_DEVICES_COUNT=${OPTARG};;
        e) REPLICAS=${OPTARG};;
        f) HTTP_SERVER_PORT=${OPTARG};;
        g) HTTP_SERVER=${OPTARG};;
        i) ITERATIONS=${OPTARG};;
        j) JMETER_HOME=${OPTARG};;
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

if [[ -z $JMETER_HOME ]]; then
    JMETER_HOME=/home/test/apache-jmeter-5.4.1
    echo "INFO: Jmeter home directory is not provided. Using default value: $JMETER_HOME"
    if [ ! -d "$JMETER_HOME" ]; then
        echo "ERROR: Jmeter home directory $JMETER_HOME does not exist"
        exit 1
    fi
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
echo "Jmeter home directory: ${JMETER_HOME}"
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

echo "INFO: Running test located in ${SCRIPT_DIR}"
JVM_ARGS="-Xms4g -Xmx64g -Xss250k -XX:MaxMetaspaceSize=1g" $JMETER_HOME/bin/jmeter.sh -n -l $test_dir/results.csv \
    -f -e -o $test_dir/results/ -t $TEST_PLAN \
    -JEDGE_DEVICES_COUNT=$EDGE_DEVICES_COUNT \
    -JEDGE_DEPLOYMENTS_PER_DEVICE=$EDGE_DEPLOYMENTS_PER_DEVICE \
    -JRAMP_UP_TIME=$RAMP_UP_TIME \
    -JITERATIONS=$ITERATIONS \
    -JOCP_API_SERVER=$OCP_API_SERVER \
    -JOCP_API_PORT=$OCP_API_PORT \
    -JK8S_BEARER_TOKEN=$K8S_BEARER_TOKEN \
    -JHTTP_SERVER=$HTTP_SERVER \
    -JHTTP_SERVER_PORT=$HTTP_SERVER_PORT \
    -JTEST_DIR=$test_dir \
    -JSCRIPTS_DIR=$SCRIPT_DIR \
    -JCERTS_FOLDER=$CERTS_FOLDER \
    -JREGISTRATION_FOLDER="${SCRIPT_DIR}/test-run-${TEST_ID}/logs/registration" \
    -JGET_UPDATES_FOLDER="${SCRIPT_DIR}/test-run-${TEST_ID}/logs/get_updates" \
    -JHEARTBEAT_FOLDER="${SCRIPT_DIR}/test-run-${TEST_ID}/logs/heartbeat" \
    -JENROL_FOLDER="${SCRIPT_DIR}/test-run-${TEST_ID}/logs/enrol" \
    -JNAMESPACES_COUNT=$NAMESPACES_COUNT|& tee -a $test_dir/summary.txt
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
  if [[ $p =~ "pod/flotta-operator-controller-manager".* ]]; then
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
echo "INFO: Patching flotta-operator"

kubectl patch cm -n flotta flotta-operator-manager-config --type merge --patch '
{ "data": {
    "LOG_LEVEL": "'$LOG_LEVEL'",
    "OBC_AUTO_CREATE": "false",
     "MAX_CONCURRENT_RECONCILES": "'$MAX_CONCURRENT_RECONCILES'",
     "EDGEWORKLOAD_CONCURRENCY": "'$EDGEWORKLOAD_CONCURRENCY'",
     "NAMESPACES_COUNT": "'$NAMESPACES_COUNT'"}
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

kubectl scale --replicas=0 deployment flotta-operator-controller-manager -n flotta
kubectl patch deployment flotta-operator-controller-manager -n flotta -p '
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

if [[ -n $EXPOSE_PPROF ]]; then
  kubectl patch deployment flotta-operator-controller-manager -n flotta -p '
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

  kubectl patch service flotta-operator-controller-manager -n flotta -p '
  { "spec": {
      "ports": [
          {
              "name": "pprof",
              "port": 6060,
              "protocol": "TCP",
              "targetPort": "pprof"
          }
      ]
  }
  }'

  kubectl patch deployment -n flotta flotta-operator-controller-manager -p '
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
fi

kubectl patch service flotta-operator-controller-manager -n flotta --type='json' -p "[{\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},{\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${HTTP_SERVER_PORT}}]"

kubectl scale --replicas=$REPLICAS deployment flotta-operator-controller-manager -n flotta
kubectl wait --for=condition=available -n flotta deployment.apps/flotta-operator-controller-manager

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
