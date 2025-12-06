#!/usr/bin/env bash
set -euo pipefail

# ==============================
# Debian/Ubuntu bootstrap script
# - Creates user (default: jack)
# - Sets password (interactive or env)
# - Optional SSH key
# - System update/upgrade
# - fastfetch installed & wired into shell
# - Common dev packages (git, curl, etc.)
# - Optional Docker install
# - Optional zsh install + basic config
# - Modular features controlled via CLI flags
# ==============================

# -------- Defaults / config --------
USERNAME="jack"
ADD_SUDO="Y"
ADD_SSH="N"

INSTALL_DEV_PACKAGES="Y"
INSTALL_DOCKER="N"
INSTALL_ZSH="N"

INTERACTIVE="Y"

# If running non-interactively, you can set NEWUSER_PASSWORD via env
NEWUSER_PASSWORD="${NEWUSER_PASSWORD:-}"

# -------- Helpers --------
usage() {
    cat <<EOF
Usage: sudo ./setup.sh [options]

Options:
  --user NAME         Username to create/use (default: jack)
  --no-sudo           Do NOT add user to sudo group
  --with-docker       Install Docker and add user to docker group
  --with-zsh          Install zsh and configure it as default shell for the user
  --no-dev            Skip installing common dev packages (git, curl, etc.)
  --non-interactive   Non-interactive mode:
                      - username taken from --user (or default)
                      - password read from \$NEWUSER_PASSWORD
                      - SSH key disabled unless you script it in
  --help              Show this help and exit

Environment:
  NEWUSER_PASSWORD    Password used for the created user when --non-interactive is set.

Examples:
  Interactive, full:
    sudo ./setup.sh

  Non-interactive, with Docker + zsh:
    NEWUSER_PASSWORD='MyS3cret' sudo ./setup.sh --user jack --with-docker --with-zsh --non-interactive

EOF
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This script must be run as root (use sudo)." >&2
        exit 1
    fi
}

check_distro() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID_LIKE:-$ID}" in
            *debian*|*ubuntu* )
                echo "Detected Debian/Ubuntu-like system: ${PRETTY_NAME:-$ID}"
                ;;
            * )
                echo "Warning: This script is intended for Debian/Ubuntu. Detected: ${PRETTY_NAME:-$ID}"
                read -r -p "Continue anyway? [y/N]: " cont
                cont=${cont:-N}
                if [[ ! "$cont" =~ ^[Yy]$ ]]; then
                    echo "Aborting."
                    exit 1
                fi
                ;;
        esac
    else
        echo "Cannot detect OS (no /etc/os-release). Continuing blindly."
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                USERNAME="$2"
                shift 2
                ;;
            --no-sudo)
                ADD_SUDO="N"
                shift
                ;;
            --with-docker)
                INSTALL_DOCKER="Y"
                shift
                ;;
            --with-zsh)
                INSTALL_ZSH="Y"
                shift
                ;;
            --no-dev)
                INSTALL_DEV_PACKAGES="N"
                shift
                ;;
            --non-interactive)
                INTERACTIVE="N"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

prompt_user_info() {
    if [[ "$INTERACTIVE" == "Y" ]]; then
        read -r -p "Enter username to create [${USERNAME}]: " input_user
        USERNAME=${input_user:-$USERNAME}

        if id "$USERNAME" >/dev/null 2>&1; then
            echo "User '$USERNAME' already exists."
            USE_EXISTING="yes"
        else
            USE_EXISTING="no"
        fi

        # Password prompt
        while true; do
            read -s -p "Enter password for user '$USERNAME': " PASSWORD
            echo
            read -s -p "Confirm password: " PASSWORD2
            echo
            if [[ "$PASSWORD" != "$PASSWORD2" ]]; then
                echo "Passwords do not match, try again."
            elif [[ -z "$PASSWORD" ]]; then
                echo "Password must not be empty, try again."
            else
                break
            fi
        done

        read -r -p "Add user '$USERNAME' to sudo group? [Y/n]: " ADD_SUDO_IN
        ADD_SUDO=${ADD_SUDO_IN:-$ADD_SUDO}

        read -r -p "Add an SSH public key for '$USERNAME'? [y/N]: " ADD_SSH_IN
        ADD_SSH=${ADD_SSH_IN:-$ADD_SSH}
    else
        # Non-interactive mode
        if id "$USERNAME" >/dev/null 2>&1; then
            echo "User '$USERNAME' already exists."
            USE_EXISTING="yes"
        else
            USE_EXISTING="no"
        fi

        if [[ -z "${NEWUSER_PASSWORD}" ]]; then
            echo "Non-interactive mode requires NEWUSER_PASSWORD env var."
            exit 1
        fi
        PASSWORD="$NEWUSER_PASSWORD"
        ADD_SSH="N"  # keep ssh key handling manual in non-interactive
    fi
}

create_or_update_user() {
    if [[ "$USE_EXISTING" == "no" ]]; then
        echo "Creating user '$USERNAME'..."
        useradd -m -s /bin/bash "$USERNAME"
    else
        echo "Using existing user '$USERNAME'."
    fi

    echo "Setting password for '$USERNAME'..."
    echo "${USERNAME}:${PASSWORD}" | chpasswd

    if [[ "$ADD_SUDO" =~ ^[Yy]$ ]]; then
        echo "Adding '$USERNAME' to sudo group..."
        if getent group sudo >/dev/null 2>&1; then
            usermod -aG sudo "$USERNAME"
        elif getent group wheel >/dev/null 2>&1; then
            usermod -aG wheel "$USERNAME"
        else
            echo "No sudo/wheel group found. Skipping sudo group membership."
        fi
    fi
}

