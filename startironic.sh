#!/bin/bash
set -ex

. /usr/local/bin/release-image.sh

IRONIC_IMAGE=$(image_for ironic)
IRONIC_AGENT_IMAGE=$(image_for ironic-agent)
CUSTOMIZATION_IMAGE=$(image_for image-customization-controller)
MACHINE_OS_IMAGES_IMAGE=$(image_for machine-os-images)

# This DHCP range is used by dnsmasq to serve DHCP to the cluster. If empty
# dnsmasq will only serve TFTP, and DHCP will be disabled.
DHCP_RANGE=""

# Used by ironic to allow ssh to running IPA instances
IRONIC_RAMDISK_SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOw0UuHxUFWdEjaRrRS3APGLtQZd0Y5xTr5dkXGxwHp2 kni@bastion.dual.local"

# First we stop any previously started containers, because ExecStop only runs when the ExecStart process
# e.g this script is still running, but we exit if *any* of the containers exits unexpectedly
for name in ironic-api ironic-conductor ironic-inspector ironic-ramdisk-logs dnsmasq httpd mariadb coreos-downloader image-customization; do
    podman ps | grep -w "$name$" && podman kill $name
    podman ps --all | grep -w "$name$" && podman rm $name -f
done

# Start the provisioning nic if not already started
PROVISIONING_NIC=ens4



if ! nmcli -t device | grep "$PROVISIONING_NIC:ethernet:connected"; then
    nmcli c add type ethernet ifname $PROVISIONING_NIC con-name provisioning  ip4  192.168.10.9/24
    nmcli c up provisioning
else
  connection=$(nmcli -t device show $PROVISIONING_NIC | grep GENERAL.CONNECTION | cut -d: -f2)
  nmcli con modify "$connection" ifname $PROVISIONING_NIC  ip4  192.168.10.9/24
  nmcli con reload "$connection"
  nmcli con up "$connection"
fi

# Wait for the interface to come up
# This is how the ironic container currently detects IRONIC_IP, this could probably be improved by using
# nmcli show provisioning there instead, but we need to confirm that works with the static-ip-manager
while [ -z "$(ip -o addr show dev $PROVISIONING_NIC | grep -v link)" ]; do
    sleep 1
done



# set password for ironic basic auth
# The ironic container contains httpd (and thus httpd-tools), so rely on it to
# supply the htpasswd command
AUTH_DIR=/opt/metal3/auth
IRONIC_HTPASSWD="$(cat ${AUTH_DIR}/ironic/password | podman run -i --rm --entrypoint htpasswd ${IRONIC_IMAGE} -niB bootstrap-user)"

# set password for mariadb
mariadb_password=$(uuidgen -r  | sed "s/-//g")

IRONIC_SHARED_VOLUME="ironic"
# Ignore errors here so we reuse any existing volume on pod restart
# this is helpful if an API service causes restart after the images
# have been downloaded
podman volume create $IRONIC_SHARED_VOLUME || true

# Apparently network-online doesn't necessarily mean iptables is ready, so wait until it is..
while ! iptables -L; do
  sleep 1
done

# Start dnsmasq, http, mariadb, and ironic containers using same image
# Currently we do this outside of a pod because we need to ensure the images
# are downloaded before starting the API pods

dnsmasq_container_name="dnsmasq"
podman run -d --net host --privileged --name $dnsmasq_container_name \
     --restart on-failure \
     --env PROVISIONING_INTERFACE=$PROVISIONING_NIC \
     --env DHCP_RANGE=$DHCP_RANGE \
     -v $IRONIC_SHARED_VOLUME:/shared:z --entrypoint /bin/rundnsmasq ${IRONIC_IMAGE}


podman run -d --net host --privileged --name mariadb \
     --restart on-failure \
     -v $IRONIC_SHARED_VOLUME:/shared:z --entrypoint /bin/runmariadb \
     --env MARIADB_PASSWORD=$mariadb_password ${IRONIC_IMAGE}


IPTABLES=iptables



EXTERNAL_IP_OPTIONS="ip=dhcp6"




  
PROVISIONING_IP_OPTIONS="ip=dhcp"
  



podman run -d --name coreos-downloader \
     --restart on-failure \
     --env IP_OPTIONS=${PROVISIONING_IP_OPTIONS} \
     -v $IRONIC_SHARED_VOLUME:/shared:z \
     ${MACHINE_OS_IMAGES_IMAGE} /bin/copy-metal --all /shared/html/images/

# Wait for images to be downloaded/ready
podman wait -i 1000ms coreos-downloader

podman run -d --net host --privileged --name httpd \
     --restart on-failure \
     --env IRONIC_RAMDISK_SSH_KEY="$IRONIC_RAMDISK_SSH_KEY" \
     --env PROVISIONING_INTERFACE=$PROVISIONING_NIC \
     -v $IRONIC_SHARED_VOLUME:/shared:z --entrypoint /bin/runhttpd ${IRONIC_IMAGE}

