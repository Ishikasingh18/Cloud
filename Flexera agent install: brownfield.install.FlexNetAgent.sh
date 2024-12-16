#!/usr/bin/env bash


# Brownfield configure managesoft/flexera agent for ALM
# Setup:
#       1. Put script in the root directory "/"
#       2. Execute sudo su
#       3. Execute chmod +x brownfield.install.FlexNetAgent.sh
#       4. Execute "./brownfield.install.FlexNetAgent.sh"
#       5. Youur console will show the output of Tracker.log after execution to verify installation


set -x
set -e # Exit immediately on any failure
. /etc/os-release


# Which Cloud Provider are we running?
if curl -x "" -s -f -m 5 http://169.254.169.254/latest/meta-data/ > /dev/null ; then
      # We are in AWS
      export CSPbeaconURL=https://mirrors.it.att.com/pub/custom/SD/nasCommon/Flexera/Agents/Linux/AWS_on-prem_beacons.txt

elif curl -x "" -s -f -m 5 -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2018-04-02" > /dev/null ; then
      # We are in Azure
      export CSPbeaconURL=https://mirrors.it.att.com/pub/custom/SD/nasCommon/Flexera/Agents/Linux/Azure_private_endpoints.txt
else
      # We are not in Azure or AWS
      echo "This is not a supported Cloud Service Provider" 
      exit 99
fi

# Leave blank for now; registering the ephemeral packer image will leave stale data behind in the image
export svcEndpoint=""
export svcProxy=http://proxy.conexus.svc.local:3128
export agentPackageURL="https://mirrors.it.att.com/pub/custom/SD/nasCommon/Flexera/Agents/Linux"

# Seed for initial configuaration
cat << 'EOF' | envsubst '$svcProxy:$svcEndpoint' > /var/tmp/mgsft_rollout_response
# The ManageSoft domain name.  Refer to the ManageSoft
# documentation for further details.
# MGSFT_DOMAIN_NAME=Flexerasoftware.com

# The alternate machine identification allows the specification of an
# alternate machine name if it is to be different to the current hostname
# (e.g. if registered differently in Active Directory) Not specifying
# this setting or a value of NONE disables this feature.
# MGSFT_MACHINE_ID=

# The policy path specifies the location of the policy to be applied to
# the managed device.  This is typically used when the policy is not
# attached to Active Directory domains.  For example, a path may be
# "Policies/Merged/MANAGESOFT_domain/Machine/device.npl".  Not specifying
# this setting or a value of NONE disables this feature.
# MGSFT_POLICY_PATH=`echo ${BOOTSTRAPPEDPOLICY} | sed -e 's/^\$[(].*[)]\///'`

# The initial ManageSoft download location(s) for the installation.
# For example, http://myhost.mydomain.com/ManageSoftDL/
# Refer to the ManageSoft documentation for further details.
# 10.254.237.133 is the load balancer for eastus2
MGSFT_BOOTSTRAP_DOWNLOAD=${svcEndpoint}

# The initial ManageSoft reporting location(s) for the installation.
# For example, http://myhost.mydomain.com/ManageSoftRL/
# Refer to the ManageSoft documentation for further details.
MGSFT_BOOTSTRAP_UPLOAD=${svcEndpoint}

# The initial proxy configuration.  Uncomment these to enable proxy configuration.
# Note that setting values of NONE disables this feature.
MGSFT_HTTP_PROXY=${svcProxy}
MGSFT_HTTPS_PROXY=${svcProxy}
# MGSFT_PROXY=socks:socks.socksproxy.local:19121,direct
# MGSFT_NO_PROXY=internal1.local,internal2.local

# Check the HTTPS server certificate's existence, name, validity period,
# and issuance by a trusted certificate authority (CA).  This is enabled
# by default and can be disabled with false.
MGSFT_HTTPS_CHECKSERVERCERTIFICATE=false

# Check that the HTTPS server certificate has not been revoked. This is
# enabled by default and can be disabled with false.
MGSFT_HTTPS_CHECKCERTIFICATEREVOCATION=false

# The run policy flag determines if policy will run after installation.
#    "1" or "Yes" will run policy after install
#    "0" or "No" will not run policy
MGSFT_RUNPOLICY=1
EOF
if [ -n "${PACKER_BUILDER_TYPE}" ] ; then
  echo "===== Rendered /var/tmp/mgsft_rollout_response file ====="
  cat /var/tmp/mgsft_rollout_response
  echo "========================================================="
fi

# Package Installation
export http_proxy="${svcProxy}"
export https_proxy="${svcProxy}"

if [[ "${ID_LIKE}" =~ "fedora" ]] ; then
  agentPackageName="managesoft-21.1.0-1.x86_64.rpm"
  /bin/rpm --upgrade --oldpackage --verbose "${agentPackageURL}/${agentPackageName}"
elif [[ "${ID_LIKE}" =~ "debian" ]] ; then
  agentPackageName="managesoft_21.1.0_amd64.deb"
  TMPDIR=$(mktemp -d)
  pushd "${TMPDIR}"
  curl -s -O "${agentPackageURL}/${agentPackageName}"
  until dpkg -i "${agentPackageName}" ; do
    sleep 5
    curl -s -O "${agentPackageURL}/${agentPackageName}"
  done
  popd
  rm -fr "${TMPDIR}"
else
  echo "This OS does not have a handler defined. This is a required agent. Aborting!"
  exit 1
fi

# Stop and disable service so we can configure on first boot
systemctl stop ndtask mgsusageag
systemctl disable ndtask mgsusageag

