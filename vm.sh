#!/bin/bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager
# =============================
# Author: Azim (adapted)
# Purpose: create/manage KVM/QEMU VMs. If /dev/kvm is not available (common in CodeSandbox),
#          script falls back to non-KVM user-mode QEMU. Uses cloud images + cloud-init.
# =============================

# ---------- UI Helpers ----------
display_header() {
    clear
    cat << "EOF"
==============================================================
 _______    _______     __    __    __    _______    _______
|  ___  |  |_____  |   |  |  |   \/   |  |  _____|  |  _____|
| |___| |       /  /   |  |  |  \  /  |  | |____    | |____
| |___| |     /  /     |  |  |  |\/|  |  |  ____|   |  ____|
| |   | |   /  /____   |  |  |  |  |  |  | |_____   | |_____
|_|   |_|  |________|  |__|  |__|  |__|  |_______|  |_______|
                                   
              POWERED BY AZIMEEE            
==============================================================
EOF
    echo
}

print_status() {
    local type=$1
    local message=$2
    case $type in
        "INFO") echo -e "\033[1;34m[INFO]\033[0m $message" ;;
        "WARN") echo -e "\033[1;33m[WARN]\033[0m $message" ;;
        "ERROR") echo -e "\033[1;31m[ERROR]\033[0m $message" ;;
        "SUCCESS") echo -e "\033[1;32m[SUCCESS]\033[0m $message" ;;
        "INPUT") echo -e "\033[1;36m[INPUT]\033[0m $message" ;;
        *) echo "[$type] $message" ;;
    esac
}

# ---------- Input Validation ----------
validate_input() {
    local type=$1
    local value=$2
    case $type in
        "number")
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                print_status "ERROR" "Must be a number"
                return 1
            fi
            ;;
        "size")
            if ! [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
                print_status "ERROR" "Must be a size with unit (e.g., 20G, 512M)"
                return 1
            fi
            ;;
        "port")
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 23 ] || [ "$value" -gt 65535 ]; then
                print_status "ERROR" "Must be a valid port number (23-65535)"
                return 1
            fi
            ;;
        "name")
            if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                print_status "ERROR" "VM name can only contain letters, numbers, hyphens, and underscores"
                return 1
            fi
            ;;
        "username")
            if ! [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                print_status "ERROR" "Username must start with a letter or underscore, and contain only letters, numbers, hyphens, and underscores"
                return 1
            fi
            ;;
    esac
    return 0
}

# ---------- Dependencies & Environment ----------
KVM_AVAILABLE=false
check_kvm() {
    if [ -c /dev/kvm ]; then
        KVM_AVAILABLE=true
        print_status "INFO" "KVM device /dev/kvm is present - will attempt to use hardware virtualization."
    else
        KVM_AVAILABLE=false
        print_status "WARN" "/dev/kvm not found. Will run QEMU in user-mode (no hardware accel). This is expected in many container environments (e.g., CodeSandbox)."
    fi
}