setup_ssh_key() {
    if [[ ! "$ADD_SSH" =~ ^[Yy]$ ]]; then
        return
    fi

    echo "Paste the SSH public key for '$USERNAME' below."
    echo "End with an empty line."
    SSH_KEY=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        SSH_KEY+="$line"$'\n'
    done

    if [[ -z "${SSH_KEY// }" ]]; then
        echo "No SSH key entered, skipping."
        return
    fi

    USER_HOME=$(eval echo "~$USERNAME")
    SSH_DIR="${USER_HOME}/.ssh"
    AUTH_KEYS="${SSH_DIR}/authorized_keys"

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    printf "%s" "$SSH_KEY" >> "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    chown -R "$USERNAME":"$USERNAME" "$SSH_DIR"

    echo "SSH key added to ${AUTH_KEYS}."
}

system_update() {
    echo "Updating apt package lists..."
    apt-get update -y

    echo "Upgrading existing packages..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

install_fastfetch() {
    echo "Installing fastfetch..."
    if ! apt-get install -y fastfetch; then
        echo "fastfetch package not found in repositories. Skipping installation."
    fi
}

install_common_dev_packages() {
    if [[ "$INSTALL_DEV_PACKAGES" != "Y" ]]; then
        echo "Skipping common dev packages installation."
        return
    fi

    echo "Installing common dev packages (git, curl, wget, vim, build-essential)..."
    apt-get install -y \
        git \
        curl \
        wget \
        vim \
        build-essential \
        ca-certificates \
        gnupg \
        lsb-release
}

install_docker() {
    if [[ "$INSTALL_DOCKER" != "Y" ]]; then
        echo "Skipping Docker installation."
        return
    fi

    echo "Installing Docker (Docker CE) for Debian/Ubuntu..."

    # Remove old versions if any
    apt-get remove -y docker docker-engine docker.io containerd runc || true

    # Set up repository (using official Docker instructions)
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    local codename
    codename=$( . /etc/os-release && echo "$VERSION_CODENAME" )

    echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
 ${codename} stable" > /etc/apt/sources.list.d/docker.list

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    # Add user to docker group
    if getent group docker >/dev/null 2>&1; then
        usermod -aG docker "$USERNAME"
        echo "User '$USERNAME' added to docker group (logout/login required)."
    fi
}

install_zsh_and_configure() {
    if [[ "$INSTALL_ZSH" != "Y" ]]; then
        echo "Skipping zsh installation."
        return
    fi

    echo "Installing zsh..."
    apt-get install -y zsh

    USER_HOME=$(eval echo "~$USERNAME")
    ZSHRC="${USER_HOME}/.zshrc"

    # Minimal zsh config
    if [[ ! -f "$ZSHRC" ]]; then
        cat > "$ZSHRC" <<'EOF'
# Basic zsh config
export HISTFILE=~/.zsh_history
export HISTSIZE=5000
export SAVEHIST=5000

setopt INC_APPEND_HISTORY SHARE_HISTORY
setopt HIST_IGNORE_ALL_DUPS

PROMPT='%F{cyan}%n@%m%f:%F{yellow}%~%f %# '

# Aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Run fastfetch if available
if command -v fastfetch >/dev/null 2>&1; then
    fastfetch
fi

EOF
        chown "$USERNAME":"$USERNAME" "$ZSHRC"
    fi

    echo "Setting zsh as default shell for '$USERNAME'..."
    chsh -s "$(command -v zsh)" "$USERNAME"
}

enable_fastfetch_in_shells() {
    USER_HOME=$(eval echo "~$USERNAME")

    # bash
    BASHRC="${USER_HOME}/.bashrc"
    FASTFETCH_SNIPPET=$'\n# Run fastfetch on interactive login\nif command -v fastfetch >/dev/null 2>&1; then\n    fastfetch\nfi\n'

    if [[ -f "$BASHRC" ]]; then
        if ! grep -q "fastfetch" "$BASHRC" 2>/dev/null; then
            echo "Enabling fastfetch for '$USERNAME' in ${BASHRC}..."
            printf "%s" "$FASTFETCH_SNIPPET" >> "$BASHRC"
            chown "$USERNAME":"$USERNAME" "$BASHRC"
        else
            echo "fastfetch already referenced in ${BASHRC}, not adding again."
        fi
    fi

    # If zsh is installed but user keeps bash, .zshrc part is handled in install_zsh_and_configure
}

summary() {
    echo
    echo "========================================"
    echo "Bootstrap complete."
    echo "User:         $USERNAME"
    echo "Sudo:         $([[ "$ADD_SUDO" =~ ^[Yy]$ ]] && echo yes || echo no)"
    echo "SSH key:      $([[ "$ADD_SSH" =~ ^[Yy]$ ]] && echo added || echo skipped)"
    echo "Dev packages: $([[ "$INSTALL_DEV_PACKAGES" == "Y" ]] && echo installed || echo skipped)"
    echo "Docker:       $([[ "$INSTALL_DOCKER" == "Y" ]] && echo installed || echo skipped)"
    echo "zsh:          $([[ "$INSTALL_ZSH" == "Y" ]] && echo installed/configured || echo skipped)"
    echo "fastfetch:    installed (if package found) and hooked into bash/zsh where configured."
    echo "========================================"
}

main() {
    require_root
    parse_args "$@"
    check_distro
    prompt_user_info
    create_or_update_user
    setup_ssh_key
    system_update
    install_common_dev_packages
    install_fastfetch
    install_docker
    install_zsh_and_configure
    enable_fastfetch_in_shells
    summary
}

main "$@"
