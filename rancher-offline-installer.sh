#!/bin/bash

set -ebpf

export RKE_VERSION=1.24.9
export CERT_VERSION=v1.10.0
export RANCHER_VERSION=v2.7.0
export LONGHORN_VERSION=v1.3.2
export NEUVECTOR_VERSION=2.2.5
export DOMAIN=7310hargrove.court

export RED='\x1b[0;31m'
export GREEN='\x1b[32m'
export BLUE='\x1b[34m'
export YELLOW='\x1b[33m'
export NC='\x1b[0m'

# Build Server Packaging (unclassified and internet connected server)
function build-server () {

  echo - Installing packages
  yum install zstd skopeo -y > /dev/null 2>&1

  mkdir -p /opt/rancher/rke2_$RKE_VERSION/
  cd /opt/rancher/rke2_$RKE_VERSION/

  echo - download rke, rancher and longhorn
  # from https://docs.rke2.io/install/airgap
  curl -#OL https://github.com/rancher/rke2/releases/download/v$RKE_VERSION%2Brke2r1/rke2-images.linux-amd64.tar.zst
  curl -#OL https://github.com/rancher/rke2/releases/download/v$RKE_VERSION%2Brke2r1/rke2.linux-amd64.tar.gz
  curl -#OL https://github.com/rancher/rke2/releases/download/v$RKE_VERSION%2Brke2r1/sha256sum-amd64.txt
  curl -#OL https://github.com/rancher/rke2-packaging/releases/download/v$RKE_VERSION%2Brke2r1.stable.0/rke2-common-$RKE_VERSION.rke2r1-0.x86_64.rpm
  curl -#OL https://github.com/rancher/rke2-selinux/releases/download/v0.11.stable.1/rke2-selinux-0.11-1.el8.noarch.rpm

  echo - get the install script
  curl -sfL https://get.rke2.io -o install.sh

  echo - Get Helm Charts
  mkdir -p /opt/rancher/helm/
  cd /opt/rancher/helm/

  echo - get helm
  curl -#LO https://get.helm.sh/helm-v3.10.2-linux-386.tar.gz > /dev/null 2>&1
  tar -zxvf helm-v3.10.2-linux-386.tar.gz > /dev/null 2>&1
  rsync -avP linux-386/helm /usr/local/bin/ > /dev/null 2>&1
  rm -rf linux-386 > /dev/null 2>&1

  echo - add repos
  helm repo add jetstack https://charts.jetstack.io > /dev/null 2>&1
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest > /dev/null 2>&1
  helm repo add longhorn https://charts.longhorn.io > /dev/null 2>&1
  helm repo add neuvector https://neuvector.github.io/neuvector-helm/ > /dev/null 2>&1
  helm repo update > /dev/null 2>&1

  echo - get charts
  helm pull jetstack/cert-manager --version $CERT_VERSION > /dev/null 2>&1
  helm pull rancher-latest/rancher --version $RANCHER_VERSION > /dev/null 2>&1
  helm pull longhorn/longhorn --version $LONGHORN_VERSION > /dev/null 2>&1
  helm pull neuvector/core --version $NEUVECTOR_VERSION > /dev/null 2>&1

  echo - Get Images - Rancher/Longhorn

  echo - create image dir
  mkdir -p /opt/rancher/images/{cert,rancher,longhorn,registry,neuvector}
  cd /opt/rancher/images/

  echo - rancher image list 
  curl -#L https://github.com/rancher/rancher/releases/download/$RANCHER_VERSION/rancher-images.txt -o rancher/orig_rancher-images.txt

  echo - shorten rancher list with a sort
  # fix library tags
  sed -i -e '0,/busybox/s/busybox/library\/busybox/' -e 's/registry/library\/registry/g' rancher/orig_rancher-images.txt
  
  # remove things that are not needed and overlapped
  sed -i -E '/neuvector|minio|gke|aks|eks|sriov|harvester|mirrored|longhorn|thanos|tekton|istio|multus|hyper|jenkins|windows/d' rancher/orig_rancher-images.txt

  # get latest version
  for i in $(cat rancher/orig_rancher-images.txt|awk -F: '{print $1}'); do 
    grep -w $i rancher/orig_rancher-images.txt | sort -Vr| head -1 >> rancher/version_unsorted.txt
  done
 
  # final sort
  cat rancher/version_unsorted.txt | sort -u >> rancher/rancher-images.txt

  echo - Cert-manager image list
  helm template /opt/rancher/helm/cert-manager-$CERT_VERSION.tgz | awk '$1 ~ /image:/ {print $2}' | sed s/\"//g > cert/cert-manager-images.txt

  echo - longhorn image list
  curl -#L https://raw.githubusercontent.com/longhorn/longhorn/$LONGHORN_VERSION/deploy/longhorn-images.txt -o longhorn/longhorn-images.txt

  echo - neuvector image list
  helm template /opt/rancher/helm/core-$NEUVECTOR_VERSION.tgz | awk '$1 ~ /image:/ {print $2}' | sed -e 's/\"//g' > neuvector/neuvector_images.txt

 # get images
  echo - skopeo - cert-manager
  for i in $(cat cert/cert-manager-images.txt); do 
    skopeo copy docker://$i docker-archive:cert/$(echo $i| awk -F/ '{print $3}'|sed 's/:/_/g').tar:$(echo $i| awk -F/ '{print $3}') > /dev/null 2>&1
  done

  echo - skopeo - Neuvector
  for i in $(cat neuvector/neuvector_images.txt); do 
    skopeo copy docker://$i docker-archive:neuvector/$(echo $i| awk -F/ '{print $3}'|sed 's/:/_/g').tar:$(echo $i| awk -F/ '{print $3}') > /dev/null 2>&1
  done

  echo - skopeo - longhorn
  for i in $(cat longhorn/longhorn-images.txt); do 
    skopeo copy docker://$i docker-archive:longhorn/$(echo $i| awk -F/ '{print $2}'|sed 's/:/_/g').tar:$(echo $i| awk -F/ '{print $2}') > /dev/null 2>&1
  done

  echo - skopeo - Rancher - be patient...
  for i in $(cat rancher/rancher-images.txt); do 
    skopeo copy docker://$i docker-archive:rancher/$(echo $i| awk -F/ '{print $2}'|sed 's/:/_/g').tar:$(echo $i| awk -F/ '{print $2}') > /dev/null 2>&1
  done

  curl -#L https://github.com/zackbradys/rancher-offline/raw/main/registry.tar -o registry/registry_2.tar > /dev/null 2>&1

  cd /opt/rancher/
  echo - compress all the things
  tar -I zstd -vcf /opt/rancher-offline.zst $(ls) > /dev/null 2>&1

  echo "----------------------------------------------------------------"
  echo " to uncompress : "
  echo "   yum install -y zstd"
  echo "   mkdir /opt/rancher"
  echo "   tar -I zstd -vxf rancher-offline.zst -C /opt/rancher"
  echo "----------------------------------------------------------------"

}