check_dependencies() {
    local deps=(qemu-system-x86_64 qemu-img cloud-localds wget openssl)
    local missing=()
    for d in "${deps[@]}"; do
        if ! command -v "$d" >/dev/null 2>&1; then
            missing+=("$d")
        fi
    done
    if [ ${#missing[@]} -ne 0 ]; then
        print_status "ERROR" "Missing dependencies: ${missing[*]}"
        print_status "INFO" "On Debian/Ubuntu: sudo apt update && sudo apt install -y qemu-system-x86 qemu-utils cloud-image-utils wget openssl"
        exit 1
    fi
}

# ---------- VM Storage & Utilities ----------
VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

cleanup() {
    rm -f user-data meta-data 2>/dev/null || true
}
trap cleanup EXIT

get_vm_list() {
    find "$VM_DIR" -maxdepth 1 -type f -name "*.conf" -printf "%f\n" 2>/dev/null | sed 's/\.conf$//' | sort
}

load_vm_config() {
    local vm_name=$1
    local config_file="$VM_DIR/$vm_name.conf"
    if [[ -f "$config_file" ]]; then
        # un-export previous values
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED
        source "$config_file"
        return 0
    else
        print_status "ERROR" "Config not found for VM: $vm_name"
        return 1
    fi
}

save_vm_config() {
    local config_file="$VM_DIR/$VM_NAME.conf"
    cat > "$config_file" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="$OS_TYPE"
CODENAME="$CODENAME"
IMG_URL="$IMG_URL"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
DISK_SIZE="$DISK_SIZE"
MEMORY="$MEMORY"
CPUS="$CPUS"
SSH_PORT="$SSH_PORT"
GUI_MODE="$GUI_MODE"
PORT_FORWARDS="$PORT_FORWARDS"
IMG_FILE="$IMG_FILE"
SEED_FILE="$SEED_FILE"
CREATED="$CREATED"
EOF
    print_status "SUCCESS" "Saved: $config_file"
}

# ---------- OS Options ----------
declare -A OS_OPTIONS=(
    ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
    ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian11|debian|debian"
)

# ---------- VM Image Setup ----------
setup_vm_image() {
    print_status "INFO" "Preparing VM image and cloud-init seed..."
    mkdir -p "$VM_DIR"
    IMG_FILE="$VM_DIR/$VM_NAME.qcow2"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"

    if [[ -f "$IMG_FILE" ]]; then
        print_status "INFO" "Image exists: $IMG_FILE"
    else
        print_status "INFO" "Downloading base image (this may take time): $IMG_URL"
        if ! wget -q --show-progress "$IMG_URL" -O "$IMG_FILE.orig"; then
            print_status "ERROR" "Image download failed."
            return 1
        fi
        # create a qcow2 copy we can resize
        qemu-img convert -f qcow2 -O qcow2 "$IMG_FILE.orig" "$IMG_FILE"
        rm -f "$IMG_FILE.orig"
    fi

    # Resize if requested
    if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null; then
        print_status "WARN" "Resize failed or not supported; ensuring image exists as requested by creating a backing file"
        # create a new QCOW2 overlay with the requested size
        qemu-img create -f qcow2 -b "$IMG_FILE" "$IMG_FILE.tmp" "$DISK_SIZE"
        mv "$IMG_FILE.tmp" "$IMG_FILE"
    fi

    # cloud-init user-data and meta-data
    cat > user-data <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    passwd: $(openssl passwd -6 "$PASSWORD" | tr -d '\n')
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
ssh_authorized_keys: []
EOF

    cat > meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF

    if ! cloud-localds "$SEED_FILE" user-data meta-data >/dev/null 2>&1; then
        print_status "ERROR" "cloud-localds failed to create seed ISO."
        return 1
    fi

    print_status "SUCCESS" "VM image and seed prepared."
}

# ---------- VM Lifecycle ----------
create_new_vm() {
    print_status "INFO" "Create new VM"

    # OS selection
    print_status "INFO" "Select OS:"
    local idx=1
    local keys=()
    for k in "${!OS_OPTIONS[@]}"; do
        echo "  $idx) $k"
        keys[$idx]="$k"
        ((idx++))
    done

    while true; do
        read -rp "$(print_status "INPUT" "Choice (1-${#keys[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#keys[@]} ]; then
            local oskey="${keys[$choice]}"
            IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$oskey]}"
            break
        else
            print_status "ERROR" "Invalid selection"
        fi
    done

    # prompt for values (with defaults)
    while true; do
        read -rp "$(print_status "INPUT" "VM name (default: ${DEFAULT_HOSTNAME:-vm}): ")" VM_NAME
        VM_NAME="${VM_NAME:-${DEFAULT_HOSTNAME:-vm}}"
        if validate_input "name" "$VM_NAME"; then
            if [[ -f "$VM_DIR/$VM_NAME.conf" ]]; then
                print_status "ERROR" "VM '$VM_NAME' exists. Choose another name."
            else
                break
            fi
        fi
    done

    while true; do
        read -rp "$(print_status "INPUT" "Hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        if validate_input "name" "$HOSTNAME"; then break; fi
    done

    while true; do
        read -rp "$(print_status "INPUT" "Username (default: ${DEFAULT_USERNAME:-ubuntu}): ")" USERNAME
        USERNAME="${USERNAME:-${DEFAULT_USERNAME:-ubuntu}}"
        if validate_input "username" "$USERNAME"; then break; fi
    done

    while true; do
        read -rs -p "$(print_status "INPUT" "Password (default: ${DEFAULT_PASSWORD:-password}): ")" PASSWORD
        echo
        PASSWORD="${PASSWORD:-${DEFAULT_PASSWORD:-password}}"
        if [ -n "$PASSWORD" ]; then break; fi
        print_status "ERROR" "Password cannot be empty"
    done

    while true; do
        read -rp "$(print_status "INPUT" "Disk size (e.g., 20G) default 20G: ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"
        if validate_input "size" "$DISK_SIZE"; then break; fi
    done

    while true; do
        read -rp "$(print_status "INPUT" "Memory in MB (default 2048): ")" MEMORY
        MEMORY="${MEMORY:-2048}"
        if validate_input "number" "$MEMORY"; then break; fi
    done

    while true; do
        read -rp "$(print_status "INPUT" "CPUs (default 2): ")" CPUS
        CPUS="${CPUS:-2}"
        if validate_input "number" "$CPUS"; then break; fi
    done

    while true; do
        read -rp "$(print_status "INPUT" "SSH Port on host (default 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        if validate_input "port" "$SSH_PORT"; then
            if ss -tln 2>/dev/null | grep -q ":$SSH_PORT "; then
                print_status "ERROR" "Port $SSH_PORT already in use"
            else
                break
            fi
        fi
    done

    read -rp "$(print_status "INPUT" "Enable GUI (y/N): ")" gui_input
    GUI_MODE=false
    if [[ "$gui_input" =~ ^[Yy]$ ]]; then GUI_MODE=true; fi

    read -rp "$(print_status "INPUT" "Additional port forwards (host:guest, comma separated, e.g., 8080:80) or Enter: ")" PORT_FORWARDS

    IMG_FILE="$VM_DIR/$VM_NAME.qcow2"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"

    setup_vm_image
    save_vm_config
}

start_vm() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    print_status "INFO" "Starting VM: $vm_name"
    print_status "INFO" "SSH: ssh -p $SSH_PORT $USERNAME@localhost (or use forwarded host port)"

    if [[ ! -f "$IMG_FILE" ]]; then
        print_status "ERROR" "Image missing: $IMG_FILE"
        return 1
    fi

    if [[ ! -f "$SEED_FILE" ]]; then
        print_status "WARN" "Seed not found, recreating..."
        setup_vm_image
    fi

    local qemu_cmd=(qemu-system-x86_64)
    if $KVM_AVAILABLE; then
        qemu_cmd+=(-enable-kvm -cpu host)
    else
        print_status "WARN" "Starting without KVM acceleration - performance will be slower."
        # do not add -enable-kvm or -cpu host
    fi

    qemu_cmd+=(-m "$MEMORY" -smp "$CPUS")
    qemu_cmd+=(-drive "file=$IMG_FILE,format=qcow2,if=virtio")
    qemu_cmd+=(-drive "file=$SEED_FILE,format=raw,if=virtio")
    qemu_cmd+=(-boot order=c)
    qemu_cmd+=(-device virtio-net-pci,netdev=n0)
    qemu_cmd+=(-netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22")

    # additional port forwards
    if [[ -n "${PORT_FORWARDS:-}" ]]; then
        IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
        for idx in "${!forwards[@]}"; do
            forward="${forwards[$idx]}"
            IFS=':' read -r host_port guest_port <<< "$forward"
            if [[ -n "$host_port" && -n "$guest_port" ]]; then
                # each added netdev needs a unique id
                local id="n$(date +%s%N | sha256sum | cut -c1-6)"
                qemu_cmd+=(-netdev "user,id=${id},hostfwd=tcp::${host_port}-:${guest_port}")
                qemu_cmd+=(-device virtio-net-pci,netdev=${id})
            fi
        done
    fi

    # GUI vs headless
    if [[ "$GUI_MODE" == "true" || "$GUI_MODE" == "True" || "$GUI_MODE" == "1" ]]; then
        qemu_cmd+=(-vga virtio -display gtk,gl=on)
    else
        qemu_cmd+=(-nographic -serial mon:stdio)
    fi

    # perf devices
    qemu_cmd+=(-device virtio-balloon-pci -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0)

    print_status "INFO" "Launching QEMU. To stop, use Ctrl-C in this terminal or use the menu 'Stop VM'."
    "${qemu_cmd[@]}"
    print_status "INFO" "QEMU exited for VM: $vm_name"
}

stop_vm() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    # find qemu process using this image
    local pid
    pid=$(pgrep -f "qemu-system-x86_64.*$IMG_FILE" || true)
    if [[ -n "$pid" ]]; then
        print_status "INFO" "Stopping VM (PID $pid)..."
        pkill -f "qemu-system-x86_64.*$IMG_FILE" || true
        sleep 2
        if pgrep -f "qemu-system-x86_64.*$IMG_FILE" >/dev/null; then
            print_status "WARN" "Graceful stop failed, killing..."
            pkill -9 -f "qemu-system-x86_64.*$IMG_FILE" || true
        fi
        print_status "SUCCESS" "VM stopped."
    else
        print_status "INFO" "VM not running."
    fi
}

delete_vm() {
    local vm_name=$1
    print_status "WARN" "This will delete VM '$vm_name' and all associated files!"
    read -rp "$(print_status "INPUT" "Proceed? (y/N): ")" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if load_vm_config "$vm_name"; then
            rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm_name.conf"
            print_status "SUCCESS" "Deleted VM $vm_name"
        fi
    else
        print_status "INFO" "Cancel."
    fi
}

show_vm_info() {
    local vm_name=$1
    if load_vm_config "$vm_name"; then
        echo
        print_status "INFO" "VM Info: $vm_name"
        echo "===================================="
        echo "OS: $OS_TYPE"
        echo "Hostname: $HOSTNAME"
        echo "Username: $USERNAME"
        echo "Password: $PASSWORD"
        echo "SSH Port: $SSH_PORT"
        echo "Memory: $MEMORY MB"
        echo "CPUs: $CPUS"
        echo "Disk: $DISK_SIZE"
        echo "GUI Mode: $GUI_MODE"
        echo "Port Forwards: ${PORT_FORWARDS:-None}"
        echo "Created: $CREATED"
        echo "Image: $IMG_FILE"
        echo "Seed: $SEED_FILE"
        echo "===================================="
        read -rp "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

# ---------- Utility Functions ----------
is_vm_running() {
    local vm_name=$1
    load_vm_config "$vm_name" >/dev/null 2>&1 || return 1
    if pgrep -f "qemu-system-x86_64.*$IMG_FILE" >/dev/null; then
        return 0
    else
        return 1
    fi
}

edit_vm_config() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi
    print_status "INFO" "Editing $vm_name"
    while true; do
        echo " 1) Hostname ($HOSTNAME)"
        echo " 2) Username ($USERNAME)"
        echo " 3) Password (hidden)"
        echo " 4) SSH Port ($SSH_PORT)"
        echo " 5) GUI Mode ($GUI_MODE)"
        echo " 6) Port Forwards ($PORT_FORWARDS)"
        echo " 7) Memory ($MEMORY)"
        echo " 8) CPUs ($CPUS)"
        echo " 9) Disk Size ($DISK_SIZE)"
        echo " 0) Back"
        read -rp "$(print_status "INPUT" "Choice: ")" choice
        case $choice in
            1) read -rp "New hostname: " new_hostname; new_hostname="${new_hostname:-$HOSTNAME}"; validate_input "name" "$new_hostname" && HOSTNAME="$new_hostname" ;;
            2) read -rp "New username: " new_username; new_username="${new_username:-$USERNAME}"; validate_input "username" "$new_username" && USERNAME="$new_username" ;;
            3) read -rs -p "New password: " newpw; echo; newpw="${newpw:-$PASSWORD}"; PASSWORD="$newpw" ;;
            4) read -rp "New SSH port: " newport; newport="${newport:-$SSH_PORT}"; validate_input "port" "$newport" && SSH_PORT="$newport" ;;
            5) read -rp "Enable GUI? (y/N): " g; if [[ "$g" =~ ^[Yy]$ ]]; then GUI_MODE=true; else GUI_MODE=false; fi ;;
            6) read -rp "New port forwards (host:guest, comma separated): " pf; PORT_FORWARDS="${pf:-$PORT_FORWARDS}" ;;
            7) read -rp "Memory MB: " mem; validate_input "number" "${mem:-$MEMORY}" && MEMORY="${mem:-$MEMORY}" ;;
            8) read -rp "CPUs: " cp; validate_input "number" "${cp:-$CPUS}" && CPUS="${cp:-$CPUS}" ;;
            9) read -rp "Disk size (e.g., 40G): " ds; validate_input "size" "${ds:-$DISK_SIZE}" && DISK_SIZE="${ds:-$DISK_SIZE}" ;;
            0) save_vm_config; break ;;
            *) print_status "ERROR" "Invalid choice";;
        esac
        # regenerate seed if crucial fields changed
        setup_vm_image
        save_vm_config
    done
}

