#!/bin/bash
set -euo pipefail

# ====================================================================
# Enhanced Multi-VM Manager (QEMU/Cloud-init)
# This script manages QEMU VMs using cloud-init images and user-defined
# configurations, allowing for easy creation, starting, stopping, and 
# configuration of lightweight virtual environments.
#
# NOTE: To run this in a Docker or CodeSandbox environment, the host 
# system must support nested virtualization and the container must 
# have QEMU, KVM access (/dev/kvm), and necessary utilities installed.
# ====================================================================

# Function to display header
display_header() {
    clear
    cat << "EOF"
========================================================================
  _   _  ____  _____ _____ _  _  _____ ____    ______      ________
 | |  | |/ __ \|  __ \_  _|\ | |/ ____|  _ \ / __ \ \    / /___  /
 | |__| | |  | | |__) || | | \| | |  __| |_) | |  | \ \_/ /   / / 
 |  __  | |  | |  ___/ | | |  \ | | |_ |  _ <| |  | |\  /   / /  
 | |  | | |__| | |   _| |_| |\  | |__| | |_) | |__| | | |   / /__ 
 |_|  |_|\____/|_|  |_____|_| \_|\_____|____/ \____/  |_|  /_____|
                                                                
                          POWERED BY HOPINGBOYZ
========================================================================
EOF
    echo
}

# Function to display colored output
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

# Function to validate various inputs (number, size, port, name, username)
validate_input() {
    local type=$1
    local value=$2
    
    case $type in
        "number")
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                print_status "ERROR" "Must be a number."
                return 1
            fi
            ;;
        "size")
            if ! [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
                print_status "ERROR" "Must be a size with unit (e.g., 100G, 512M)."
                return 1
            fi
            ;;
        "port")
            # Ports 1-1023 are privileged, 22 is default SSH. Using 1024-65535 range for host forwarding.
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1024 ] || [ "$value" -gt 65535 ]; then
                print_status "ERROR" "Must be a valid host port number (1024-65535)."
                return 1
            fi
            ;;
        "name")
            if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                print_status "ERROR" "VM name can only contain letters, numbers, hyphens, and underscores."
                return 1
            fi
            ;;
        "username")
            # Standard Unix username pattern
            if ! [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                print_status "ERROR" "Username must start with a letter or underscore, and contain only lowercase letters, numbers, hyphens, and underscores."
                return 1
            fi
            ;;
    esac
    return 0
}

# Function to check required system dependencies
check_dependencies() {
    local deps=("qemu-system-x86_64" "wget" "cloud-localds" "qemu-img" "openssl")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_status "ERROR" "Missing essential dependencies: ${missing_deps[*]}"
        print_status "INFO" "Please install these packages (e.g., on Debian/Ubuntu: sudo apt install qemu-system cloud-image-utils wget openssl iproute2)."
        exit 1
    fi
}

# Function to cleanup temporary cloud-init files
cleanup() {
    if [ -f "user-data" ]; then rm -f "user-data"; fi
    if [ -f "meta-data" ]; then rm -f "meta-data"; fi
}

# Function to get all VM configuration names
get_vm_list() {
    find "$VM_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

# Function to load VM configuration from file
load_vm_config() {
    local vm_name=$1
    local config_file="$VM_DIR/$vm_name.conf"
    
    if [[ -f "$config_file" ]]; then
        # Clear previous variables
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
        unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED
        
        # Load configuration
        source "$config_file"
        return 0
    else
        print_status "ERROR" "Configuration for VM '$vm_name' not found at $config_file"
        return 1
    fi
}

# Function to save VM configuration to file
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
    
    print_status "SUCCESS" "Configuration saved to $config_file"
}

