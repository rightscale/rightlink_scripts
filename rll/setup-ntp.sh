#! /bin/bash -e
#
# ---
# RightScript Name: RL10 Linux Setup NTP
# Description: Installs and configures NTP client.
# Inputs:
#   SETUP_NTP:
#     Category: RightScale
#     Description: |
#       Whether or not to configure NTP. "if_missing" only configures NTP if its not already setup by a service such as
#       DHCP while "always" will overwrite any existing configuration.
#     Input Type: single
#     Required: true
#     Advanced: true
#     Default: text:if_missing
#     Possible Values:
#       - text:always
#       - text:if_missing
#       - text:none
#   NTP_SERVERS:
#     Category: RightScale
#     Description: |
#       A comma-separated list of fully qualified domain names for the array  of servers that instances should talk to
#       Example: time1.example.com, time2.example.com, time3.example.com. An empty value will leave ntp unconfigured.
#     Input Type: single
#     Required: true
#     Advanced: true
#     Default: text:time.rightscale.com
# Attachments: []
# ...

# Check if a file needs to be written. First checks if the target file exists and if so checks if the checksums of the
# target file and the temporary file match.
#
# $1: the target file path to be checked
# $2: the temporary file path with new contents to check against
function run_check_write_needed() {
  sudo [ ! -f "$1" ] || [[ $(run_checksum "$2") != $(run_checksum "$1") ]]
}

# Get the SHA256 checksum of a file.
#
# $1: the file path to get the checksum from
#
function run_checksum() {
  sudo sha256sum "$1" | cut -d ' ' -f 1
}

# Add a temporary file to the list of temporary files to clean up on exit.
#
# $@: one or more file paths to add to the list
#
function add_mktemp_file() {
  mktemp_files=("$@" "${mktemp_files[@]}")
}

# Handle installation of NTP service first off

# Run passed-in command with retries if errors occur.
#
# $@: full line command
#
function retry_command() {
  # Setting config variables for this function
  retries=5
  wait_time=10

  while [ $retries -gt 0 ]; do
    # Reset this variable before every iteration to be checked if changed
    issue_running_command=false
    $@ || { issue_running_command=true; }
    if [ "$issue_running_command" = true ]; then
      (( retries-- ))
      echo "Error occurred - will retry shortly"
      sleep $wait_time
    else
      # Break out of loop since command was successful.
      break
    fi
  done

  # Check if issue running command still existed after all retries
  if [ "$issue_running_command" = true ]; then
    echo "ERROR: Unable to run: '$@'"
    return 1
  fi
}


SETUP_NTP=${SETUP_NTP:-"if_missing"}
if [[ "$SETUP_NTP" == "none" ]]; then
  echo "Not configuring NTP: SETUP_NTP is none"
  exit 0
fi

if [[ -z "$NTP_SERVERS" ]]; then
  echo "Not configuring NTP: No NTP servers specified"
  exit 0
fi

#######################################
# Setup NTP
#######################################
if [[ -d /etc/apt ]]; then
  ntp_service=ntp
  if ! which ntpd >/dev/null 2>&1; then
    retry_command sudo apt-get update -y >/dev/null
    retry_command sudo apt-get install -y ntp
  fi
elif [[ -d /etc/yum.repos.d ]] && grep -q 'release 8' /etc/redhat-release; then
  echo "This appears to be Redhat or Centos 8.  NTP has been replaced by Chrony in those versions.  Skipping..."
  exit 0
elif [[ -d /etc/yum.repos.d ]]; then
  ntp_service=ntpd
  if ! which ntpd >/dev/null 2>&1; then
    retry_command sudo yum install -y ntp
  fi
  if sudo chkconfig 2>/dev/null | grep ntpd >/dev/null 2>&1; then
    sudo chkconfig ntpd on
  elif sudo systemctl list-unit-files 2>/dev/null | grep ntpd >/dev/null 2>&1; then
    sudo systemctl enable ntpd
  fi
elif grep -i coreos /etc/os-release >/dev/null 2>&1; then
  # CoreOS case. CoreOS already configures time without any help from us.
  echo "Not configuring NTP, CoreOS configures it by default."
  exit 0
else
  echo "Not configuring NTP, unsupported or unknown distro."
  exit 1
fi

if [[ "$SETUP_NTP" == "if_missing" ]]; then
  if grep -i -E '^server ' /etc/ntp.conf 2>/dev/null; then
    echo "NTP already configured, skipping setup."
    if ! sudo service $ntp_service status; then
      sudo service $ntp_service start
    fi
    exit 0
  fi
fi

#######################################
# Configure NTP
#######################################

# Declare a list for temporary files to clean up on exit and set the command to delete them if they still exist when the
# script exits
declare -a mktemp_files
trap 'sudo rm --force "${mktemp_files[@]}"' EXIT

# Read NTP servers input into an array
IFS=',' read -r -a ntp_servers_array <<<"$NTP_SERVERS"

# Initialize variables
ntp_var_lib=/var/lib/ntp
ntp_stats=/var/log/ntpstats
ntp_conf=/etc/ntp.conf
ntp_service_notify=0

sudo mkdir --mode=0755 --parents $ntp_var_lib $ntp_stats
sudo chown ntp:ntp $ntp_var_lib $ntp_stats

# Create a temporary file for the NTP configuration
ntp_conf_tmp=$(sudo mktemp "${ntp_conf}.XXXXXXXXXX")
add_mktemp_file "$ntp_conf_tmp"

sudo tee "$ntp_conf_tmp" >/dev/null <<EOF
# Generated by BASE ntp RightScript
tinker panic 0
statsdir $ntp_stats/
driftfile $ntp_var_lib/ntp.drift

statistics loopstats peerstats clockstats
filegen loopstats file loopstats type day enable
filegen peerstats file peerstats type day enable
filegen clockstats file clockstats type day enable

disable monitor

EOF

for ntp_server in "${ntp_servers_array[@]}"; do
  sudo tee -a "$ntp_conf_tmp" >/dev/null  <<EOF
server $ntp_server iburst
restrict $ntp_server nomodify notrap noquery
EOF
done

sudo  tee -a "$ntp_conf_tmp" >/dev/null <<EOF

restrict default kod notrap nomodify nopeer noquery
restrict 127.0.0.1 nomodify
restrict -6 default kod notrap nomodify nopeer noquery
restrict -6 ::1 nomodify
EOF

# Overwrite and backup the NTP configuration if it has changed
if run_check_write_needed "$ntp_conf" "$ntp_conf_tmp"; then
  sudo chown ntp:ntp "$ntp_conf_tmp"
  sudo chmod 0644 "$ntp_conf_tmp"

  [[ -f $ntp_conf ]] && sudo cp --archive $ntp_conf "${ntp_conf}.$(date -u +%Y%m%d%H%M%S)"
  sudo mv --force "$ntp_conf_tmp" "$ntp_conf"
  if which restorecon >/dev/null 2>&1; then
    sudo restorecon -v "$ntp_conf" || true
  fi
  ntp_service_notify=1
fi

# Start the NTP service if it is not running or restart it if it needs to be restarted
if ! sudo service $ntp_service status; then
  sudo service $ntp_service start
elif [[ $ntp_service_notify -eq 1 ]]; then
  sudo service $ntp_service restart
fi
