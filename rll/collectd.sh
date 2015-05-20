#! /bin/bash -e

# ---
# RightScript Name: BASE collectd
# Description: Install and setup collectd and basic set of plugins. This configures
#   collectd to work with RightScale TSS (Time Series Storage), the backend system
#   for aggregating monitoring data. Collectd sends its monitoring data to the 
#   RightLink process on the localhost over http using the write_http plugin. RightLink
#   then forwards that data to the TSS servers over HTTPS with authentication.
# Inputs:
#   RS_INSTANCE_UUID:
#     Input Type: single
#     Category: RightScale
#     Default: env:RS_INSTANCE_UUID
#     Required: true
#     Advanced: true
#   COLLECTD_SERVER:
#     Input Type: single
#     Category: RightScale
#     Default: env:RS_TSS
#     Description: The FQDN or IP address of the remote collectd server.
#     Required: true
#     Advanced: true
# ...
#

# Check if a file needs to be written. First checks if the target file exists and if so checks if the checksums of the
# target file and the temporary file match.
#
# $1: the target file path to be checked
# $2: the temporary file path with new contents to check against
#
function run_check_write_needed() {
  sudo [ ! -f $1 ] || [[ `run_checksum $2` != `run_checksum $1` ]]
}

# Get the SHA256 checksum of a file.
#
# $1: the file path to get the checksum from
#
function run_checksum() {
  sudo sha256sum $1 | cut -d ' ' -f 1
}

# Add a temporary file to the list of temporary files to clean up on exit.
#
# $@: one or more file paths to add to the list
#
function add_mktemp_file() {
  mktemp_files=("$@" "${mktemp_files[@]}")
}

# Configure a collectd plugin.
#
# $1: the name of the collectd plugin to configure
# $@: zero or more configuration options to set
#
function configure_collectd_plugin() {
  local collectd_plugin=$1
  # Remove $1 from $@
  shift
  local collectd_plugin_conf="$collectd_conf_plugins_dir/${collectd_plugin}.conf"
  # Create a temporary file for the collectd plugin configration
  local collectd_plugin_conf_tmp=`sudo mktemp "${collectd_plugin_conf}.XXXXXXXXXX"`
  add_mktemp_file $collectd_plugin_conf_tmp

  sudo dd of="$collectd_plugin_conf_tmp" 2>/dev/null <<EOF
# Generated by BASE collectd RightScript
LoadPlugin "$collectd_plugin"
EOF

  # Add each configuration option to the collectd plugin configuration if there are any
  if [[ $# -ne 0 ]]; then
    sudo dd oflag=append conv=notrunc of="$collectd_plugin_conf_tmp" 2>/dev/null <<EOF

<Plugin "$collectd_plugin">
EOF

    for option in "$@"; do
      sudo bash -c "echo '  $option' >> $collectd_plugin_conf_tmp"
    done
    sudo bash -c "echo '</Plugin>' >> $collectd_plugin_conf_tmp"
  fi

  # Overwrite and backup the collectd plugin configration if it has changed
  if run_check_write_needed $collectd_plugin_conf $collectd_plugin_conf_tmp; then
    sudo chmod 0644 $collectd_plugin_conf_tmp
    sudo [ -f $collectd_plugin_conf ] && sudo cp --archive $collectd_plugin_conf "${collectd_plugin_conf}.`date -u +%Y%m%d%H%M%S`"
    sudo mv --force $collectd_plugin_conf_tmp $collectd_plugin_conf
    collectd_service_notify=1
  fi

  echo "collectd plugin $collectd_plugin configured"
}

# Initialize variables
if [[ ! "$COLLECTD_SERVER" =~ tss ]]; then
  echo "ERROR: This script will only run on a TSS enabled account. Contact RightScale Support to enable."
  exit 1
fi

# Collectd package is located in the EPEL repository. Install if its not already
# installed.
if [[ -e /etc/redhat-release ]]; then
  if [[ `cat /etc/redhat-release` =~ ^([^0-9]+)\ ([0-9])\. ]]; then
    distro="${BASH_REMATCH[1]}"
    ver="${BASH_REMATCH[2]}"
  else
    echo "Could not parse distro and version from /etc/redhat-release"
    exit 1
  fi

  case "$ver" in
  6)
    if ! yum list installed "epel-release-6*"; then
      echo "Installing EPEL repository"
      sudo rpm -Uvh http://download.fedoraproject.org/pub/epel/6/x86_64/epel-release-6-8.noarch.rpm
      if [[ "$distro" =~ CentOS ]]; then 
        # versions of CentOS 6.x have trouble with https...
        sudo sed -i 's/https/http/' /etc/yum.repos.d/epel.repo
      fi
    fi
    ;;
  7)
    if ! yum list installed "epel-release-7*"; then
      echo "Installing EPEL repository"
      sudo rpm -Uvh http://download.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm
    fi
    ;;
  esac