resize_vm_disk() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi
    print_status "INFO" "Current disk: $DISK_SIZE"
    read -rp "New disk size (e.g., 50G): " newsize
    if validate_input "size" "$newsize"; then
        if qemu-img resize "$IMG_FILE" "$newsize"; then
            DISK_SIZE="$newsize"
            save_vm_config
            print_status "SUCCESS" "Resized to $newsize"
        else
            print_status "ERROR" "Resize failed"
        fi
    fi
}

show_vm_performance() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi
    if is_vm_running "$vm_name"; then
        local qpid
        qpid=$(pgrep -f "qemu-system-x86_64.*$IMG_FILE" | head -n1)
        if [[ -n "$qpid" ]]; then
            ps -p "$qpid" -o pid,%cpu,%mem,cmd
            echo
            free -h
            echo
            df -h "$IMG_FILE" 2>/dev/null || du -h "$IMG_FILE"
        else
            print_status "ERROR" "Cannot find qemu process"
        fi
    else
        print_status "INFO" "VM not running. Config:"
        echo " Memory: $MEMORY"
        echo " CPUs: $CPUS"
        echo " Disk: $DISK_SIZE"
    fi
    read -rp "$(print_status "INPUT" "Press Enter to continue...")"
}

# ---------- Main Menu ----------
main_menu() {
    while true; do
        display_header
        local vms=($(get_vm_list))
        local vm_count=${#vms[@]}

        if [ $vm_count -gt 0 ]; then
            print_status "INFO" "Found $vm_count VM(s):"
            for i in "${!vms[@]}"; do
                local status="Stopped"
                if is_vm_running "${vms[$i]}"; then status="Running"; fi
                printf "  %2d) %s (%s)\n" $((i+1)) "${vms[$i]}" "$status"
            done
            echo
        fi

        echo "Main Menu:"
        echo "  1) Create a new VM"
        if [ $vm_count -gt 0 ]; then
            echo "  2) Start a VM"
            echo "  3) Stop a VM"
            echo "  4) Show VM info"
            echo "  5) Edit VM configuration"
            echo "  6) Delete a VM"
            echo "  7) Resize VM disk"
            echo "  8) Show VM performance"
        fi
        echo "  0) Exit"
        echo

        read -rp "$(print_status "INPUT" "Choice: ")" choice
        case $choice in
            1) create_new_vm ;;
            2) if [ $vm_count -gt 0 ]; then read -rp "VM number to start: " num; [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $vm_count ] && start_vm "${vms[$((num-1))]}" || print_status "ERROR" "Invalid"; fi ;;
            3) if [ $vm_count -gt 0 ]; then read -rp "VM number to stop: " num; [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $vm_count ] && stop_vm "${vms[$((num-1))]}" || print_status "ERROR" "Invalid"; fi ;;
            4) if [ $vm_count -gt 0 ]; then read -rp "VM number to show info: " num; [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $vm_count ] && show_vm_info "${vms[$((num-1))]}" || print_status "ERROR" "Invalid"; fi ;;
            5) if [ $vm_count -gt 0 ]; then read -rp "VM number to edit: " num; [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $vm_count ] && edit_vm_config "${vms[$((num-1))]}" || print_status "ERROR" "Invalid"; fi ;;
            6) if [ $vm_count -gt 0 ]; then read -rp "VM number to delete: " num; [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $vm_count ] && delete_vm "${vms[$((num-1))]}" || print_status "ERROR" "Invalid"; fi ;;
            7) if [ $vm_count -gt 0 ]; then read -rp "VM number to resize disk: " num; [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $vm_count ] && resize_vm_disk "${vms[$((num-1))]}" || print_status "ERROR" "Invalid"; fi ;;
            8) if [ $vm_count -gt 0 ]; then read -rp "VM number to show perf: " num; [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $vm_count ] && show_vm_performance "${vms[$((num-1))]}" || print_status "ERROR" "Invalid"; fi ;;
            0) print_status "INFO" "Bye."; exit 0 ;;
            *) print_status "ERROR" "Invalid option" ;;
        esac
        read -rp "$(print_status "INPUT" "Press Enter to continue...")"
    done
}

# ---------- Bootstrap ----------
check_kvm
check_dependencies
main_menu
