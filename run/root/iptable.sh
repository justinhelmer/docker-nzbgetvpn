#!/bin/bash

# ip route
###

# split comma seperated string into list from LAN_NETWORK env variable
IFS=',' read -ra lan_network_list <<< "${LAN_NETWORK}"

# process lan networks in the list
for lan_network_item in "${lan_network_list[@]}"; do

	# strip whitespace from start and end of lan_network_item
	lan_network_item=$(echo "${lan_network_item}" | sed -e 's/^[ \t]*//')

	echo "[info] Adding ${lan_network_item} as route via docker eth0"
	ip route add "${lan_network_item}" via "${DEFAULT_GATEWAY}" dev eth0

done

echo "[info] ip route defined as follows..."
echo "--------------------"
ip route
echo "--------------------"


# setup iptables marks to allow routing of defined ports via eth0
###

if [[ "${DEBUG}" == "true" ]]; then
	echo "[debug] Modules currently loaded for kernel" ; lsmod
fi

# check kernel for iptable_mangle module
lsmod | grep "iptable_mangle" > /dev/null
iptable_mangle_exit_code=$?

# delect if iptable mangle module present
if [[ $iptable_mangle_exit_code != 0 ]]; then

	echo "[warn] 'iptable_mangle' kernel module not available, you will not be able to connect to the applications Web UI or Privoxy outside of your LAN"
	echo "[info] unRAID users: Please attempt to load the module by executing the following on your host:- '/sbin/modprobe iptable_mangle'"
	echo "[info] Ubuntu users: Please attempt to load the module by executing the following on your host:- '/sbin/modprobe iptable_mangle'"
	echo "[info] Synology users: Please attempt to load the module by executing the following on your host:- 'insmod /lib/modules/iptable_mangle.ko'"

else

	echo "[info] iptable_mangle support detected, adding fwmark for tables"

	# setup route for nzbget webui http using set-mark to route traffic for port 6789 to eth0
	echo "6789    webui_http" >> /etc/iproute2/rt_tables
	ip rule add fwmark 1 table webui_http
	ip route add default via $DEFAULT_GATEWAY table webui_http

fi

# identify docker bridge interface name (probably eth0)
docker_interface=$(netstat -ie | grep -vE "lo|tun|tap" | sed -n '1!p' | grep -P -o -m 1 '^[^:]+')
if [[ "${DEBUG}" == "true" ]]; then
	echo "[debug] Docker interface defined as ${docker_interface}"
fi

# identify ip for docker bridge interface
docker_ip=$(ifconfig "${docker_interface}" | grep -P -o -m 1 '(?<=inet\s)[^\s]+')
if [[ "${DEBUG}" == "true" ]]; then
	echo "[debug] Docker IP defined as ${docker_ip}"
fi

# identify netmask for docker bridge interface
docker_mask=$(ifconfig "${docker_interface}" | grep -P -o -m 1 '(?<=netmask\s)[^\s]+')
if [[ "${DEBUG}" == "true" ]]; then
	echo "[debug] Docker netmask defined as ${docker_mask}"
fi

# convert netmask into cidr format
docker_network_cidr=$(ipcalc "${docker_ip}" "${docker_mask}" | grep -P -o -m 1 "(?<=Network:)\s+[^\s]+")
echo "[info] Docker network defined as ${docker_network_cidr}"

# input iptable rules
###

# set policy to drop for input
iptables -P INPUT DROP

# accept input to tunnel adapter
iptables -A INPUT -i "${VPN_DEVICE_TYPE}"0 -j ACCEPT

# accept input to/from docker containers (172.x range is internal dhcp)
iptables -A INPUT -s "${docker_network_cidr}" -d "${docker_network_cidr}" -j ACCEPT

# accept input to vpn gateway
iptables -A INPUT -i eth0 -p $VPN_PROTOCOL --sport $VPN_PORT -j ACCEPT

# accept input to nzbget webui port 6789
iptables -A INPUT -i eth0 -p tcp --dport 6789 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp --sport 6789 -j ACCEPT