fi


# Declare a list for temporary files to clean up on exit and set the command to delete them if they still exist when the
# script exits
declare -a mktemp_files
trap 'sudo rm --force "${mktemp_files[@]}"' EXIT

collectd_base_dir=/var/lib/collectd
collectd_types_db=/usr/share/collectd/types.db
collectd_interval=10
collectd_read_threads=5
collectd_server_port=3011
collectd_service=collectd
collectd_service_notify=0

if [[ -d /etc/apt ]]; then
  collectd_conf_dir=/etc/collectd
  collectd_conf_plugins_dir="$collectd_conf_dir/plugins"
  collectd_plugin_dir=/usr/lib/collectd
elif [[ -d /etc/yum.repos.d ]]; then
  collectd_conf_dir=/etc
  collectd_conf_plugins_dir="$collectd_conf_dir/collectd.d"
  collectd_plugin_dir=/usr/lib64/collectd
else
  echo "unsupported distribution!"
  exit 1
fi

collectd_conf="$collectd_conf_dir/collectd.conf"
collectd_collection_conf="$collectd_conf_dir/collection.conf"
collectd_thresholds_conf="$collectd_conf_dir/thresholds.conf"

# Install platform specific collectd packages
if [[ -d /etc/apt ]]; then
  sudo apt-get install -y curl collectd-core
elif [[ -d /etc/yum.repos.d ]]; then
  # keep these lines separate, yum doesn't fail for missing packages when grouped together
  sudo yum install -y curl
  sudo yum install -y collectd
fi

# For TSS, collectd connects to the rightlink process, which runs with a random
# high port for localhost (127.0.0.1). Without this permission relaxed, we'll get  
# permission denied connecting to that local ip 
if sestatus 2>/dev/null | grep "SELinux status" | grep enabled; then
  sudo setsebool -P collectd_tcp_network_connect 1
fi

sudo mkdir --mode=0755 --parents $collectd_conf_plugins_dir $collectd_base_dir $collectd_plugin_dir

# Create a temporary file for the collectd configuration
collectd_conf_tmp=`sudo mktemp "${collectd_conf}.XXXXXXXXXX"`
add_mktemp_file $collectd_conf_tmp

sudo dd of="$collectd_conf_tmp" 2>/dev/null <<EOF
# Config file for collectd(1).
#
# Some plugins need additional configuration and are disabled by default.
# Please read collectd.conf(5) for details.
#
# You should also read /usr/share/doc/collectd/README.Debian.plugins before
# enabling any more plugins.

Hostname "$RS_INSTANCE_UUID"
FQDNLookup false
BaseDir "$collectd_base_dir"
PluginDir "$collectd_plugin_dir"
TypesDB "$collectd_types_db"
Interval $collectd_interval
ReadThreads $collectd_read_threads

Include "$collectd_conf_plugins_dir/*.conf"
Include "$collectd_thresholds_conf"
EOF

# Overwrite and backup the collectd configuration if it has changed
if run_check_write_needed $collectd_conf $collectd_conf_tmp; then
  sudo chmod 0644 $collectd_conf_tmp
  sudo [ -f $collectd_conf ] && sudo cp --archive $collectd_conf "${collectd_conf}.`date -u +%Y%m%d%H%M%S`"
  sudo mv --force $collectd_conf_tmp $collectd_conf
  collectd_service_notify=1
fi

# Create a temporary file for the collectd collection configuration
collectd_collection_conf_tmp=`sudo mktemp "${collectd_collection_conf}.XXXXXXXXXX"`
add_mktemp_file $collectd_collection_conf_tmp

sudo dd of="$collectd_collection_conf_tmp" 2>/dev/null <<EOF
datadir: "$collectd_base_dir/rrd/"
libdir: "$collectd_plugin_dir/"
EOF