# Install Base Settings
function base () {

  echo " updating kernel settings"
  cat << EOF >> /etc/sysctl.conf
# SWAP settings
vm.swappiness=0
vm.panic_on_oom=0
vm.overcommit_memory=1
kernel.panic=10
kernel.panic_on_oops=1
vm.max_map_count = 262144

# Have a larger connection range available
net.ipv4.ip_local_port_range=1024 65000

# Increase max connection
net.core.somaxconn=10000

# Reuse closed sockets faster
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15

# The maximum number of "backlogged sockets".  Default is 128.
net.core.somaxconn=4096
net.core.netdev_max_backlog=4096

# 16MB per socket - which sounds like a lot,
# but will virtually never consume that much.
net.core.rmem_max=16777216
net.core.wmem_max=16777216

# Various network tunables
net.ipv4.tcp_max_syn_backlog=20480
net.ipv4.tcp_max_tw_buckets=400000
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_wmem=4096 65536 16777216

# ARP cache settings for a highly loaded docker swarm
net.ipv4.neigh.default.gc_thresh1=8096
net.ipv4.neigh.default.gc_thresh2=12288
net.ipv4.neigh.default.gc_thresh3=16384

# ip_forward and tcp keepalive for iptables
net.ipv4.tcp_keepalive_time=600
net.ipv4.ip_forward=1

# monitor file system events
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=1048576
EOF
sysctl -p > /dev/null 2>&1

  echo install packages
  yum install -y zstd nfs-utils iptables skopeo container-selinux iptables libnetfilter_conntrack libnfnetlink libnftnl policycoreutils-python-utils cryptsetup iscsi-initiator-utils
  systemctl enable iscsid && systemctl start iscsid
  echo -e "[keyfile]\nunmanaged-devices=interface-name:cali*;interface-name:flannel*" > /etc/NetworkManager/conf.d/rke2-canal.conf
}

