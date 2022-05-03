#!/bin/bash

echo "${PAYLOAD}" |  envsubst > ${ENROL_FOLDER}/${DEVICE_ID}_enrol_payload.json

#Verify!
cat ${ENROL_FOLDER}/${DEVICE_ID}_enrol_payload.json | jq .

if [ $? -ne 0 ]; then
 echo "Error when checking ${ENROL_FOLDER}/${DEVICE_ID}_enrol_payload.json"
 exit -1
fi
echo "curl \
  --cacert ${CERTS_FOLDER}/default_ca.pem \\
  --cert ${CERTS_FOLDER}/default_cert.pem \\
  --key ${CERTS_FOLDER}/default_key.pem -v \\
  -d @${ENROL_FOLDER}/${DEVICE_ID}_enrol_payload.json \\
   --write-out %{http_code} \\
  -X POST \\
  -H \"Content-Type: application/json\" \
  -i \\
  https://${HTTP_SERVER}:${HTTP_SERVER_PORT}/api/flotta-management/v1/data/${DEVICE_ID}/out > ${ENROL_FOLDER}/${DEVICE_ID}_enrol_response.json"

status=$(curl \
  --cacert ${CERTS_FOLDER}/default_ca.pem \
  --cert ${CERTS_FOLDER}/default_cert.pem \
  --key ${CERTS_FOLDER}/default_key.pem -v \
  -d @${ENROL_FOLDER}/${DEVICE_ID}_enrol_payload.json \
  -X POST \
  -H "Content-Type: application/json" \
  -i \
  --write-out %{http_code} \
  https://${HTTP_SERVER}:${HTTP_SERVER_PORT}/api/flotta-management/v1/data/${DEVICE_ID}/out)

if [ $? -ne 0 ]; then
 echo "Error when sending enrol request, see  ${ENROL_FOLDER}/${DEVICE_ID}_enrol.out"
 exit -1
fi

if [ $status -eq 208 ]; then
  echo "Device ${DEVICE_ID} already enroled, got $status"
  exit $status
else
  if [ $status  -ne 200 ]; then
    echo "Error when sending enrol request, got status $status see  ${ENROL_FOLDER}/${DEVICE_ID}_enrol.err"
    exit $status
  fi
fi

exit 0