# Function to setup the VM image and cloud-init seed
setup_vm_image() {
    print_status "INFO" "Downloading and preparing image..."
    
    # Create VM directory if it doesn't exist
    mkdir -p "$VM_DIR"
    
    # --- 1. Image Download/Check ---
    if [[ -f "$IMG_FILE" ]]; then
        print_status "INFO" "Base image file already exists ($IMG_FILE). Skipping download."
    else
        print_status "INFO" "Downloading image from $IMG_URL..."
        if ! wget --progress=bar:force "$IMG_URL" -O "$IMG_FILE.tmp"; then
            print_status "ERROR" "Failed to download image from $IMG_URL"
            exit 1
        fi
        mv "$IMG_FILE.tmp" "$IMG_FILE"
    fi
    
    # --- 2. Disk Resize ---
    print_status "INFO" "Resizing disk image to $DISK_SIZE..."
    # Note: qemu-img resize only increases the capacity; the guest OS still needs to expand the filesystem.
    if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE"; then
        print_status "WARN" "Failed to resize disk image. Proceeding with current image size."
    fi

    # --- 3. Cloud-init Configuration (User Data) ---
    print_status "INFO" "Creating cloud-init user data..."
    cat > user-data <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    # Hash password using OpenSSL passwd -6 (SHA-512)
    password: $(openssl passwd -6 "$PASSWORD" | tr -d '\n')
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false

# For persistent disk resizing on first boot
growpart:
  mode: auto
  devices: ['/']
EOF

    # --- 4. Cloud-init Configuration (Meta Data) ---
    cat > meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF

    # --- 5. Create Cloud-init Seed ISO ---
    if ! cloud-localds "$SEED_FILE" user-data meta-data; then
        print_status "ERROR" "Failed to create cloud-init seed image"
        exit 1
    fi
    
    print_status "SUCCESS" "VM '$VM_NAME' image and seed prepared successfully."
}