# Deploy Control Node (first node)
function deploy-control-nodes () {
  # this is for the first node
  # mkdir /opt/rancher
  # tar -I zstd -vxf rancher-offline.zst -C /opt/rancher

  base

  echo - Install rke2
  cd /opt/rancher/rke2_$RKE_VERSION
  useradd -r -c "etcd user" -s /sbin/nologin -M etcd -U
  mkdir -p /etc/rancher/rke2/ /var/lib/rancher/rke2/server/manifests/
  echo -e "#profile: cis-1.6\nselinux: true\nsecrets-encryption: true\nwrite-kubeconfig-mode: 0640\nkube-controller-manager-arg:\n- bind-address=127.0.0.1\n- use-service-account-credentials=true\n- tls-min-version=VersionTLS12\n- tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384\nkube-scheduler-arg:\n- tls-min-version=VersionTLS12\n- tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384\nkube-apiserver-arg:\n- tls-min-version=VersionTLS12\n- tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384\n- authorization-mode=RBAC,Node\n- anonymous-auth=false\n- audit-policy-file=/etc/rancher/rke2/audit-policy.yaml\n- audit-log-mode=blocking-strict\n- audit-log-maxage=30\nkubelet-arg:\n- protect-kernel-defaults=true\n- read-only-port=0\n- authorization-mode=Webhook" > /etc/rancher/rke2/config.yaml

  # set up audit policy file
  echo -e "apiVersion: audit.k8s.io/v1\nkind: Policy\nrules:\n- level: RequestResponse" > /etc/rancher/rke2/audit-policy.yaml

  # set up ssl passthrough for nginx
  echo -e "---\napiVersion: helm.cattle.io/v1\nkind: HelmChartConfig\nmetadata:\n  name: rke2-ingress-nginx\n  namespace: kube-system\nspec:\n  valuesContent: |-\n    controller:\n      config:\n        use-forwarded-headers: true\n      extraArgs:\n        enable-ssl-passthrough: true" > /var/lib/rancher/rke2/server/manifests/rke2-ingress-nginx-config.yaml; 

  # pre-load registry image
  mkdir -p /var/lib/rancher/rke2/agent/images
  rsync -avP /opt/rancher/images/registry/registry_2.tar /var/lib/rancher/rke2/agent/images/

 # insall rke2 - stig'd
  INSTALL_RKE2_ARTIFACT_PATH=/opt/rancher/rke2_$RKE_VERSION sh /opt/rancher/rke2_$RKE_VERSION/install.sh 
  yum install -y /opt/rancher/rke2_$RKE_VERSION/rke2-common-$RKE_VERSION.rke2r1-0.x86_64.rpm /opt/rancher/rke2_$RKE_VERSION/rke2-selinux-0.11-1.el8.noarch.rpm
  systemctl enable rke2-server.service && systemctl start rke2-server.service

  sleep 30

  # wait and add link
  echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml PATH=$PATH:/var/lib/rancher/rke2/bin" >> ~/.bashrc
  ln -s /var/run/k3s/containerd/containerd.sock /var/run/containerd/containerd.sock
  source ~/.bashrc

  echo - Setup nfs
  # share out opt directory
  echo "/opt/rancher *(ro)" > /etc/exports
  systemctl enable nfs-server.service && systemctl start nfs-server.service

  echo - run local registry
  # Adam made me use localhost:5000
  mkdir /opt/rancher/registry
  chcon system_u:object_r:container_file_t:s0 /opt/rancher/registry

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: registry
  labels:
    app: registry
spec:
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
      - name: registry
        image: registry:2
        ports:
        - name: registry
          containerPort: 5000
        securityContext:
          capabilities:
            add:
            - NET_BIND_SERVICE
        volumeMounts:
        - name: registry
          mountPath: /var/lib/registry
      volumes:
      - name: registry
        hostPath:
          path: /opt/rancher/registry
      hostNetwork: true
EOF

  sleep 30
  
  echo - load images
  for file in $(ls /opt/rancher/images/longhorn/ | grep -v txt ); do 
    skopeo copy docker-archive:/opt/rancher/images/longhorn/$file docker://$(echo $file | sed 's/.tar//g' | awk -F_ '{print "localhost:5000/longhornio/"$1":"$2}') --dest-tls-verify=false
  done

  # longhorn issue due to tags
  skopeo copy docker-archive:/opt/rancher/images/longhorn/longhorn-instance-manager_v1_20221003.tar docker://localhost:5000/longhornio/longhorn-instance-manager:v1_20221003 --dest-tls-verify=false
  skopeo copy docker-archive:/opt/rancher/images/longhorn/longhorn-share-manager_v1_20221003.tar docker://localhost:5000/longhornio/longhorn-share-manager:v1_20221003 --dest-tls-verify=false

  for file in $(ls /opt/rancher/images/cert/ | grep -v txt ); do 
    skopeo copy docker-archive:/opt/rancher/images/cert/$file docker://$(echo $file | sed 's/.tar//g' | awk -F_ '{print "localhost:5000/"$1":"$2}') --dest-tls-verify=false
  done

  for file in $(ls /opt/rancher/images/neuvector/ | grep -v txt ); do 
    skopeo copy docker-archive:/opt/rancher/images/neuvector/$file docker://$(echo $file | sed 's/.tar//g' | awk -F_ '{print "localhost:5000/neuvector/"$1":"$2}') --dest-tls-verify=false
  done

  for file in $(ls /opt/rancher/images/rancher/ | grep -v txt ); do 
    skopeo copy docker-archive:/opt/rancher/images/rancher/$file docker://$(echo $file | sed 's/.tar//g' | awk -F_ '{print "localhost:5000/rancher/"$1":"$2}') --dest-tls-verify=false
  done

  chmod 600 /etc/rancher/rke2/rke2.yaml

  echo - unpack helm
  cd /opt/rancher/helm
  tar -zxvf helm-v3.10.2-linux-386.tar.gz > /dev/null 2>&1
  rsync -avP linux-386/helm /usr/local/bin/ > /dev/null 2>&1

  cat /var/lib/rancher/rke2/server/token > /opt/rancher/token

  echo "----------------------------------------------------------------"
  echo " Next:"
  echo "  - Mkdir: \"mkdir /opt/rancher\""
  echo "  - Mount: \"mount $(hostname -I | awk '{ print $1 }'):/opt/rancher /opt/rancher\""
  echo "  - CD: \"cd /opt/rancher\""
  echo "  - Run: \""$0" worker\" on your worker nodes"
  echo "----------------------------------------------------------------"
  echo "  - yolo: \"mkdir /opt/rancher && mount $(hostname -I | awk '{ print $1 }'):/opt/rancher /opt/rancher && cd /opt/rancher && $0 worker\""
  echo "----------------------------------------------------------------"

}

