#!/bin/bash
#echo "${POST_BODY}" |  envsubst > ${ENROL_FOLDER}/${DEVICE_ID}_enrol_payload.json


echo "curl -XPOST \\
  --cacert ${CERTS_FOLDER}/default_ca.pem \\
  --cert ${CERTS_FOLDER}/${DEVICE_ID}.pem \\
  --key ${CERTS_FOLDER}/${DEVICE_ID}.key -v \\
  -H \"Content-Type: application/json\" \\
   --write-out %{http_code} \\
   -o /dev/null \\
  --data '${POST_BODY}' \\
  https://${HTTP_SERVER}:${HTTP_SERVER_PORT}/${REQUEST_PATH}"

status=$(curl -XPOST \
  --cacert ${CERTS_FOLDER}/default_ca.pem \
  --cert ${CERTS_FOLDER}/${DEVICE_ID}.pem \
  --key ${CERTS_FOLDER}/${DEVICE_ID}.key -v \
  -H "Content-Type: application/json" \
   --write-out %{http_code} \
   -o /dev/null \
  --data "${POST_BODY}" -i \
  https://${HTTP_SERVER}:${HTTP_SERVER_PORT}/${REQUEST_PATH})

if [ $? -ne 0 ]; then
  echo "Error posting device"
  exit -1
fi;

if [ $status -ne 200 ]; then
  echo "Error getting device updates, got status $status"
  exit $status
fi;

exit 0