# Function to create a new VM
create_new_vm() {
    print_status "INFO" "Starting new VM creation wizard."
    
    # 1. OS Selection
    print_status "INFO" "Select an OS image to set up:"
    local os_options=()
    local i=1
    for os in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $os"
        os_options[$i]="$os"
        ((i++))
    done
    
    while true; do
        read -p "$(print_status "INPUT" "Enter your choice (1-${#OS_OPTIONS[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#OS_OPTIONS[@]} ]; then
            local os="${os_options[$choice]}"
            # Parse OS details: OS_TYPE|CODENAME|IMG_URL|DEFAULT_HOSTNAME|DEFAULT_USERNAME|DEFAULT_PASSWORD
            IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$os]}"
            break
        else
            print_status "ERROR" "Invalid selection. Try again."
        fi
    done

    # 2. Custom Inputs with validation
    while true; do
        read -p "$(print_status "INPUT" "Enter VM name (default: $DEFAULT_HOSTNAME): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        if validate_input "name" "$VM_NAME"; then
            if [[ -f "$VM_DIR/$VM_NAME.conf" ]]; then
                print_status "ERROR" "VM with name '$VM_NAME' already exists."
            else
                break
            fi
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        if validate_input "name" "$HOSTNAME"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter username (default: $DEFAULT_USERNAME): ")" USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
        if validate_input "username" "$USERNAME"; then
            break
        fi
    done

    while true; do
        read -s -p "$(print_status "INPUT" "Enter password (default: $DEFAULT_PASSWORD, shown as ****): ")" PASSWORD
        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
        echo
        if [ -n "$PASSWORD" ]; then
            break
        else
            print_status "ERROR" "Password cannot be empty."
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Disk size (default: 20G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"
        if validate_input "size" "$DISK_SIZE"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Memory in MB (default: 2048): ")" MEMORY
        MEMORY="${MEMORY:-2048}"
        if validate_input "number" "$MEMORY"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Number of CPUs (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        if validate_input "number" "$CPUS"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "SSH Host Port (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        if validate_input "port" "$SSH_PORT"; then
            # Check if port is already in use by any service
            if command -v ss &> /dev/null && ss -tln 2>/dev/null | grep -q ":$SSH_PORT "; then
                print_status "ERROR" "Port $SSH_PORT is already in use by another process."
            else
                break
            fi
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enable GUI mode? (y/n, default: n): ")" gui_input
        GUI_MODE=false
        gui_input="${gui_input:-n}"
        if [[ "$gui_input" =~ ^[Yy]$ ]]; then  
            GUI_MODE=true
            break
        elif [[ "$gui_input" =~ ^[Nn]$ ]]; then
            break
        else
            print_status "ERROR" "Please answer y or n."
        fi
    done

    read -p "$(print_status "INPUT" "Additional port forwards (e.g., 8080:80, press Enter for none): ")" PORT_FORWARDS

    # Finalize file paths and metadata
    IMG_FILE="$VM_DIR/$VM_NAME.qcow2" # Renaming to .qcow2 for clarity
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"

    # Download and setup VM image, and create cloud-init ISO
    setup_vm_image
    
    # Save configuration
    save_vm_config
}

# Function to start a VM
start_vm() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        print_status "INFO" "Starting VM: $vm_name"
        print_status "INFO" "Connection Info: ssh -p $SSH_PORT $USERNAME@localhost"
        print_status "INFO" "Password: $PASSWORD"
        
        if [[ ! -f "$IMG_FILE" ]]; then
            print_status "ERROR" "VM image file not found: $IMG_FILE. Cannot start."
            return 1
        fi
        
        # Ensure seed file is present (or re-create it if config changed)
        if [[ ! -f "$SEED_FILE" ]]; then
            print_status "WARN" "Seed file not found, recreating..."
            setup_vm_image
        fi
        
        # Base QEMU command construction
        local qemu_cmd=(
            qemu-system-x86_64
            -enable-kvm
            -name "$VM_NAME"
            -m "$MEMORY"
            -smp "$CPUS"
            -cpu host
            -drive "file=$IMG_FILE,format=qcow2,if=virtio"
            -drive "file=$SEED_FILE,format=raw,if=virtio"
            -boot order=c
            -device virtio-net-pci,netdev=n0
            -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22"
        )

        # Add additional port forwards
        if [[ -n "$PORT_FORWARDS" ]]; then
            IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
            local netdev_idx=1
            for forward in "${forwards[@]}"; do
                IFS=':' read -r host_port guest_port <<< "$forward"
                # Add hostfwd to the primary netdev (n0) - simplifying the networking
                qemu_cmd[$((${#qemu_cmd[@]}-1))]+=",hostfwd=tcp::$host_port-:$guest_port"
                print_status "INFO" "Forwarding Host:$host_port to Guest:$guest_port"
            done
        fi

        # Add GUI or console mode
        if [[ "$GUI_MODE" == true ]]; then
            qemu_cmd+=(-vga virtio -display gtk,gl=on)
        else
            # For console/headless mode
            qemu_cmd+=(-nographic -serial mon:stdio)
        fi

        # Add performance and general device enhancements
        qemu_cmd+=(
            -device virtio-balloon-pci
            -object rng-random,filename=/dev/urandom,id=rng0
            -device virtio-rng-pci,rng=rng0
            -daemonize # Run QEMU in the background
        )

        print_status "INFO" "Starting QEMU process in the background..."
        "${qemu_cmd[@]}"

        # Wait a moment for QEMU to start and check PID
        sleep 2
        if is_vm_running "$vm_name"; then
             print_status "SUCCESS" "VM $vm_name started successfully (PID: $(pgrep -f "qemu-system-x86_64.*$IMG_FILE"))."
             print_status "INFO" "Run 'ssh -p $SSH_PORT $USERNAME@localhost' to connect."
        else
            print_status "ERROR" "Failed to start VM $vm_name. Check QEMU logs (if available)."
        fi
    fi
}

# Function to check if VM is running
is_vm_running() {
    local vm_name=$1
    # Check for the running process using the unique image file path
    if pgrep -f "qemu-system-x86_64.*$VM_DIR/$vm_name.qcow2" >/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to stop a running VM (graceful shutdown not easily possible in user mode, so we use pkill)
stop_vm() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        if is_vm_running "$vm_name"; then
            local qemu_pid=$(pgrep -f "qemu-system-x86_64.*$IMG_FILE")
            print_status "INFO" "Stopping VM: $vm_name (PID: $qemu_pid)"
            
            # Attempt graceful stop (SIGTERM)
            pkill -TERM -f "qemu-system-x86_64.*$IMG_FILE"
            sleep 3
            
            if is_vm_running "$vm_name"; then
                print_status "WARN" "VM did not stop gracefully, forcing termination (SIGKILL)..."
                pkill -KILL -f "qemu-system-x86_64.*$IMG_FILE"
            fi
            
            # Final check
            sleep 1
            if ! is_vm_running "$vm_name"; then
                 print_status "SUCCESS" "VM $vm_name stopped successfully."
            else
                 print_status "ERROR" "Failed to stop VM $vm_name."
            fi
        else
            print_status "INFO" "VM $vm_name is not running."
        fi
    fi
}

# Function to delete a VM
delete_vm() {
    local vm_name=$1
    
    # Ensure VM is stopped before deletion
    if is_vm_running "$vm_name"; then
        print_status "ERROR" "VM '$vm_name' is running. Please stop it first (Option 3)."
        return 1
    fi

    print_status "WARN" "This will permanently delete VM '$vm_name' and all its data!"
    read -p "$(print_status "INPUT" "Are you sure? (y/N): ")" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if load_vm_config "$vm_name"; then
            rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm_name.conf"
            print_status "SUCCESS" "VM '$vm_name' has been deleted."
        fi
    else
        print_status "INFO" "Deletion cancelled."
    fi
}

# Function to show VM info
show_vm_info() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        local status_text="Stopped"
        if is_vm_running "$vm_name"; then
            status_text="Running (PID: $(pgrep -f "qemu-system-x86_64.*$IMG_FILE"))"
        fi
        
        echo
        print_status "INFO" "VM Information: $vm_name"
        echo "=========================================="
        echo "Status: $status_text"
        echo "OS: $OS_TYPE ($CODENAME)"
        echo "Hostname: $HOSTNAME"
        echo "Username: $USERNAME"
        echo "Password: $PASSWORD"
        echo "SSH Port (Host->Guest 22): $SSH_PORT"
        echo "Memory: $MEMORY MB"
        echo "CPUs: $CPUS"
        echo "Disk: $DISK_SIZE"
        echo "GUI Mode: $GUI_MODE"
        echo "Port Forwards: ${PORT_FORWARDS:-None}"
        echo "Created: $CREATED"
        echo "Image File: $IMG_FILE"
        echo "Seed File: $SEED_FILE"
        echo "=========================================="
        echo
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

# Function to show VM performance metrics
show_vm_performance() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        echo
        print_status "INFO" "Performance metrics for VM: $vm_name"
        echo "=========================================="
        
        if is_vm_running "$vm_name"; then
            local qemu_pid=$(pgrep -f "qemu-system-x86_64.*$IMG_FILE" | head -n 1) # Get the main process PID
            
            if [[ -n "$qemu_pid" ]]; then
                # Show process stats (CPU%, MEM%, VSZ, RSS)
                print_status "INFO" "QEMU Process Stats (PID: $qemu_pid):"
                ps -p "$qemu_pid" -o pid,%cpu,%mem,rss,vsz,cmd --no-headers
                echo
                
                # Show VM image disk usage
                print_status "INFO" "Disk File Size:"
                du -h "$IMG_FILE"
            else
                print_status "ERROR" "Could not find a running QEMU process for VM $vm_name."
            fi
        else
            print_status "INFO" "VM $vm_name is not running."
            print_status "INFO" "Configuration Summary:"
            echo "  Memory: $MEMORY MB | CPUs: $CPUS | Disk: $DISK_SIZE"
        fi
        echo "=========================================="
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

# Function to edit VM configuration (excluding OS/Image parameters)
edit_vm_config() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        print_status "INFO" "Editing VM: $vm_name"
        local config_changed=false
        
        # Display current values for clarity
        show_vm_info "$vm_name"
        
        while true; do
            echo "What would you like to edit?"
            echo "  1) Hostname (Current: $HOSTNAME)"
            echo "  2) Username (Current: $USERNAME)"
            echo "  3) Password"
            echo "  4) SSH Port (Host->Guest 22, Current: $SSH_PORT)"
            echo "  5) GUI Mode (Current: $GUI_MODE)"
            echo "  6) Port Forwards (Current: ${PORT_FORWARDS:-None})"
            echo "  7) Memory (RAM) (Current: $MEMORY MB)"
            echo "  8) CPU Count (Current: $CPUS)"
            echo "  9) Disk Size (Current: $DISK_SIZE) - **This requires external partition resizing**"
            echo "  0) Done editing / Back to main menu"
            
            read -p "$(print_status "INPUT" "Enter your choice: ")" edit_choice
            
            case $edit_choice in
                1)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new hostname: ")" new_hostname
                        new_hostname="${new_hostname:-$HOSTNAME}"
                        if validate_input "name" "$new_hostname"; then
                            if [[ "$HOSTNAME" != "$new_hostname" ]]; then config_changed=true; fi
                            HOSTNAME="$new_hostname"
                            break
                        fi
                    done
                    ;;
                2)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new username: ")" new_username
                        new_username="${new_username:-$USERNAME}"
                        if validate_input "username" "$new_username"; then
                            if [[ "$USERNAME" != "$new_username" ]]; then config_changed=true; fi
                            USERNAME="$new_username"
                            break
                        fi
                    done
                    ;;
                3)
                    while true; do
                        read -s -p "$(print_status "INPUT" "Enter new password: ")" new_password
                        new_password="${new_password:-$PASSWORD}"
                        echo
                        if [ -n "$new_password" ]; then
                            if [[ "$PASSWORD" != "$new_password" ]]; then config_changed=true; fi
                            PASSWORD="$new_password"
                            break
                        else
                            print_status "ERROR" "Password cannot be empty."
                        fi
                    done
                    ;;
                4)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new SSH port (Host->Guest 22): ")" new_ssh_port
                        new_ssh_port="${new_ssh_port:-$SSH_PORT}"
                        if validate_input "port" "$new_ssh_port"; then
                             if [[ "$SSH_PORT" != "$new_ssh_port" ]]; then 
                                if command -v ss &> /dev/null && ss -tln 2>/dev/null | grep -q ":$new_ssh_port "; then
                                    print_status "ERROR" "Port $new_ssh_port is already in use."
                                    continue
                                fi
                                SSH_PORT="$new_ssh_port"
                                config_changed=true
                            fi
                            break
                        fi
                    done
                    ;;
                5)
                    while true; do
                        read -p "$(print_status "INPUT" "Enable GUI mode? (y/n): ")" gui_input
                        gui_input="${gui_input:-}"
                        if [[ "$gui_input" =~ ^[Yy]$ ]]; then  
                            if [[ "$GUI_MODE" != "true" ]]; then config_changed=true; fi
                            GUI_MODE=true
                            break
                        elif [[ "$gui_input" =~ ^[Nn]$ ]]; then
                            if [[ "$GUI_MODE" != "false" ]]; then config_changed=true; fi
                            GUI_MODE=false
                            break
                        elif [ -z "$gui_input" ]; then
                            break
                        else
                            print_status "ERROR" "Please answer y or n."
                        fi
                    done
                    ;;
                6)
                    read -p "$(print_status "INPUT" "Additional port forwards (e.g., 8080:80, current: ${PORT_FORWARDS:-None}): ")" new_port_forwards
                    if [[ "$PORT_FORWARDS" != "$new_port_forwards" ]]; then config_changed=true; fi
                    PORT_FORWARDS="${new_port_forwards:-$PORT_FORWARDS}"
                    ;;
                7)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new memory in MB: ")" new_memory
                        new_memory="${new_memory:-$MEMORY}"
                        if validate_input "number" "$new_memory"; then
                            if [[ "$MEMORY" != "$new_memory" ]]; then config_changed=true; fi
                            MEMORY="$new_memory"
                            break
                        fi
                    done
                    ;;
                8)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new CPU count: ")" new_cpus
                        new_cpus="${new_cpus:-$CPUS}"
                        if validate_input "number" "$new_cpus"; then
                            if [[ "$CPUS" != "$new_cpus" ]]; then config_changed=true; fi
                            CPUS="$new_cpus"
                            break
                        fi
                    done
                    ;;
                9)
                    # For simplicity, resize disk is handled by separate menu option 7, but we can update the config value here.
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new disk size (e.g., 50G) - will only update config: ")" new_disk_size
                        new_disk_size="${new_disk_size:-$DISK_SIZE}"
                        if validate_input "size" "$new_disk_size"; then
                            if [[ "$DISK_SIZE" != "$new_disk_size" ]]; then config_changed=true; fi
                            DISK_SIZE="$new_disk_size"
                            break
                        fi
                    done
                    ;;
                0)
                    if $config_changed; then
                        read -p "$(print_status "INPUT" "Save changes before exiting? (Y/n): ")" save_reply
                        save_reply="${save_reply:-y}"
                        if [[ "$save_reply" =~ ^[Yy]$ ]]; then
                            # Recreate seed image if user credentials changed
                            if [[ "$edit_choice" -le 3 ]]; then
                                print_status "INFO" "Updating cloud-init configuration..."
                                setup_vm_image
                            fi
                            save_vm_config
                        fi
                    fi
                    return 0
                    ;;
                *)
                    print_status "ERROR" "Invalid selection. Please choose a number from the menu."
                    continue
                    ;;
            esac
            
            # Since the user made a change, let's save and continue editing
            if $config_changed; then
                # Only need to regenerate cloud-init seed if user/pass/hostname changed
                if [[ "$edit_choice" -le 3 ]]; then
                    print_status "INFO" "Updating cloud-init configuration..."
                    setup_vm_image
                fi
                
                save_vm_config
                print_status "SUCCESS" "Configuration updated. Remember to stop and start the VM for settings to take effect."
                config_changed=false # Reset flag after saving
            fi
            
            read -p "$(print_status "INPUT" "Press Enter to continue editing...")"
        done
    fi
}

