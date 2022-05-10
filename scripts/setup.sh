sysctl -w net.core.somaxconn=50000
sysctl -w net.core.netdev_max_backlog=50000
sysctl -w net.ipv4.tcp_max_syn_backlog=50000 
sysctl -w net.ipv4.ip_local_port_range="15000 65000"
sysctl -w net.ipv4.tcp_fin_timeout=10
sysctl -w vm.max_map_count=999999
sysctl -w kernel.threads-max=4113992

if [[ -z $(grep "* soft nofile 999999" "/etc/security/limits.conf") ]]; then
    echo "* soft nofile 999999" >> /etc/security/limits.conf
fi

if [[ -z $(grep "* hard nofile 999999" "/etc/security/limits.conf") ]]; then
    echo "* hard nofile 999999" >> /etc/security/limits.conf
fi


ifconfig br-ex txqueuelen 5000
ifconfig cni-podman0 txqueuelen 5000
ifconfig ens3 txqueuelen 5000
ifconfig ens4 txqueuelen 5000
ifconfig ovn-k8s-mp0 txqueuelen 5000
