#!/usr/bin/env bash
set -euo pipefail

# This script automates the process of setting up secrets for the PDS using sops-nix.
# It supports both SSH host keys and dedicated age keys.

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_error() {
  echo -e "${RED}Error: $1${NC}" >&2
}

print_success() {
  echo -e "${GREEN}$1${NC}"
}

print_warning() {
  echo -e "${YELLOW}Warning: $1${NC}"
}

print_info() {
  echo -e "$1"
}

print_blue() {
  echo -e "${BLUE}$1${NC}"
}

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check for dependencies
if ! command_exists sops; then
  print_error "sops is not installed. Please install it before running this script."
  echo "  nix-shell -p sops"
  exit 1
fi

if ! command_exists openssl; then
  print_error "openssl is not installed."
  exit 1
fi

if ! command_exists ssh-to-age; then
    print_error "ssh-to-age is not installed. Install with: nix-shell -p ssh-to-age"
    exit 1
fi

print_blue "=== PDS Secrets Setup Script ==="
print_info ""
print_info "This script will help you set up secrets for your Bluesky PDS."
print_info "You can choose between using SSH host keys or a dedicated age key."
print_info ""

# --- Choose Key Type ---
print_blue "Key Selection:"
print_info "1) Use SSH host key (recommended for NixOS systems)"
print_info "2) Generate new age key (portable, works anywhere)"
print_info ""

SSH_HOST_KEY="/etc/ssh/ssh_host_ed25519_key"
SSH_HOST_KEY_PUB="${SSH_HOST_KEY}.pub"

if [ -f "$SSH_HOST_KEY_PUB" ] && [ -r "$SSH_HOST_KEY_PUB" ]; then
  DEFAULT_CHOICE="1"
  print_success "✓ SSH host key found: $SSH_HOST_KEY_PUB"
else
  DEFAULT_CHOICE="2"
  print_warning "✗ SSH host key not found or not readable"
fi

print_info ""
read -p "Choose key type (1 or 2) [default: $DEFAULT_CHOICE]: " KEY_CHOICE
KEY_CHOICE=${KEY_CHOICE:-$DEFAULT_CHOICE}

AGE_PUBLIC_KEY=""
KEY_TYPE=""

case $KEY_CHOICE in
  1)
    # SSH host key method
    KEY_TYPE="ssh"

    if [ ! -r "$SSH_HOST_KEY_PUB" ]; then
      print_error "Cannot read $SSH_HOST_KEY_PUB. Please run this script with sudo."
      exit 1
    fi

    print_success "\nUsing SSH host key method"
    print_info "Converting SSH host key to age public key..."
    AGE_PUBLIC_KEY=$(ssh-to-age < "$SSH_HOST_KEY_PUB")

    if [ -z "$AGE_PUBLIC_KEY" ]; then
      print_error "Failed to generate age public key from SSH host key"
      exit 1
    fi

    print_success "Age public key: $AGE_PUBLIC_KEY"
    ;;

  2)
    # Age key method
    KEY_TYPE="age"
    AGE_PRIVATE_KEY_FILE="/root/.config/sops/age/keys.txt"

    if ! command_exists age-keygen; then
      print_error "age-keygen is not installed. Install with: nix-shell -p age"
      exit 1
    fi

    print_success "\nUsing dedicated age key method"

    mkdir -p "$(dirname "$AGE_PRIVATE_KEY_FILE")"
    age-keygen -o "$AGE_PRIVATE_KEY_FILE"
    AGE_PUBLIC_KEY=$(age-keygen -y "$AGE_PRIVATE_KEY_FILE")

    print_success "Age private key saved to: $AGE_PRIVATE_KEY_FILE"
    print_success "Age public key: $AGE_PUBLIC_KEY"
    print_warning "IMPORTANT: Back up this file: $AGE_PRIVATE_KEY_FILE"
    ;;

  *)
    print_error "Invalid choice. Please enter 1 or 2."
    exit 1
    ;;
