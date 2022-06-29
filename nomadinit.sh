#!/bin/sh

# There should only be a single user, so this will get the username
NEW_USER=$(ls /home)

# Install docker
curl https://get.docker.com/ | bash

# Set up docker for NEW_USER
apt-get install -y uidmap
runuser -l $NEW_USER -c "dockerd-rootless-setuptool.sh install"

# Install hashicorp products
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt-get update && sudo apt-get install -y nomad consul

# Set up iptables for nomad
echo 1 > /proc/sys/net/bridge/bridge-nf-call-arptables
echo 1 > /proc/sys/net/bridge/bridge-nf-call-ip6tables
echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables

# Then make them persist between restarts
cat > /etc/sysctl.d/11-connect.conf <<EOL
net.bridge.bridge-nf-call-arptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOL

# Set up consul config
cat > /etc/consul.d/consul.hcl <<EOL
data_dir = "/opt/consul"

ui_config{
  enabled = true
}

server = true

bind_addr = "{{ GetInterfaceIP \"eth0\" }}" # Listen on all IPv4

bootstrap=true

ports {
  grpc = 8502
}

connect {
  enabled = true
}
EOL

# Set up nomad config
cat > /etc/nomad.d/nomad.hcl <<EOL
data_dir  = "/opt/nomad/data"
bind_addr = "0.0.0.0"

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true
  servers = ["127.0.0.1"]
}

plugin "docker" {
  config {
    volumes {
      enabled      = true
      selinuxlabel = "z"
    }
  }
}
EOL

# Install cni plugins
curl -L -o /tmp/cni-plugins.tgz "https://github.com/containernetworking/plugins/releases/download/v1.0.0/cni-plugins-linux-$( [ $(uname -m) = aarch64 ] && echo arm64 || echo amd64)"-v1.0.0.tgz
mkdir -p /opt/cni/bin
tar -C /opt/cni/bin -xzf /tmp/cni-plugins.tgz
rm /tmp/cni-plugins.tgz

# Start the services
systemctl enable consul
systemctl enable nomad
systemctl start consul
systemctl start nomad

apt install -y jq

# Wait for nomad to start
while ! nc -z localhost 4646; do
  sleep 1 # wait for 1/10 of the second before check again
done
sleep 5

# Enable memory oversubscription
NOMAD_ADDR=http://127.0.0.1:4646
curl -s $NOMAD_ADDR/v1/operator/scheduler/configuration | \
  jq '.SchedulerConfig | .MemoryOversubscriptionEnabled=true' | \
  curl -X PUT $NOMAD_ADDR/v1/operator/scheduler/configuration -d @-

