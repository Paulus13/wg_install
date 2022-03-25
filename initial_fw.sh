#!/bin/bash

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

echo "# Installing Wireguard"

#./remove.sh

./install_autoip_fw_ub2004.sh

./add-client.sh

echo "# Wireguard installed"