# Deploy Worker Nodes (all other nodes)
function deploy-worker-nodes () {
  echo - deploy worker

  # check for mount point
  if [ ! -f /opt/rancher/token ]; then echo " -$RED Did you mount the volume from the first node?$NC"; exit 1; fi

  # base bits
  base

  export token=$(cat /opt/rancher/token)
  export server=$(mount |grep rancher | awk -F: '{print $1}')

  # setup RKE2
  mkdir -p /etc/rancher/rke2/
  echo -e "server: https://$server:9345\ntoken: $token\nwrite-kubeconfig-mode: 0640\n#profile: cis-1.6\nkube-apiserver-arg:\n- \"authorization-mode=RBAC,Node\"\nkubelet-arg:\n- \"protect-kernel-defaults=true\" " > /etc/rancher/rke2/config.yaml

  chmod 600 /etc/rancher/rke2/config.yaml

  # install rke2
  cd /opt/rancher
  INSTALL_RKE2_ARTIFACT_PATH=/opt/rancher/rke2_$RKE_VERSION INSTALL_RKE2_TYPE=agent sh /opt/rancher/rke2_$RKE_VERSION/install.sh 
  yum install -y /opt/rancher/rke2_$RKE_VERSION/rke2-common-$RKE_VERSION.rke2r1-0.x86_64.rpm /opt/rancher/rke2_$RKE_VERSION/rke2-selinux-0.11-1.el8.noarch.rpm

  rsync -avP /opt/rancher/images/registry/registry_2.tar /var/lib/rancher/rke2/agent/images/
  
  systemctl enable rke2-agent.service && systemctl start rke2-agent.service
}

