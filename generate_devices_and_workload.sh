#!/bin/bash 
NB_DEVICES=$1
SCRIPT=$(readlink -f "$0")
export SCRIPT_DIR=$(dirname "$SCRIPT")
export CERTS_FOLDER=${SCRIPT_DIR}/certs
export REGISTRATION_FOLDER=${SCRIPT_DIR}/logs/registration
export ENROL_FOLDER=${SCRIPT_DIR}/logs/enrol
rm -rf ${SCRIPT_DIR}/logs $CERTS_FOLDER
mkdir -p $REGISTRATION_FOLDER
mkdir -p $ENROL_FOLDER
mkdir -p $CERTS_FOLDER
export HTTP_SERVER=127.0.0.1
export HTTP_SERVER_PORT=8043
for p in $(kubectl -n flotta-test get edgedevices --no-headers | awk '{print $1}'); do kubectl -n flotta-test patch edgedevices $p -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null; done

kubectl delete namespace flotta-test
kubectl create namespace flotta-test

BASE_SERIAL=$(uuidgen)
for i in $(seq 1 $NB_DEVICES); do 
  DEVICE_ID=$(uuidgen)
  PAYLOAD='{
    "content": {
        "target_namespace": "flotta-test",
        "features": {
            "hardware": {
                "cpu": {
                    "architecture": "x86_64",
                    "flags": [],
                    "model_name": "Intel(R) Core(TM) i7-6820HQ CPU @ 2.70GHz"
                },
                "hostname": "fedora",
                "system_vendor": {
                    "manufacturer": "LENOVO",
                    "product_name": "azerty'$(expr $i % 2)'",
                    "serial_number": "'${BASE_SERIAL}_${i}'"
                }
            },
            "os_image_id": "unknown"
            
          }
      },
    "directive": "enrolment",
    "message_id": "${__UUID()}",
    "sent": "2021-11-21T14:45:25.271+02:00",
    "type": "data",
    "version": 1
    
  }'
  DEVICE_ID=default CERTS_FOLDER=$CERTS_FOLDER sh scripts/generate_certs.sh >> $CERTS_FOLDER/logs.out 2>> $CERTS_FOLDER/logs.err

  DEVICE_ID=$DEVICE_ID PAYLOAD=$PAYLOAD sh scripts/enrol_device.sh  >> $ENROL_FOLDER/logs.out 2>> $ENROL_FOLDER/logs.err


  ## Registration

  PAYLOAD='{
    "content": {
            "hardware": {
                "cpu": {
                    "architecture": "x86_64",
                    "flags": [],
                    "model_name": "Intel(R) Core(TM) i7-6820HQ CPU @ 2.70GHz"
                },
                "hostname": "fedora",
                "system_vendor": {
                    "manufacturer": "LENOVO",
                    "product_name": "azerty'$(expr $i % 2)'",
                    "serial_number": "'${BASE_SERIAL}_${i}'"
                }
            },
            "os_image_id": "unknown"
      },
    "directive": "registration",
    "message_id": "'$(uuidgen)'",
    "sent": "2021-11-21T14:45:25.271+02:00",
    "type": "data",
    "version": 1
    
  }'

  DEVICE_ID=$DEVICE_ID PAYLOAD=$PAYLOAD sh scripts/register_device.sh >> $REGISTRATION_FOLDER/logs.out 2>> $REGISTRATION_FOLDER/logs.err
done
SELECTOR_ALL="device.system-manufacturer: lenovo"
SELECTOR_ODD="device.system-product: azerty1"
SELECTOR_PAIR="device.system-product: azerty0"
SELECTOR_UNIQUE="device.system-serial: ${BASE_SERIAL}_1"

# A pretend Python dictionary with bash 3 
WORKLOADS_SELECTOR=( "all:$SELECTOR_ALL"
        "odd:$SELECTOR_ODD"
        "pair:$SELECTOR_PAIR"
        "unique:$SELECTOR_UNIQUE" )

