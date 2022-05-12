#!/bin/bash 
openssl ecparam -name prime256v1 -genkey -noout -out ${CERTS_FOLDER}/${DEVICE_ID}.key
openssl req -new -subj '/CN=${DEVICE_ID}' -key ${CERTS_FOLDER}/${DEVICE_ID}.key -out ${CERTS_FOLDER}/${DEVICE_ID}.csr
export CERTIFICATE_REQUEST=$(cat ${CERTS_FOLDER}/${DEVICE_ID}.csr | sed 's/$/\\n/' | tr -d '\n')
UUID=$(uuidgen)

echo "${PAYLOAD}" | sed -e 's/"content": {/"content": {\n       "certificate_request": "$CERTIFICATE_REQUEST",/g' | envsubst > ${REGISTRATION_FOLDER}/${DEVICE_ID}_payload.json

#Verify!
cat ${REGISTRATION_FOLDER}/${DEVICE_ID}_payload.json | jq .

if [ $? -ne 0 ]; then
 echo "Error when checking ${REGISTRATION_FOLDER}/${DEVICE_ID}_payload.json"
 exit -1
fi
echo "curl \\
  --cacert ${CERTS_FOLDER}/default_ca.pem \\
  --cert ${CERTS_FOLDER}/default_cert.pem \\
  --key ${CERTS_FOLDER}/default_key.pem -v \\
  -d @${REGISTRATION_FOLDER}/${DEVICE_ID}_payload.json \\
  -X POST \\
  -H \"Content-Type: application/json\" \\
   --write-out %{http_code} \\
  -o ${REGISTRATION_FOLDER}/${DEVICE_ID}_response.json \\
  https://${HTTP_SERVER}:${HTTP_SERVER_PORT}/api/flotta-management/v1/data/${DEVICE_ID}/out"


count=0
status=404
while [[ $status -eq 404 ]]; do
  status=$(curl \
    --cacert ${CERTS_FOLDER}/default_ca.pem \
    --cert ${CERTS_FOLDER}/default_cert.pem \
    --key ${CERTS_FOLDER}/default_key.pem -v \
    -d @${REGISTRATION_FOLDER}/${DEVICE_ID}_payload.json \
    -X POST \
    -H "Content-Type: application/json" \
    -o ${REGISTRATION_FOLDER}/${DEVICE_ID}_response.json \
    --write-out %{http_code} \
    https://${HTTP_SERVER}:${HTTP_SERVER_PORT}/api/flotta-management/v1/data/${DEVICE_ID}/out)
  let count+=1 
  echo $count
  sleep 60
done;

echo $status
if [[ $status -eq 404 ]]; then
 echo "Error when sending registration request, see  ${REGISTRATION_FOLDER}/${DEVICE_ID}_register.out"
 exit -1
fi

if [ $status -ne 200 ]; then
 echo "Error when sending registration request, got code $status see  ${REGISTRATION_FOLDER}/${DEVICE_ID}_register.out"
 exit $status
fi

cat ${REGISTRATION_FOLDER}/${DEVICE_ID}_response.json | jq '.content.certificate' | sed -e 's/\\n/\n/g' | sed -e 's/"//g' > ${CERTS_FOLDER}/${DEVICE_ID}.pem


#openssl x509 -in ${CERTS_FOLDER}/${DEVICE_ID}.pem --text

if [ $? -ne 0 ]; then
 echo "Error when extracting ${REGISTRATION_FOLDER}/${DEVICE_ID}_response.json to  ${CERTS_FOLDER}/${DEVICE_ID}.pem"
 exit -1
fi

exit 0