# Deploy Rancher with local helm/images
function rancher () {
  echo - deploying rancher
  helm upgrade -i cert-manager /opt/rancher/helm/cert-manager-v1.10.0.tgz --namespace cert-manager --create-namespace --set installCRDs=true --set image.repository=localhost:5000/cert-manager-controller --set webhook.image.repository=localhost:5000/cert-manager-webhook --set cainjector.image.repository=localhost:5000/cert-manager-cainjector --set startupapicheck.image.repository=localhost:5000/cert-manager-ctl

  helm upgrade -i rancher /opt/rancher/helm/rancher-2.7.0.tgz --namespace cattle-system --create-namespace --set bootstrapPassword=bootStrapAllTheThings --set replicas=1 --set auditLog.level=2 --set auditLog.destination=hostPath --set useBundledSystemChart=true --set rancherImage=localhost:5000/rancher/rancher --set systemDefaultRegistry=localhost:5000 --set hostname=rancher.$DOMAIN

  echo "   - bootstrap password = \"bootStrapAllTheThings\" "
}

# Deploy Longhorn with local helm/images
function longhorn () {
  echo - deploying longhorn
  helm upgrade -i longhorn /opt/rancher/helm/longhorn-1.3.2.tgz --namespace longhorn-system --create-namespace --set ingress.enabled=true --set ingress.host=longhorn.$DOMAIN --set global.cattle.systemDefaultRegistry=localhost:5000
}

# Deploy Neuvector with local helm/images
function neuvector () {
  echo - deploying neuvector
  helm upgrade -i neuvector --namespace neuvector neuvector/core --create-namespace  --set imagePullSecrets=regsecret --set k3s.enabled=true --set k3s.runtimePath=/run/k3s/containerd/containerd.sock  --set manager.ingress.enabled=true --set controller.pvc.enabled=true --set controller.pvc.capacity=500Mi --set registry=localhost:5000 --set tag=5.0.5 --set controller.image.repository=neuvector/controller --set enforcer.image.repository=neuvector/enforcer --set manager.image.repository=neuvector/manager --set cve.updater.image.repository=neuvector/updater --set manager.ingress.host=neuvector.$DOMAIN
}

# Validate and Verify the Images
function validate () {
  echo - showing images
  kubectl get pods -A -o jsonpath="{.items[*].spec.containers[*].image}" | tr -s '[[:space:]]' '\n' |sort | uniq -c
}

############################# steps ################################
function helpme () {
  echo ""
  echo "----------------------------------------------------------------"
  echo ""
  echo "High Level Steps:"
  echo " - On the Build Server (Unclass)... Pull the Installer Script and Package It Up!"
  echo "    - mkdir /opt/rancher && cd /opt/rancher"
  echo "    - curl -#OL https://raw.githubusercontent.com/zackbradys/rancher-offline/main/rancher-offline-installer.sh"
  echo "    - chmod 755 rancher-offline-installer.sh"
  echo "    - $0 build"
  echo " - Move the Package (.zst) to the network/air gapped server"
  echo "    - ex: scp /opt/rancher-offline.zst user@IP:/opt/"
  echo " - Setup the Control Node Server (.zst)"
  echo "    - mkdir /opt/rancher && tar -I zstd -vxf rancher-offline.zst -C /opt/rancher"
  echo " - Install the Control Node Server (RKE2)"
  echo "    - cd /opt/rancher; $0 control"
  echo " - Setup the Worker Node Servers (RKE2)"
  echo "    - mkdir /opt/rancher && mount \$IP:/opt/rancher /opt/rancher"
  echo " - Install on each Worker Node Servers (RKE2)"
  echo "    - cd /opt/rancher; $0 worker"
  echo " - Install on the Control Node Server"
  echo "    - Rancher : $0 rancher"
  echo "    - Longhorn : $0 longhorn"
  echo "    - Neuvector : $0 neuvector"
  echo ""
  echo " - Please refer to the Github Repository for more details:"
  echo "    - https://github.com/zackbradys/rancher-offline"
  echo ""
  echo "----------------------------------------------------------------"
  echo ""
  exit 1
}

case "$1" in
        build ) build-server;;
        control) deploy-control-nodes;;
        worker) deploy-worker-nodes;;
        neuvector) neuvector;;
        longhorn) longhorn;;
        rancher) rancher;;
        validate) validate;;
        *) helpme;;
esac