# Overwrite and backup the collectd collection configuration if it has changed
if run_check_write_needed $collectd_collection_conf $collectd_collection_conf_tmp; then
  sudo chmod 0644 $collectd_collection_conf_tmp
  [[ -f $collectd_collection_conf ]] && sudo cp --archive $collectd_collection_conf "${collectd_collection_conf}.`date -u +%Y%m%d%H%M%S`"
  sudo mv --force $collectd_collection_conf_tmp $collectd_collection_conf
  collectd_service_notify=1
fi

# Create a temporary file for the collectd thresholds configuration
collectd_thresholds_conf_tmp=`sudo mktemp "${collectd_thresholds_conf}.XXXXXXXXXX"`
add_mktemp_file $collectd_thresholds_conf_tmp

sudo dd of="$collectd_thresholds_conf_tmp" 2>/dev/null <<EOF
# Threshold configuration for collectd(1).
#
# See the section "THRESHOLD CONFIGURATION" in collectd.conf(5) for details.

#<Threshold>
#	<Type "counter">
#		WarningMin 0.00
#		WarningMax 1000.00
#		FailureMin 0
#		FailureMax 1200.00
#		Invert false
#		Persist false
#		Instance "some_instance"
#	</Type>
#
#	<Plugin "interface">
#		Instance "eth0"
#		<Type "if_octets">
#			DataSource "rx"
#			FailureMax 10000000
#		</Type>
#	</Plugin>
#
#	<Host "hostname">
#		<Type "cpu">
#			Instance "idle"
#			FailureMin 10
#		</Type>
#
#		<Plugin "memory">
#			<Type "memory">
#				Instance "cached"
#				WarningMin 100000000
#			</Type>
#		</Plugin>
#	</Host>
#</Threshold>
EOF

# Overwrite and backup the collectd thresholds configuration if it has changed
if run_check_write_needed $collectd_thresholds_conf $collectd_thresholds_conf_tmp; then
  sudo chmod 0644 $collectd_thresholds_conf_tmp
  [[ -f $collectd_thresholds_conf ]] && sudo cp --archive $collectd_thresholds_conf "${collectd_thresholds_conf}.`date -u +%Y%m%d%H%M%S`"
  sudo mv --force $collectd_thresholds_conf_tmp $collectd_thresholds_conf
  collectd_service_notify=1
fi

configure_collectd_plugin syslog
configure_collectd_plugin interface \
  'Interface "eth0"'
configure_collectd_plugin cpu
configure_collectd_plugin df \
  'ReportReserved false' \
  'FSType "proc"' \
  'FSType "sysfs"' \
  'FSType "fusectl"' \
  'FSType "debugfs"' \
  'FSType "securityfs"' \
  'FSType "devtmpfs"' \
  'FSType "devpts"' \
  'FSType "tmpfs"' \
  'IgnoreSelected true'
configure_collectd_plugin disk
configure_collectd_plugin memory

if [[ $(sudo swapon -s | wc -l) -gt 1 ]];then
  configure_collectd_plugin swap
else
  echo "swapfile not setup, skipping collectd swap plugin"
fi

# Populate RS_RLL_PORT
source /var/run/rightlink/secret
/usr/local/bin/rsc rl10 put_hostname /rll/tss/hostname hostname=$COLLECTD_SERVER
collectd_ver=5
if [[ "$(collectd -h)" =~ "collectd 4" ]]; then
  collectd_ver=4
fi
configure_collectd_plugin write_http \
  "<URL \"http://127.0.0.1:$RS_RLL_PORT/rll/tss/collectdv$collectd_ver\">" \
  "  BufferSize 16384" \
  "</URL>"

configure_collectd_plugin load
configure_collectd_plugin processes
configure_collectd_plugin users


# Make sure the collectd service is enabled
if [[ -d /etc/yum.repos.d ]]; then
  sudo chkconfig $collectd_service on
fi

# Start the collectd service if it is not running or restart it if it needs to be restarted
if ! sudo service $collectd_service status; then
  sudo service $collectd_service start
elif [[ $collectd_service_notify -eq 1 ]]; then
  sudo service $collectd_service restart
fi

# Add the RightScale monitoring active tag
auth_tag=rs_monitoring:state=auth
/usr/local/bin/rsc --rl10 cm15 multi_add /api/tags/multi_add resource_hrefs[]=$RS_SELF_HREF tags[]=$auth_tag &&\
  logger -s -t RightScale "Setting monitoring active tag"
