#!/bin/bash
#echo "${POST_BODY}" |  envsubst > ${ENROL_FOLDER}/${DEVICE_ID}_enrol_payload.json


echo "curl -XPOST \\
  --cacert ${CERTS_FOLDER}/default_ca.pem \\
  --cert ${CERTS_FOLDER}/${DEVICE_ID}.pem \\
  --key ${CERTS_FOLDER}/${DEVICE_ID}.key -v \\
  -H \"Content-Type: application/json\" \\
  --data '${POST_BODY}' \\
  https://${HTTP_SERVER}:${HTTP_SERVER_PORT}/${REQUEST_PATH} | grep \"200\""

curl -XPOST \
  --cacert ${CERTS_FOLDER}/default_ca.pem \
  --cert ${CERTS_FOLDER}/${DEVICE_ID}.pem \
  --key ${CERTS_FOLDER}/${DEVICE_ID}.key -v \
  -H "Content-Type: application/json" \
  --data "${POST_BODY}" -i \
  https://${HTTP_SERVER}:${HTTP_SERVER_PORT}/${REQUEST_PATH} | grep "200"

if [ $? -ne 0 ]; then
  echo "Error posting device"
  exit -1
fi;

exit 0
