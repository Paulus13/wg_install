#!/bin/bash

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

if grep -qs "ubuntu" /etc/os-release; then
	os="ubuntu"
	os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
else
	echo "This script for Ubuntu 18.04 or higher. For other OS use original script"
	exit
fi

if [[ "$os" == "ubuntu" && "$os_version" -lt 1804 ]]; then
	echo "Ubuntu 18.04 or higher is required to use this installer.
This version of Ubuntu is too old and unsupported."
	exit
fi

if [[ "$os_version" = 1804 ]]; then
	apt install software-properties-common -y
	add-apt-repository ppa:wireguard/wireguard -y
	apt update
	apt install wireguard-dkms wireguard-tools qrencode -y
fi

if [[ "$os_version" = 2004 ]]; then
	apt update
	apt install wireguard qrencode -y
fi

NET_FORWARD="net.ipv4.ip_forward=1"
sysctl -w  ${NET_FORWARD}
sed -i "s:#${NET_FORWARD}:${NET_FORWARD}:" /etc/sysctl.conf

cd /etc/wireguard

umask 077

SERVER_PRIVKEY=$( wg genkey )
SERVER_PUBKEY=$( echo $SERVER_PRIVKEY | wg pubkey )

echo $SERVER_PUBKEY > ./server_public.key
echo $SERVER_PRIVKEY > ./server_private.key

# If system has a single IPv4, it is selected automatically. Else, ask the user
if [[ $(ip -4 addr | grep inet | grep -vEc '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}') -eq 1 ]]; then
	ip=$(ip -4 addr | grep inet | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
else
	number_of_ip=$(ip -4 addr | grep inet | grep -vEc '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
	echo
	echo "What IPv4 address should the WG server use?"
	ip -4 addr | grep inet | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | nl -s ') '
	read -p "IPv4 address [1]: " ip_number
	until [[ -z "$ip_number" || "$ip_number" =~ ^[0-9]+$ && "$ip_number" -le "$number_of_ip" ]]; do
		echo "$ip_number: invalid selection."
		read -p "IPv4 address [1]: " ip_number
	done
	[[ -z "$ip_number" ]] && ip_number="1"
	ip=$(ip -4 addr | grep inet | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sed -n "$ip_number"p)
fi

read -p "Enter the IP Address, [ENTER] set to default: $ip: " ip_new
if [ -z $ip_new ]
   then ip=$ip
else
	ip=$ip_new
fi

read -p "Enter the port, [ENTER] set to default: 53420: " port
if [ -z $port ]
   then port="53420"
fi

echo "IP =" $ip
echo "Port=" $port
echo $ip:$port > ./endpoint.var

#read -p "Enter the endpoint (external ip and port) in format [ipv4:port] (e.g. 4.3.2.1:54321):" ENDPOINT
#if [ -z $ENDPOINT ]
#then
#echo "[#]Empty endpoint. Exit"
#exit 1;
#fi
#echo $ENDPOINT > ./endpoint.var

if [ -z "$1" ]
  then 
    read -p "Enter the server address in the VPN subnet (CIDR format), [ENTER] set to default: 10.50.0.1: " SERVER_IP
    if [ -z $SERVER_IP ]
      then SERVER_IP="10.50.0.1"
    fi
  else SERVER_IP=$1
fi

echo $SERVER_IP | grep -o -E '([0-9]+\.){3}' > ./vpn_subnet.var

read -p "Enter the ip address of the server DNS (CIDR format), [ENTER] set to default: 1.1.1.1): " DNS
if [ -z $DNS ]
then DNS="1.1.1.1"
fi
echo $DNS > ./dns.var

echo 1 > ./last_used_ip.var

eth=$(ls /sys/class/net | awk '/^e/{print}')

read -p "Enter the name of the WAN network interface ([ENTER] set to default: $eth ): " WAN_INTERFACE_NAME
if [ -z $WAN_INTERFACE_NAME ]
then
  WAN_INTERFACE_NAME=$eth
fi

echo $WAN_INTERFACE_NAME > ./wan_interface_name.var

cat ./endpoint.var | sed -e "s/:/ /" | while read SERVER_EXTERNAL_IP SERVER_EXTERNAL_PORT
do
cat > ./wg0.conf.def << EOF
[Interface]
Address = $SERVER_IP
SaveConfig = false
PrivateKey = $SERVER_PRIVKEY
ListenPort = $SERVER_EXTERNAL_PORT
#PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $WAN_INTERFACE_NAME -j MASQUERADE;
#PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $WAN_INTERFACE_NAME -j MASQUERADE;
EOF
done

cp -f ./wg0.conf.def ./wg0.conf

systemctl enable wg-quick@wg0

read -p "Configure Firewall? [Y/n]: " fw
if [ -z $fw ]
then
  fw='Y'
fi

until [[ "$fw" =~ ^[yYnN]*$ ]]; do
	echo "$fw: invalid selection."
	read -p "Configure Firewall? [Y/n]: " fw
done
			
if [[ "$fw" =~ ^[yY]$ ]]; then
	iptables -P OUTPUT ACCEPT
	iptables -P INPUT DROP
	iptables -P FORWARD DROP

	iptables -A INPUT -p icmp -j ACCEPT
	iptables -A INPUT -p tcp --dport 5202 -j ACCEPT
	iptables -A INPUT -p tcp --dport 5202 -j ACCEPT
	iptables -A INPUT -p tcp --dport 22 -j ACCEPT
	iptables -A INPUT -p udp --dport 53 -j ACCEPT
	iptables -A INPUT -p tcp --dport 53 -j ACCEPT
	iptables -A INPUT -p udp --dport 53420 -j ACCEPT
	iptables -A INPUT -p tcp --dport 443 -j ACCEPT
	iptables -A INPUT -p tcp --dport 5555 -j ACCEPT
	iptables -A INPUT -p udp --dport 500 -j ACCEPT
	iptables -A INPUT -p udp --dport 1701 -j ACCEPT
	iptables -A INPUT -p udp --dport 4500 -j ACCEPT
	iptables -A INPUT -p 50 -j ACCEPT
	iptables -A INPUT -p 51 -j ACCEPT

	iptables -A INPUT -i lo -j ACCEPT
	iptables -A FORWARD -o lo -j ACCEPT

	iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

	iptables -t nat -A POSTROUTING -o $WAN_INTERFACE_NAME -j MASQUERADE
	iptables -A FORWARD -i wg0 -j ACCEPT
	iptables -A FORWARD -o wg0 -j ACCEPT
	iptables -A FORWARD -i tap_se0 -j ACCEPT
	iptables -A FORWARD -o tap_se0 -j ACCEPT
	
	apt install -y iptables-persistent
fi