# additional port list for scripts
if [[ ! -z "${ADDITIONAL_PORTS}" ]]; then

	# split comma seperated string into list from ADDITIONAL_PORTS env variable
	IFS=',' read -ra additional_port_list <<< "${ADDITIONAL_PORTS}"

	# process additional ports in the list
	for additional_port_item in "${additional_port_list[@]}"; do

		# strip whitespace from start and end of additional_port_item
		additional_port_item=$(echo "${additional_port_item}" | sed -e 's/^[ \t]*//')

		echo "[info] Adding additional incoming port ${additional_port_item} for eth0"

		# accept input to additional port for eth0
		iptables -A INPUT -i eth0 -p tcp --dport "${additional_port_item}" -j ACCEPT
		iptables -A INPUT -i eth0 -p tcp --sport "${additional_port_item}" -j ACCEPT

	done

fi

# process lan networks in the list
for lan_network_item in "${lan_network_list[@]}"; do

	# strip whitespace from start and end of lan_network_item
	lan_network_item=$(echo "${lan_network_item}" | sed -e 's/^[ \t]*//')

	# accept input to privoxy if enabled
	if [[ $ENABLE_PRIVOXY == "yes" ]]; then
		iptables -A INPUT -i eth0 -p tcp -s "${lan_network_item}" -d "${docker_network_cidr}" -j ACCEPT
	fi

done

# accept input dns lookup
iptables -A INPUT -p udp --sport 53 -j ACCEPT

# accept input icmp (ping)
iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT

# accept input to local loopback
iptables -A INPUT -i lo -j ACCEPT

# output iptable rules
###

# set policy to drop for output
iptables -P OUTPUT DROP

# accept output from tunnel adapter
iptables -A OUTPUT -o "${VPN_DEVICE_TYPE}"0 -j ACCEPT

# accept output to/from docker containers (172.x range is internal dhcp)
iptables -A OUTPUT -s "${docker_network_cidr}" -d "${docker_network_cidr}" -j ACCEPT

# accept output from vpn gateway
iptables -A OUTPUT -o eth0 -p $VPN_PROTOCOL --dport $VPN_PORT -j ACCEPT

# if iptable mangle is available (kernel module) then use mark
if [[ $iptable_mangle_exit_code == 0 ]]; then

	# accept output from nzbget webui port 6789 - used for external access
	iptables -t mangle -A OUTPUT -p tcp --dport 6789 -j MARK --set-mark 1
	iptables -t mangle -A OUTPUT -p tcp --sport 6789 -j MARK --set-mark 1

fi

# accept output from nzbget webui port 6789 - used for lan access
iptables -A OUTPUT -o eth0 -p tcp --dport 6789 -j ACCEPT
iptables -A OUTPUT -o eth0 -p tcp --sport 6789 -j ACCEPT

# additional port list for scripts
if [[ ! -z "${ADDITIONAL_PORTS}" ]]; then

	# split comma seperated string into list from ADDITIONAL_PORTS env variable
	IFS=',' read -ra additional_port_list <<< "${ADDITIONAL_PORTS}"

	# process additional ports in the list
	for additional_port_item in "${additional_port_list[@]}"; do

		# strip whitespace from start and end of additional_port_item
		additional_port_item=$(echo "${additional_port_item}" | sed -e 's/^[ \t]*//')

		echo "[info] Adding additional outgoing port ${additional_port_item} for eth0"

		# accept output to additional port for eth0
		iptables -A OUTPUT -o eth0 -p tcp --dport "${additional_port_item}" -j ACCEPT
		iptables -A OUTPUT -o eth0 -p tcp --sport "${additional_port_item}" -j ACCEPT

	done

fi

# process lan networks in the list
for lan_network_item in "${lan_network_list[@]}"; do

	# strip whitespace from start and end of lan_network_item
	lan_network_item=$(echo "${lan_network_item}" | sed -e 's/^[ \t]*//')

	# accept output from privoxy if enabled - used for lan access
	if [[ $ENABLE_PRIVOXY == "yes" ]]; then
		iptables -A OUTPUT -o eth0 -p tcp -s "${docker_network_cidr}" -d "${lan_network_item}" -j ACCEPT
	fi

done

# accept output for dns lookup
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT

# accept output for icmp (ping)
iptables -A OUTPUT -p icmp --icmp-type echo-request -j ACCEPT

# accept output from local loopback adapter
iptables -A OUTPUT -o lo -j ACCEPT

echo "[info] iptables defined as follows..."
echo "--------------------"
iptables -S
echo "--------------------"
