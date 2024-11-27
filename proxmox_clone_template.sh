#!/bin/bash

# Default values
TEMPLATE_ID=100
NUM_CLONES=1
NAME_PREFIX="ubuntu-clone"

# Help function
show_help() {
    echo "Usage: $0 [-n number_of_clones] [-p name_prefix]"
    echo "Options:"
    echo "  -n    Number of clones to create (default: 5)"
    echo "  -p    Prefix for clone names (default: ubuntu-clone)"
    echo "  -h    Show this help message"
    exit 1
}

# Parse command line options
while getopts "n:p:h" opt; do
    case $opt in
        n) NUM_CLONES="$OPTARG";;
        p) NAME_PREFIX="$OPTARG";;
        h) show_help;;
        \?) echo "Invalid option: -$OPTARG" >&2; show_help;;
    esac
done

# Validate number of clones
if ! [[ "$NUM_CLONES" =~ ^[0-9]+$ ]]; then
    echo "Error: Number of clones must be a positive integer"
    exit 1
fi

# Function to find next available VM ID
get_next_vmid() {
    local vmid=100
    while qm status $vmid >/dev/null 2>&1 || [[ -d "/etc/pve/qemu-server/$vmid.conf" ]]; do
        ((vmid++))
    done
    echo $vmid
}

# Create clones
for i in $(seq 0 $((NUM_CLONES-1))); do
    NEW_ID=$(get_next_vmid)
    echo "Creating clone with ID: $NEW_ID"
    qm clone $TEMPLATE_ID $NEW_ID \
        --name "${NAME_PREFIX}-${i}" \
        --full 0
    qm set $NEW_ID --ciuser shuv
    qm set $NEW_ID --ipconfig0 ip=dhcp
    qm set $NEW_ID --sshkeys ~/.ssh/id_rsa_shuv.pub
    # Start the VM after creation (optional)
    qm start $NEW_ID
done