for WORKLOAD_SELECTOR in "${WORKLOADS_SELECTOR[@]}" ; do
    SELECTOR_NAME=${WORKLOAD_SELECTOR%%:*}
    SELECTOR=${WORKLOAD_SELECTOR#*:}
    printf "%s apply %s.\n" "$SELECTOR_NAME" "$SELECTOR"
    WORKLOAD="
apiVersion: management.project-flotta.io/v1alpha1
kind: EdgeWorkload
metadata:
  name: edgeworkload-sample-${SELECTOR_NAME}
  namespace: flotta-test
spec:
  deviceSelector:
    matchLabels:
      $SELECTOR
  data:
    paths:
      - source: .
        target: nginx
  type: pod
  pod:
    spec:
      containers:
        - name: nginx
          image: docker.io/nginx:1.14.2
          ports:
            - containerPort: 80
              hostPort: 9090
"
    echo "$WORKLOAD" | kubectl apply -f - > /dev/null
done
echo "=================="
if [[ $NB_DEVICES -lt 2 ]]; then
  echo "!!! Warn: Amount of device the create is $NB_DEVICES which is lower than 2, tests checking the expected amount of devices matching a workload will fail"
fi
echo -n "Checking if workloads are correctly depoloyed on devices..."

NB_PAIR_EXPTECTED=$(expr $NB_DEVICES / 2)
NB_ODD_EXPTECTED=$(expr $NB_DEVICES - $NB_PAIR_EXPTECTED)
NB_ALL_DEVICES=0
NB_ODD_DEVICES=0
NB_PAIR_DEVICES=0
NB_UNIQUE_DEVICES=0

for DEVICE in $(kubectl -n flotta-test get edgedevice --no-headers | awk '{print $1}')
do
  kubectl -n flotta-test get edgedevices $DEVICE -o yaml | grep "name: edgeworkload-sample-all" > /dev/null
  if [[ $? -ne 0 ]]; then
    echo $'\n'"Error: $DEVICE should have workload edgeworkload-sample-all but has not" 
  else
    let "NB_ALL_DEVICES++"
  fi
done
if [[ $NB_ALL_DEVICES -ne $NB_DEVICES ]]; then
  echo $'\n'"Error: edgeworkload-sample-all is not apply to all devices created: should be $NB_DEVICES get $NB_ALL_DEVICES"
fi

for ODD_DEVICE in $(kubectl -n flotta-test get edgedevice -l device.system-product=azerty1 --no-headers | awk '{print $1}'); do
  kubectl -n flotta-test get edgedevices $ODD_DEVICE -o yaml | grep "name: edgeworkload-sample-odd" > /dev/null
  if [[ $? -ne 0 ]]; then
    echo $'\n'"Error: $ODD_DEVICE should have workload edgeworkload-sample-odd but has not" 
  else
    let "NB_ODD_DEVICES++"
  fi
done
if [[ $NB_ODD_DEVICES -ne $NB_ODD_EXPTECTED ]]; then
  echo $'\n'"Error: edgeworkload-sample-odd is not apply to all devices created: should be $NB_ODD_EXPTECTED get $NB_ODD_DEVICES"
fi

for PAIR_DEVICE in $(kubectl -n flotta-test get edgedevice -l device.system-product=azerty0 --no-headers | awk '{print $1}'); do
  kubectl -n flotta-test get edgedevices $PAIR_DEVICE -o yaml | grep "name: edgeworkload-sample-pair" > /dev/null
  if [[ $? -ne 0 ]]; then
    echo $'\n'"Error: $PAIR_DEVICE should have workload edgeworkload-sample-pair but has not" 
  else
    let "NB_PAIR_DEVICES++"
  fi
done
if [[ $NB_PAIR_DEVICES -ne $NB_PAIR_EXPTECTED ]]; then
  echo $'\n'"Error: edgeworkload-sample-pair is not apply to all devices created: should be $NB_PAIR_EXPTECTED get $NB_PAIR_DEVICES"
fi

for UNIQUE_DEVICE in $(kubectl -n flotta-test get edgedevice -l device.system-serial=${BASE_SERIAL}_1 --no-headers | awk '{print $1}'); do
  kubectl -n flotta-test get edgedevices $UNIQUE_DEVICE -o yaml | grep "name: edgeworkload-sample-unique" > /dev/null
  if [[ $? -ne 0 ]]; then
    echo $'\n'"Error: $UNIQUE_DEVICE should have workload edgeworkload-sample-unique but has not" 
  else
    let "NB_UNIQUE_DEVICES++"
  fi
done
if [[ $NB_UNIQUE_DEVICES -ne 1 ]]; then
  echo "Error: edgeworkload-sample-unique is not apply to all devices created: should be 1 get $NB_UNIQUE_DEVICES"
fi

for PAIR_DEVICE in $(kubectl -n flotta-test get edgedevice -l device.system-product=azerty0 --no-headers | awk '{print $1}'); do
  kubectl -n flotta-test patch edgedevices $PAIR_DEVICE -p '{"metadata":{"labels":{"device.system-product":"azerty"}}}' --type=merge >/dev/null
  kubectl -n flotta-test get edgedevices $PAIR_DEVICE -o yaml | grep "name: edgeworkload-sample-pair" > /dev/null
  if [[ $? -eq 0 ]]; then
    echo $'\n'"Error: $PAIR_DEVICE should NOT have workload edgeworkload-sample-pair anymore as the label was changed and does not match the worload selector anymore" 
  fi
done

for PAIR_DEVICE in $(kubectl -n flotta-test get edgedevice -l device.system-product=azerty --no-headers | awk '{print $1}'); do
  kubectl -n flotta-test patch edgedevices $PAIR_DEVICE -p '{"metadata":{"labels":{"device.system-product":"azerty0"}}}' --type=merge >/dev/null
  kubectl -n flotta-test get edgedevices $PAIR_DEVICE -o yaml | grep "name: edgeworkload-sample-pair" > /dev/null
  if [[ $? -ne 0 ]]; then
    echo $'\n'"Error: $PAIR_DEVICE should  have workload edgeworkload-sample-pair AGAIN as the label matching the worload selector has been added" 
  fi
done

echo "Done"