#!/bin/bash
###########################
# Configuration Variables #
###########################

DEFAULT_BACK_DIR="/pve-backup/backups"
MAX_BACKUPS=5

SLACK_API_TOKEN="xoxb-***"
SLACK_CHANNEL="***"

###########################

# Set terminal to "dumb" if not set (cron compatibility)
export TERM=${TERM:-dumb}

# Always exit on error
set -e

# Set backup directory to default OR environment variable
_bdir=${BACK_DIR:-$DEFAULT_BACK_DIR}

# Check if backup directory exists
if [[ ! -d "${_bdir}" ]] ; then
    echo "Aborting because backup target does not exist"
    exit 1
fi

# Temporary storage directory
_tdir=${TMP_DIR:-/var/tmp}
_tdir=$(mktemp -d "${_tdir}/proxmox-XXXXXXXX")

function clean_up {
    echo "Cleaning up"
    rm -rf "${_tdir}"
}

# Register the cleanup function to be called on the EXIT signal
trap clean_up EXIT

# Set current date and hostname
_now=$(date +%Y-%m-%d.%H.%M.%S)
_HOSTNAME=$(hostname)

# Define backup file names
_filename1="${_tdir}/proxmoxetc.${_now}.tar"
_filename2="${_tdir}/proxmoxvarlibpve.${_now}.tar"
_filename3="${_tdir}/proxmoxroot.${_now}.tar"
_filename4="${_tdir}/proxmoxcron.${_now}.tar"
_filename5="${_tdir}/proxmoxvbios.${_now}.tar"
_filename6="${_tdir}/proxmoxpackages.${_now}.list"
_filename7="${_tdir}/proxmoxreport.${_now}.txt"
_filename8="${_tdir}/proxmoxlocalbin.${_now}.tar"
_filename9="${_tdir}/proxmoxetcpve.${_now}.tar"
_filename_final="${_tdir}/pve_${_HOSTNAME}_${_now}.tar.gz"

##########

function check_num_backups {
    local backup_count
    backup_count=$(ls "${_bdir}"/*"${_HOSTNAME}"*_*.tar.gz -l | grep ^- | wc -l)

    if [[ ${backup_count} -ge $MAX_BACKUPS ]]; then
        local old_backup
        old_backup=$(basename "$(ls "${_bdir}"/*"${_HOSTNAME}"*.tar.gz -t | tail -1)")
        echo "${_bdir}/${old_backup}"
        rm "${_bdir}/${old_backup}"
    fi
}

function copy_filesystem {
    echo "Creating tar files"
    # Copy key system files
    tar --warning='no-file-ignored' -cvPf "${_filename1}" /etc/.
    tar --warning='no-file-ignored' -cvPf "${_filename9}" /etc/pve/.
    tar --warning='no-file-ignored' -cvPf "${_filename2}" /var/lib/pve-cluster/.
    tar --warning='no-file-ignored' -cvPf "${_filename3}" /root/.
    tar --warning='no-file-ignored' -cvPf "${_filename4}" /var/spool/cron/.

    if [[ -n "$(ls -A /usr/local/bin 2>/dev/null)" ]]; then
        tar --warning='no-file-ignored' -cvPf "${_filename8}" /usr/local/bin/.
    fi

    if [[ -n "$(ls /usr/share/kvm/*.vbios 2>/dev/null)" ]]; then
        echo "Backing up custom video BIOS..."
        tar --warning='no-file-ignored' -cvPf "${_filename5}" /usr/share/kvm/*.vbios
    fi

    # Copy installed packages list
    echo "Copying installed packages list from APT"
    apt-mark showmanual | tee "${_filename6}"

    # Copy pvereport output
    echo "Copying pvereport output"
    pvereport | tee "${_filename7}"
}

function compress_and_archive {
    echo "Compressing files"
    tar -cvzPf "${_filename_final}" "${_tdir}"/*.{tar,list,txt}

    # Copy config archive to backup folder
    cp "${_filename_final}" "${_bdir}/"
}

function stop_services {
    for service in pve-cluster pvedaemon vz qemu-server; do
        systemctl stop "$service"
    done

    # Give them a moment to finish
    sleep 10s
}

function start_services {
    for service in qemu-server vz pvedaemon pve-cluster; do
        systemctl start "$service"
    done

    # Make sure that all VMs + LXC containers are running
    qm startall
}

function send_message_to_slack {
    local file_name
    file_name=$(basename "${_filename_final}")
    local file_size
    file_size=$(wc -c < "${_filename_final}")
    local response
    response=$(curl -s \
        -X POST \
        -H "Authorization: Bearer ${SLACK_API_TOKEN}" \
        -F filename="${file_name}" \
        -F length="${file_size}" \
        "https://slack.com/api/files.getUploadURLExternal")

    local upload_url
    upload_url=$(echo "${response}" | jq -r '.upload_url')
    local file_id
    file_id=$(echo "${response}" | jq -r '.file_id')

    curl -s \
        -H "Authorization: Bearer ${SLACK_API_TOKEN}" \
        -F file=@"${_filename_final}" \
        "${upload_url}"

    local json_body
    json_body=$(jq -n \
        --arg id "${file_id}" \
        --arg title "${file_name}" \
        --arg channel "${SLACK_API_TOKEN}" \
        '[{id: $id, title: $title}]')

    curl -s \
        -H "Authorization: Bearer ${SLACK_API_TOKEN}" \
        -F channel_id="${SLACK_CHANNEL}" \
        -F files="${json_body}" \
        "https://slack.com/api/files.completeUploadExternal"
}

##########

check_num_backups

# Uncomment the following lines if you need to stop and start services
# stop_services

copy_filesystem

# Uncomment the following lines if you need to start services after stopping them
# start_services

compress_and_archive

send_message_to_slack
