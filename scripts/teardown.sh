#!/bin/bash

if [ $# -eq 1 ]; then
    for i in $(seq $1)
    do
      NS=$((i - 1))
      kubectl get edgedevices -n $NS --no-headers | awk -v ns=$NS '{print $1 " --namespace=" ns}' |  xargs -P 20 -n 2 kubectl patch edgedevice -p '{"metadata":{"finalizers":null}}' --type=merge & 
      kubectl get edgeworkload -n $NS --no-headers | awk -v ns=$NS '{print $1 " --namespace=" ns}' | xargs -P 20  -n 2 kubectl patch edgeworkload -p '{"metadata":{"finalizers":null}}' --type=merge &
      kubectl delete edsr --all -n $NS &
      kubectl delete edgedevice --all -n $NS &
      kubectl delete edgeworkloads --all -n $NS &
      kubectl delete ns $NS
    done
    exit 0
fi

kubectl get edgedevices --all-namespaces --no-headers | awk '{print $2 " --namespace=" $1}' |  xargs -P 20 -n 2 kubectl patch edgedevice -p '{"metadata":{"finalizers":null}}' --type=merge &
kubectl get edgeworkload --all-namespaces --no-headers | awk '{print $2 " --namespace=" $1}' | xargs -P 20 -n 2 kubectl patch edgeworkload -p '{"metadata":{"finalizers":null}}' --type=merge &
kubectl delete edsr --all --all-namespaces &
kubectl delete edgedevice --all --all-namespaces &
kubectl delete edgeworkloads --all --all-namespaces &