# Function to resize VM disk
resize_vm_disk() {
    local vm_name=$1
    
    if is_vm_running "$vm_name"; then
        print_status "ERROR" "VM '$vm_name' is running. Please stop it before resizing the disk."
        return 1
    fi
    
    if load_vm_config "$vm_name"; then
        print_status "INFO" "Current configured disk size: $DISK_SIZE"
        
        while true; do
            read -p "$(print_status "INPUT" "Enter new disk size (e.g., 50G): ")" new_disk_size
            if validate_input "size" "$new_disk_size"; then
                if [[ "$new_disk_size" == "$DISK_SIZE" ]]; then
                    print_status "INFO" "New disk size is the same as current size. No changes made."
                    return 0
                fi
                
                print_status "INFO" "Resizing disk image file ($IMG_FILE) to $new_disk_size..."
                
                # Resize the disk image file
                if qemu-img resize "$IMG_FILE" "$new_disk_size"; then
                    # Update configuration on success
                    DISK_SIZE="$new_disk_size"
                    save_vm_config
                    print_status "SUCCESS" "Disk image file resized successfully to $new_disk_size"
                    print_status "WARN" "You must manually expand the filesystem inside the guest OS on next boot using 'sudo growpart /dev/vda 1' and 'sudo resize2fs /dev/vda1' or equivalent."
                else
                    print_status "ERROR" "Failed to resize disk image file. Check QEMU output."
                    return 1
                fi
                break
            fi
        done
    fi
}

