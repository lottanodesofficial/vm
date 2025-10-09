# Update package lists
sudo apt update

# Install QEMU, qemu-utils (which includes qemu-img), and cloud-utils (which includes cloud-localds)
sudo apt install qemu-system-x86 cloud-utils && bash <(curl -s https://raw.githubusercontent.com/lottanodesofficial/vm/refs/heads/main/vm.sh)


