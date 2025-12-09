#!/bin/bash

rm /etc/resolv.conf
bash -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'
bash -c 'echo "[network]" > /etc/wsl.conf'
bash -c 'echo "generateResolvConf = false" >> /etc/wsl.conf'
chattr +i /etc/resolv.conf