# Add firewall rules to ensure the IPA ramdisk can reach httpd, Ironic and the Inspector API on the host
for port in 80 5050 6385 ; do
    if ! $IPTABLES -C INPUT -i $PROVISIONING_NIC -p tcp -m tcp --dport $port -j ACCEPT > /dev/null 2>&1; then
        $IPTABLES -I INPUT -i $PROVISIONING_NIC -p tcp -m tcp --dport $port -j ACCEPT
    fi
done

# It is possible machine-api-operator comes up while the bootstrap is
# online, meaning there could be two DHCP servers on the network. To
# avoid bootstrap responding to a worker, which would cause a failed
# deployment, we filter out requests from anyone else than the control
# plane.  We are using iptables instead of dnsmasq's dhcp-host because
# DHCPv6 wants to use DUID's instead of mac addresses.


export KUBECONFIG=/opt/openshift/auth/kubeconfig-loopback

mkdir -p /tmp/nmstate


    until oc get -n openshift-machine-api baremetalhost master-1.ipi.acm.local; do
        echo Waiting for Host master-1.ipi.acm.local to appear...
        sleep 10
    done
    secret_name=$(oc get -n openshift-machine-api baremetalhost master-1.ipi.acm.local -o jsonpath="{.spec.preprovisioningNetworkDataName}")
    if [ -n "${secret_name}" ]; then
        until oc get -n openshift-machine-api secret "${secret_name}"; do
            echo Waiting for Secret "${secret_name}" to appear...
            sleep 10
        done
        oc get -n openshift-machine-api secret ${secret_name} -o jsonpath="{.data.nmstate}" | base64 -d > /tmp/nmstate/master-1.ipi.acm.local.yaml
    else
        touch /tmp/nmstate/master-1.ipi.acm.local.yaml
    fi

    until oc get -n openshift-machine-api baremetalhost master-2.ipi.acm.local; do
        echo Waiting for Host master-2.ipi.acm.local to appear...
        sleep 10
    done
    secret_name=$(oc get -n openshift-machine-api baremetalhost master-2.ipi.acm.local -o jsonpath="{.spec.preprovisioningNetworkDataName}")
    if [ -n "${secret_name}" ]; then
        until oc get -n openshift-machine-api secret "${secret_name}"; do
            echo Waiting for Secret "${secret_name}" to appear...
            sleep 10
        done
        oc get -n openshift-machine-api secret ${secret_name} -o jsonpath="{.data.nmstate}" | base64 -d > /tmp/nmstate/master-2.ipi.acm.local.yaml
    else
        touch /tmp/nmstate/master-2.ipi.acm.local.yaml
    fi

    until oc get -n openshift-machine-api baremetalhost master-3.ipi.acm.local; do
        echo Waiting for Host master-3.ipi.acm.local to appear...
        sleep 10
    done
    secret_name=$(oc get -n openshift-machine-api baremetalhost master-3.ipi.acm.local -o jsonpath="{.spec.preprovisioningNetworkDataName}")
    if [ -n "${secret_name}" ]; then
        until oc get -n openshift-machine-api secret "${secret_name}"; do
            echo Waiting for Secret "${secret_name}" to appear...
            sleep 10
        done
        oc get -n openshift-machine-api secret ${secret_name} -o jsonpath="{.data.nmstate}" | base64 -d > /tmp/nmstate/master-3.ipi.acm.local.yaml
    else
        touch /tmp/nmstate/master-3.ipi.acm.local.yaml
    fi


IRONIC_IP="fd7c:5e30:98fe:f591::7"
# If the IP contains a colon, then it's an IPv6 address, and the HTTP
# host needs surrounding with brackets
if [[ "$IRONIC_IP" =~ .*:.* ]]; then
    IRONIC_HOST="[${IRONIC_IP}]"
else
    IRONIC_HOST="${IRONIC_IP}"
fi

HTTP_PROXY="http://[fd7c:5e30:98fe:f591::100]:3128"
HTTPS_PROXY="http://[fd7c:5e30:98fe:f591::100]:3128"
NO_PROXY=".apps.ipi.acm.local,.cluster.local,.dual.local,.ipi.acm.local,.svc,127.0.0.1,127.0.0.1/32,192.168.10.0/24,5050,6385,8000,8084,8089,9999,::1/128,api-int.ipi.acm.local,fd02::/48,fd03::/112,fd7c:5e2f:98fd:c590::0/64,fd7c:5e2f:98fd:f590::0/64,fd7c:5e30:98fe:f591::/112,fd7c:5e30:98fe:f591::0/64,localhost"
# Create a podman secret for the image-customization-server 
podman secret rm pull-secret || true
base64 -w 0 /root/.docker/config.json | podman secret create pull-secret -

