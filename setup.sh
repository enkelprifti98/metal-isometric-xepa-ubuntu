#!/bin/sh

# Install XFCE GUI, VNC server, and other necessary packages

apt update && apt install -y ca-certificates curl openssl sudo xvfb x11vnc xfce4 xfce4-terminal faenza-icon-theme bash procps nano git

# Set VNC password: ("admin" but you can set it to whatever)

mkdir -p /root/.vnc && x11vnc -storepasswd admin /root/.vnc/passwd

# Start GUI and VNC server services

export DISPLAY=:99
export RESOLUTION=1920x1080x24

nohup /usr/bin/Xvfb :99 -screen 0 $RESOLUTION -ac +extension GLX +render -noreset > /dev/null 2>&1 &

nohup startxfce4 > /dev/null 2>&1 &

nohup x11vnc -xkb -noxrecord -noxfixes -noxdamage -display $DISPLAY -forever -bg -rfbauth /root/.vnc/passwd -users root -rfbport 5900 > /dev/null 2>&1 &

# Install KVM hypervisor

apt install -y qemu qemu-kvm libvirt-daemon libvirt-clients bridge-utils virt-manager
modprobe tun
modprobe br_netfilter
grep -q -E 'vmx' /proc/cpuinfo && modprobe kvm-intel
grep -q -E 'svm' /proc/cpuinfo && modprobe kvm-amd
service libvirtd start


# Install web-browser (Firefox works, Chromium seems to throw an I/O error and doesn't launch)

apt install -y firefox
xdg-settings set default-web-browser firefox.desktop

# Install NoVNC (VNC client over http)

export NOVNC_TAG=$(curl -s https://api.github.com/repos/novnc/noVNC/releases/latest | jq -r .tag_name)

export WEBSOCKIFY_TAG=$(curl -s https://api.github.com/repos/novnc/websockify/releases/latest | jq -r .tag_name)

git clone --depth 1 https://github.com/novnc/noVNC --branch ${NOVNC_TAG} /root/noVNC

git clone --depth 1 https://github.com/novnc/websockify --branch ${WEBSOCKIFY_TAG} /root/noVNC/utils/websockify

cp /root/noVNC/vnc.html /root/noVNC/index.html

sed -i "s/UI.initSetting('resize', 'off');/UI.initSetting('resize', 'scale');/" /root/noVNC/app/ui.js

nohup /root/noVNC/utils/novnc_proxy --vnc localhost:5900 --listen 80 > /dev/null 2>&1 &

# Install File Browser (https://filebrowser.org/)
# Default login is:
# Username: admin
# Password: admin

curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

PUBLIC_IP=$(curl -s https://metadata.platformequinix.com/metadata | jq -r ".network.addresses[] | select(.public == true) | select(.address_family == 4) | .address")

nohup filebrowser -r /root -a $PUBLIC_IP -p 8080 > /dev/null 2>&1 &

clear

printf "\n\n"
echo "The ISO installation environment is available at:"
printf "\n"
echo "http://$PUBLIC_IP/"
printf "\n"
echo "The File Transfer portal is available at:"
printf "\n"
echo "http://$PUBLIC_IP:8080/"
printf "\n"
echo "The instance is running in $([ -d /sys/firmware/efi ] && echo UEFI || echo BIOS) boot mode."
printf "\n\n"

