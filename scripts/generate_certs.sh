#!/bin/bash
if [[ -z "${CERTS_FOLDER}" ]]; then
  export CERTS_FOLDER="${test_dir}/certs"
  echo "CERTS_FOLDER no defined, setting it to ${CERTS_FOLDER}"
fi
mkdir -p $CERTS_FOLDER

# make get-certs
kubectl -n flotta get secret flotta-ca -o go-template='{{ index .data "ca.crt" | base64decode}}'  > ${CERTS_FOLDER}/${DEVICE_ID}_ca.pem
export REG_SECRET_NAME=$(kubectl get secrets -n flotta -l reg-client-ca=true --sort-by=.metadata.creationTimestamp | tail -1 | awk '{print $1}')
kubectl -n flotta get secret ${REG_SECRET_NAME} -o go-template='{{ index .data "client.crt" | base64decode}}' > ${CERTS_FOLDER}/${DEVICE_ID}_cert.pem
kubectl -n flotta get secret ${REG_SECRET_NAME} -o go-template='{{ index .data "client.key" | base64decode}}' > ${CERTS_FOLDER}/${DEVICE_ID}_key.pem
# make get-certs END