# Main menu function
main_menu() {
    while true; do
        display_header
        
        local vms=($(get_vm_list))
        local vm_count=${#vms[@]}
        
        if [ $vm_count -gt 0 ]; then
            print_status "INFO" "VM List:"
            for i in "${!vms[@]}"; do
                local vm_name="${vms[$i]}"
                local status="Stopped"
                if is_vm_running "$vm_name"; then
                    status="Running"
                fi
                printf "  %2d) %-20s (%s)\n" $((i+1)) "$vm_name" "$status"
            done
            echo
        fi
        
        echo "Main Menu Options:"
        echo "  1) Create a new VM"
        if [ $vm_count -gt 0 ]; then
            echo "--- VM Operations ---"
            echo "  2) Start a VM"
            echo "  3) Stop a VM"
            echo "  4) Show VM Info"
            echo "  5) Edit VM Configuration"
            echo "  6) Delete a VM"
            echo "  7) Resize VM Disk Image"
            echo "  8) Show VM Performance (if running)"
        fi
        echo "  0) Exit"
        echo
        
        read -p "$(print_status "INPUT" "Enter your choice: ")" choice
        
        # Helper function to get selected VM name
        select_vm() {
            local vm_num=$1
            if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                echo "${vms[$((vm_num-1))]}"
                return 0
            else
                print_status "ERROR" "Invalid VM number selection."
                return 1
            fi
        }

        case $choice in
            1)
                create_new_vm
                ;;
            2|3|4|5|6|7|8)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number (1-$vm_count): ")" vm_num
                    local selected_vm=$(select_vm "$vm_num")
                    if [ -n "$selected_vm" ]; then
                        case $choice in
                            2) start_vm "$selected_vm" ;;
                            3) stop_vm "$selected_vm" ;;
                            4) show_vm_info "$selected_vm" ;;
                            5) edit_vm_config "$selected_vm" ;;
                            6) delete_vm "$selected_vm" ;;
                            7) resize_vm_disk "$selected_vm" ;;
                            8) show_vm_performance "$selected_vm" ;;
                        esac
                    fi
                else
                    print_status "WARN" "No VMs created yet. Select option 1 to create one."
                fi
                ;;
            0)
                print_status "INFO" "Exiting VM Manager. Goodbye!"
                exit 0
                ;;
            *)
                print_status "ERROR" "Invalid option."
                ;;
        esac
        
        read -p "$(print_status "INPUT" "Press Enter to return to main menu...")"
    done
}

# --- Initialization ---

# Set trap to cleanup temporary files on exit
trap cleanup EXIT

# Check dependencies
check_dependencies

# Initialize paths (VM_DIR defaults to $HOME/vms)
VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

# Supported OS list: OS_TYPE|CODENAME|IMG_URL|DEFAULT_HOSTNAME|DEFAULT_USERNAME|DEFAULT_PASSWORD
declare -A OS_OPTIONS=(
    ["Ubuntu 22.04 LTS (Jammy)"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04 LTS (Noble)"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Debian 12 (Bookworm)"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
    ["Fedora 40 Cloud Base"]="fedora|40|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2|fedora40|fedora|fedora"
    ["Rocky Linux 9 GenericCloud"]="rockylinux|9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|rocky9|rocky|rocky"
)

# Start the main menu interface
main_menu