esac

# --- Check if secrets.sops.yaml already exists ---
if [ -f secrets.sops.yaml ]; then
  print_warning "\nsecrets.sops.yaml already exists!"
  read -p "Do you want to overwrite it? (y/N): " -r
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Exiting without changes."
    exit 0
  fi
  # Backup existing file
  BACKUP_FILE="secrets.sops.yaml.backup.$(date +%s)"
  cp secrets.sops.yaml "$BACKUP_FILE"
  print_info "Backed up existing secrets.sops.yaml to $BACKUP_FILE"
fi

# --- Create .sops.yaml configuration ---
print_info "\nCreating .sops.yaml configuration..."
cat > .sops.yaml << EOL
creation_rules:
  - path_regex: secrets.tmp.yaml
    age: $AGE_PUBLIC_KEY
EOL
print_success ".sops.yaml created successfully"


# --- Generate Secrets ---
print_blue "\n=== Generating PDS Secrets ==="

print_info "Generating JWT secret..."
PDS_JWT_SECRET=$(openssl rand -hex 16)

# Get admin password
while true; do
  read -sp "Please enter the admin password: " PDS_ADMIN_PASSWORD
  echo
  if [ -z "$PDS_ADMIN_PASSWORD" ]; then
    print_error "Password cannot be empty"
    continue
  fi
  read -sp "Confirm admin password: " PDS_ADMIN_PASSWORD_CONFIRM
  echo
  if [ "$PDS_ADMIN_PASSWORD" = "$PDS_ADMIN_PASSWORD_CONFIRM" ]; then
    print_success "Password confirmed!"
    break
  else
    print_error "Passwords do not match. Please try again."
  fi
done

print_info "Generating PLC rotation key (secp256k1)..."
PDS_PLC_ROTATION_KEY=$(openssl ecparam -name secp256k1 -genkey -noout -outform DER | tail -c +8 | head -c 32 | xxd -p -c 32)

# Define the database URL
PDS_DATABASE_URL="sqlite:///var/lib/pds/pds.sqlite"

# Get ACME email
while true; do
  read -p "Enter your email for ACME/Let's Encrypt certificates: " ACME_EMAIL
  if [ -z "$ACME_EMAIL" ]; then
    print_error "Email cannot be empty"
    continue
  fi
  # Basic email validation
  if [[ "$ACME_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    print_success "Email validated: $ACME_EMAIL"
    break
  else
    print_error "Invalid email format. Please try again."
  fi
done

# --- Create & Encrypt Secrets File ---
print_info "\nCreating and encrypting secrets file..."

# 1. Create a temporary unencrypted YAML file
cat > secrets.tmp.yaml << EOL
pds_jwt_secret: $PDS_JWT_SECRET
pds_admin_password: $PDS_ADMIN_PASSWORD
pds_plc_rotation_key: $PDS_PLC_ROTATION_KEY
pds_database_url: $PDS_DATABASE_URL
acme_email: $ACME_EMAIL
EOL

# 2. Encrypt the temporary file using the .sops.yaml rules
sops --encrypt secrets.tmp.yaml > secrets.sops.yaml

# 3. Clean up the temporary and config files
rm secrets.tmp.yaml
rm .sops.yaml

print_success "Successfully created secrets.sops.yaml!"

# --- Summary ---
print_blue "\n=== Setup Complete ==="

if [ "$KEY_TYPE" = "ssh" ]; then
  print_info "Your configuration.nix should use:"
  print_info '  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];'
else
  print_info "Your configuration.nix should use:"
  print_info "  sops.age.keyFile = \"$AGE_PRIVATE_KEY_FILE\";"
fi

print_info ""
print_success "Next steps:"
print_info "  1. Verify your sops settings in configuration.nix"
print_info "  2. Run: nixos-rebuild switch --flake .#nixos"
print_info ""
print_info "To view secrets later, run: sops -d secrets.sops.yaml"
