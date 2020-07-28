#!/bin/bash -ve

# Disable pointless daemons
systemctl stop snapd snapd.socket lxcfs snap.amazon-ssm-agent.amazon-ssm-agent
systemctl disable snapd snapd.socket lxcfs snap.amazon-ssm-agent.amazon-ssm-agent

# Disable swap to make K8S happy
swapoff -a
sed -i '/swap/d' /etc/fstab

# Install K8S, kubeadm and Docker
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y kubelet=${k8sversion}-00 kubeadm=${k8sversion}-00 kubectl=${k8sversion}-00 awscli jq docker.io
apt-mark hold kubelet kubeadm kubectl docker.io

# Point Docker at big ephemeral drive and turn on log rotation
systemctl stop docker
mkdir /mnt/docker
chmod 711 /mnt/docker
cat <<EOF > /etc/docker/daemon.json
{
    "data-root": "/mnt/docker",
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "5"
    }
}
EOF
systemctl start docker
systemctl enable docker

# Point kubelet at big ephemeral drive
mkdir /mnt/kubelet
echo 'KUBELET_EXTRA_ARGS="--root-dir=/mnt/kubelet --cloud-provider=aws"' > /etc/default/kubelet

# Pass bridged IPv4 traffic to iptables chains (required by Flannel)
echo "net.bridge.bridge-nf-call-iptables = 1" > /etc/sysctl.d/60-flannel.conf
service procps start

# Compute cert hash from backup if available
if [[ "${backupenabled}" == "1" ]]; then
    until aws s3 ls s3://${s3bucket}/pki; do
        # wait until master finally uploads its certs to the S3 bucket
        echo "Waiting for master node to create folder at s3://${s3bucket}/pki..."
        sleep 15
    done
    latest_backup=$(aws s3api list-objects --bucket ${s3bucket} --prefix pki --query 'reverse(sort_by(Contents,&LastModified))[0]' | jq -rc .Key)
    old_instance_id=$(echo $latest_backup | cut -d'/' -f2)
    aws s3 cp s3://${s3bucket}/pki/$old_instance_id/ca.crt /tmp/ca.crt
    discovery_hash=$(openssl x509 -pubkey -in /tmp/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')
    rm /tmp/ca.crt
fi

# Join the cluster
for i in {1..50}; do
    if [[ "${backupenabled}" == "1" ]]; then
        kubeadm join --token=${k8stoken} --discovery-token-ca-cert-hash sha256:$${discovery_hash} --node-name=$(curl -s http://169.254.169.254/latest/meta-data/local-hostname) ${masterIP}:6443 && break || sleep 15;
    else
        kubeadm join --token=${k8stoken} --discovery-token-unsafe-skip-ca-verification --node-name=$(curl -s http://169.254.169.254/latest/meta-data/local-hostname) ${masterIP}:6443 && break || sleep 15;
    fi
done