# Embed agent ignition into the rhcos live iso
podman run -d --net host --privileged --name image-customization \
    --env DEPLOY_ISO="/shared/html/images/ironic-python-agent.iso" \
    --env DEPLOY_INITRD="/shared/html/images/ironic-python-agent.initramfs" \
    --env IRONIC_BASE_URL="http://${IRONIC_HOST}" \
    --env IRONIC_RAMDISK_SSH_KEY="$IRONIC_RAMDISK_SSH_KEY" \
    --env IRONIC_AGENT_IMAGE="$IRONIC_AGENT_IMAGE" \
    --env IP_OPTIONS=$EXTERNAL_IP_OPTIONS \
    --env REGISTRIES_CONF_PATH=/tmp/containers/registries.conf \
    --env HTTP_PROXY="$HTTP_PROXY" \
    --env HTTPS_PROXY="$HTTPS_PROXY" \
    --env NO_PROXY="$NO_PROXY" \
    --entrypoint '["/image-customization-server", "--nmstate-dir=/tmp/nmstate/", "--images-publish-addr=http://0.0.0.0:8084"]' \
    -v /tmp/nmstate/:/tmp/nmstate/ \
    -v $IRONIC_SHARED_VOLUME:/shared:z \
    -v /etc/containers:/tmp/containers:z \
    --secret pull-secret,mode=400 \
    ${CUSTOMIZATION_IMAGE}

podman run -d --net host --privileged --name ironic-conductor \
     --restart on-failure \
     --env IRONIC_RAMDISK_SSH_KEY="$IRONIC_RAMDISK_SSH_KEY" \
     --env MARIADB_PASSWORD=$mariadb_password \
     --env PROVISIONING_INTERFACE=$PROVISIONING_NIC \
     --env OS_CONDUCTOR__HEARTBEAT_TIMEOUT=120 \
     --env HTTP_BASIC_HTPASSWD=${IRONIC_HTPASSWD} \
     --env IRONIC_KERNEL_PARAMS=${PROVISIONING_IP_OPTIONS} \
     --entrypoint /bin/runironic-conductor \
     -v $AUTH_DIR:/auth:ro \
     -v $IRONIC_SHARED_VOLUME:/shared:z ${IRONIC_IMAGE}

# We need a better way to wait for the DB sync to happen..
sleep 10

podman run -d --net host --privileged --name ironic-inspector \
     --restart on-failure \
     --env PROVISIONING_INTERFACE=$PROVISIONING_NIC \
     --env HTTP_BASIC_HTPASSWD=${IRONIC_HTPASSWD} \
     --env IRONIC_KERNEL_PARAMS=${PROVISIONING_IP_OPTIONS} \
     --entrypoint /bin/runironic-inspector \
     -v $AUTH_DIR:/auth:ro \
     -v $IRONIC_SHARED_VOLUME:/shared:z "${IRONIC_IMAGE}"

podman run -d --net host --privileged --name ironic-api \
     --restart on-failure \
     --env MARIADB_PASSWORD=$mariadb_password \
     --env PROVISIONING_INTERFACE=$PROVISIONING_NIC \
     --env HTTP_BASIC_HTPASSWD=${IRONIC_HTPASSWD} \
     --entrypoint /bin/runironic-api \
     -v $AUTH_DIR:/auth:ro \
     -v $IRONIC_SHARED_VOLUME:/shared:z ${IRONIC_IMAGE}

podman run -d --name ironic-ramdisk-logs \
     --restart on-failure \
     --entrypoint /bin/runlogwatch.sh \
     -v $IRONIC_SHARED_VOLUME:/shared:z ${IRONIC_IMAGE}

set +x
AUTH_DIR=/opt/metal3/auth
ironic_url="$(printf 'http://%s:%s@localhost:6385/v1' "$(cat "${AUTH_DIR}/ironic/username")" "$(cat "${AUTH_DIR}/ironic/password")")"
inspector_url="$(printf 'http://%s:%s@localhost:5050/v1' "$(cat "${AUTH_DIR}/ironic-inspector/username")" "$(cat "${AUTH_DIR}/ironic-inspector/password")")"

while [ "$(curl -s "${ironic_url}/nodes" | jq '.nodes[] | .uuid' | wc -l)" -lt 1 ]; do
  echo "Waiting for a control plane host to show up in Ironic..."
  sleep 20
done

while true; do
    # Check if all nodes have been deployed
    if ! curl -s "${ironic_url}/nodes" | jq '.nodes[] | .provision_state' | grep -v active;
    then
      echo "All hosts have been deployed."
      sleep 30
      while ! test -f /opt/openshift/.master-bmh-update.done; do
        echo "Waiting for introspection data to be synced..."
        sleep 10
      done

      echo "Stopping provisioning services..."
      podman stop ironic-api ironic-conductor ironic-inspector ironic-ramdisk-logs $dnsmasq_container_name httpd mariadb image-customization
      exit 0
    fi

    sleep 10
done