# Remove installation logs; leaving these behind in the golden image
# causes confusion if something goes wrong during VM startup.
rm -f /var/opt/managesoft/log/* || /bin/true

# Configure for first startup; do so through cloud-init's per-instance so that clones of clones of clones
# will always do the right thing on instantiation.
mkdir -p /var/lib/cloud/scripts/per-instance
> /var/lib/cloud/scripts/per-instance/configure-managesoft.sh

chmod 0750 /var/lib/cloud/scripts/per-instance/configure-managesoft.sh
export FALLBACK_BEACONS=$(curl -x "${svcProxy}" -sL "${CSPbeaconURL}" \
           | sed $'s/\r//g' \
           | grep -E '\.att\.com$|\.sbc\.com$')

cat << 'EOF' | envsubst '$FALLBACK_BEACONS:$CSPbeaconURL' > /var/lib/cloud/scripts/per-instance/configure-managesoft.sh
#!/usr/bin/env bash

export proxy=http://proxy.conexus.svc.local:3128

# Determine First Contact beacons
fallback_beacons="
${FALLBACK_BEACONS}
"

beacons=$(curl -x "${proxy}" -sL "${CSPbeaconURL}" \
           | sed $'s/\r//g' \
           | grep -E '\.att\.com$|\.sbc\.com$')

# Test to ensure the retrieved list is not empty
if [ $(echo "${beacons}" |  tr -d '\n' | awk '{print NF}') -eq 0 ] ; then
  echo "RETRIEVED FLEXERA ALM BEACON LIST EMPTY!!!! Using fallback beacons hardcoded in this script."
  beacons="${fallback_beacons}"
fi

# Reset logs
rm -f /var/opt/managesoft/log/*

> /var/tmp/config.ini
region_pref=$(curl -x "" -s -H Metadata:true 'http://169.254.169.254/metadata/instance?api-version=2019-08-15' | jq -r .compute.location | sed 's/[0-9]$//g')
for beacon in $(echo "${beacons}" | sort -R) ; do
  export beacon
  export uploadUuid=$(uuidgen)
  export downloadUuid=$(uuidgen)
  # If the beacon is in the local region (ignoring any traling numbers) let's give it a more favorable priority
  if echo "${beacon}" | cut -d. -f1 | sed 's/[0-9]$//g' | grep -q "${region_pref}" ; then
    export priority=25
  else
    export priority=50
  fi
  cat << '_EOF_' | envsubst '$beacon:$priority:$proxy:$downloadUuid:$uploadUuid' >> /var/tmp/config.ini
[ManageSoft\Common\DownloadSettings\${downloadUuid}]
Priority=${priority}
Host=${beacon}
Protocol=https
PORT=443
Proxy=${proxy}
User=
Password=
AutoPriority=False
Directory=ManageSoftDL

[ManageSoft\Common\UploadSettings\${uploadUuid}]
Priority=${priority}
Host=${beacon}
Protocol=https
PORT=443
Proxy=${proxy}
User=
Password=
AutoPriority=False
Directory=ManageSoftRL

_EOF_
  unset uploadUuid downloadUuid beacon
done
cat << '_EOF_' >> /var/tmp/config.ini
[ManageSoft\NetSelector\CurrentVersion]
SelectorAlgorithm=MgsNameMatch(20,,true)
_EOF_
/opt/managesoft/bin/mgsconfig -i /var/tmp/config.ini && rm -f /var/tmp/config.ini

systemctl enable ndtask mgsusageag
systemctl start ndtask mgsusageag

# Configure initial schedule that will be assertive with failed
# registrations in hopes of avoiding orphaned clients
cat << '_EOF_' > /var/tmp/schedule.nds
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE Schedule PUBLIC "ManageSoft Schedule" "http://www.managesoft.com/schedule.dtd">

<Schedule SCHEDSCHEMA="60" NAME="Default Machine Schedule" TIMEDATESTAMP="20200608T121948Z">
  <Event NETWORK="false" NAME="Update Machine Policy" ID="{30c8899c-9eab-4f07-9160-d8610b27f67f}" CATCHUP="Never" IDLEDURATION="0">
    <LogicalCommand PARAM="-t Machine -o UserInteractionLevel=Quiet" COMPONENT="PolicyClient" ACTION="Apply" />
    <Trigger TIMESTART="000500" REPEAT="43200" DURATION="86400" TYPE="Daily" TYPE_PARAM="1" TIMEWINDOW="3600" DATESTART="20200608" />
    <Trigger TIMESTART="121948" TYPE="Logon" TYPE_PARAM="0" TIMEWINDOW="0" DATESTART="20200608" />
    <Trigger TIMESTART="121948" TYPE="OnConnect" TYPE_PARAM="0" TIMEWINDOW="0" DATESTART="20200608" />
    <Trigger TIMESTART="121948" TYPE="Now" TYPE_PARAM="1" TIMEWINDOW="0" DATESTART="20200608" />
  </Event>
</Schedule>
_EOF_

/opt/managesoft/bin/ndschedag -o ScheduleType=Machine -o ScheduleRootURL=/var/tmp/schedule.nds /var/tmp/schedule.nds && rm -f /var/tmp/schedule.nds
EOF

# Execute configuration and startup script if run outside of Packer
[ -z "${PACKER_BUILDER_TYPE}" ] && /var/lib/cloud/scripts/per-instance/configure-managesoft.sh || /bin/true

# Setup and execute ndtrack
cd /opt/managesoft/bin
chmod 700 ndtrack
/opt/managesoft/bin/ndtrack -t machine

# If ndtrack worked then tracker.log exists. Go to the directory and display
# Look for "Upload successful" near the bottom of the file to verify

cd /var/opt/managesoft/log
echo "------------------------Tracker.log Output follows-------------------------------"
cat tracker.log
