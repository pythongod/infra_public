#!/usr/bin/env bash
set -euo pipefail

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "Neither curl nor wget found. Installing curl..."
    apt-get update -y
    apt-get install -y curl
fi

# ======= USEAGE ================
# curl -fsSL https://raw.githubusercontent.com/pythongod/infra_public/main/setup.sh | sudo bash
#
# curl -fsSLO https://raw.githubusercontent.com/pythongod/infra_public/main/setup.sh
# chmod +x setup.sh
# sudo ./setup.sh
# 
# curl -fsSL https://raw.githubusercontent.com/pythongod/infra_public/main/setup.sh | \
#  NEWUSER_PASSWORD='MyS3cret' sudo bash -s -- \
#    --user jack \
#    --with-docker \
#    --with-zsh \
#    --non-interactive
#
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
# - Logs everything to /var/log/bootstrap.log
# ==============================

# -------- Defaults / config --------
USERNAME="jack"
ADD_SUDO="Y"
ADD_SSH="N"

INSTALL_DEV_PACKAGES="Y"
INSTALL_DOCKER="N"
INSTALL_ZSH="N"

INTERACTIVE="Y"

LOG_FILE="/var/log/bootstrap.log"

# If running non-interactively, you can set NEWUSER_PASSWORD via env
NEWUSER_PASSWORD="${NEWUSER_PASSWORD:-}"

# -------- Logging helpers --------
init_logging() {
    # Make sure we can write to the log file
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    {
        echo
        echo "===================="
        echo "Bootstrap run started: $(date --iso-8601=seconds)"
        echo "===================="
    } >> "$LOG_FILE"
}

log_console() {
    # Console only (short messages)
    echo "$*"
}

log_file() {
    # File-only detailed logging (no console)
    printf '%s %s\n' "$(date --iso-8601=seconds)" "$*" >> "$LOG_FILE"
}

log_both() {
    # Console + file
    echo "$*"
    printf '%s %s\n' "$(date --iso-8601=seconds)" "$*" >> "$LOG_FILE"
}

log_error() {
    # Console to stderr + file
    >&2 echo "$*"
    printf '%s [ERROR] %s\n' "$(date --iso-8601=seconds)" "$*" >> "$LOG_FILE"
}

# Trap for unexpected errors
trap 'log_error "Script aborted unexpectedly at line $LINENO."' ERR

# -------- Core helpers --------
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
EOF
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)."
        exit 1
    fi
}

check_distro() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID_LIKE:-$ID}" in
            *debian*|*ubuntu* )
                log_both "Detected Debian/Ubuntu-like system: ${PRETTY_NAME:-$ID}"
                ;;
            * )
                log_both "Warning: This script is intended for Debian/Ubuntu. Detected: ${PRETTY_NAME:-$ID}"
                read -r -p "Continue anyway? [y/N]: " cont
                cont=${cont:-N}
                if [[ ! "$cont" =~ ^[Yy]$ ]]; then
                    log_both "Aborting due to unsupported distro."
                    exit 1
                fi
                ;;
        esac
    else
        log_both "Cannot detect OS (no /etc/os-release). Continuing blindly."
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
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    log_file "Parsed args: USERNAME=$USERNAME, ADD_SUDO=$ADD_SUDO, INSTALL_DEV_PACKAGES=$INSTALL_DEV_PACKAGES, INSTALL_DOCKER=$INSTALL_DOCKER, INSTALL_ZSH=$INSTALL_ZSH, INTERACTIVE=$INTERACTIVE"
}

prompt_user_info() {
    if [[ "$INTERACTIVE" == "Y" ]]; then
        read -r -p "Enter username to create [${USERNAME}]: " input_user
        USERNAME=${input_user:-$USERNAME}

        if id "$USERNAME" >/dev/null 2>&1; then
            log_both "User '$USERNAME' already exists."
            USE_EXISTING="yes"
        else
            log_both "User '$USERNAME' does not exist yet, will be created."
            USE_EXISTING="no"
        fi

        # Password prompt
        while true; do
            read -s -p "Enter password for user '$USERNAME': " PASSWORD
            echo
            read -s -p "Confirm password: " PASSWORD2
            echo
            if [[ "$PASSWORD" != "$PASSWORD2" ]]; then
                log_console "Passwords do not match, try again."
                log_file "Password mismatch while configuring user '$USERNAME'."
            elif [[ -z "$PASSWORD" ]]; then
                log_console "Password must not be empty, try again."
                log_file "Empty password attempted for user '$USERNAME'."
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
            log_both "User '$USERNAME' already exists (non-interactive)."
            USE_EXISTING="yes"
        else
            log_both "User '$USERNAME' does not exist yet, will be created (non-interactive)."
            USE_EXISTING="no"
        fi

        if [[ -z "${NEWUSER_PASSWORD}" ]]; then
            log_error "Non-interactive mode requires NEWUSER_PASSWORD env var."
            exit 1
        fi
        PASSWORD="$NEWUSER_PASSWORD"
        ADD_SSH="N"  # keep ssh key handling manual in non-interactive
    fi

    log_file "User config: USERNAME=$USERNAME, USE_EXISTING=$USE_EXISTING, ADD_SUDO=$ADD_SUDO, ADD_SSH=$ADD_SSH"
}

create_or_update_user() {
    if [[ "$USE_EXISTING" == "no" ]]; then
        log_both "Creating user '$USERNAME'..."
        useradd -m -s /bin/bash "$USERNAME"
    else
        log_both "Using existing user '$USERNAME'."
    fi

    log_file "Setting password for '$USERNAME'."
    echo "${USERNAME}:${PASSWORD}" | chpasswd

    if [[ "$ADD_SUDO" =~ ^[Yy]$ ]]; then
        log_both "Adding '$USERNAME' to sudo group..."
        if getent group sudo >/dev/null 2>&1; then
            usermod -aG sudo "$USERNAME"
        elif getent group wheel >/dev/null 2>&1; then
            usermod -aG wheel "$USERNAME"
        else
            log_error "No sudo/wheel group found. Skipping sudo group membership."
        fi
    fi
}

setup_ssh_key() {
    if [[ ! "$ADD_SSH" =~ ^[Yy]$ ]]; then
        log_file "SSH key addition skipped for '$USERNAME'."
        return
    fi

    log_console "Paste the SSH public key for '$USERNAME' below."
    log_console "End with an empty line."
    SSH_KEY=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        SSH_KEY+="$line"$'\n'
    done

    if [[ -z "${SSH_KEY// }" ]]; then
        log_console "No SSH key entered, skipping."
        log_file "No SSH key entered for '$USERNAME'."
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

    log_both "SSH key added to ${AUTH_KEYS}."
}

system_update() {
    log_both "Updating apt package lists..."
    apt-get update -y >>"$LOG_FILE" 2>&1

    log_both "Upgrading existing packages..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >>"$LOG_FILE" 2>&1
}

install_fastfetch() {
    log_both "Installing fastfetch..."
    if ! apt-get install -y fastfetch >>"$LOG_FILE" 2>&1; then
        log_error "fastfetch package not found in repositories. Skipping installation."
    else
        log_file "fastfetch installed successfully."
    fi
}

install_common_dev_packages() {
    if [[ "$INSTALL_DEV_PACKAGES" != "Y" ]]; then
        log_both "Skipping common dev packages installation."
        return
    fi

    log_both "Installing common dev packages (git, curl, wget, vim, build-essential)..."
    apt-get install -y \
        git \
        curl \
        wget \
        vim \
        build-essential \
        ca-certificates \
        gnupg \
        lsb-release >>"$LOG_FILE" 2>&1

    log_file "Common dev packages installed."
}

install_docker() {
    if [[ "$INSTALL_DOCKER" != "Y" ]]; then
        log_both "Skipping Docker installation."
        return
    fi

    log_both "Installing Docker (Docker CE) for Debian/Ubuntu..."

    apt-get remove -y docker docker-engine docker.io containerd runc >>"$LOG_FILE" 2>&1 || true

    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg >>"$LOG_FILE" 2>&1
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    local codename
    codename=$( . /etc/os-release && echo "$VERSION_CODENAME" )

    echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
 ${codename} stable" > /etc/apt/sources.list.d/docker.list

    apt-get update -y >>"$LOG_FILE" 2>&1
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >>"$LOG_FILE" 2>&1

    systemctl enable docker >>"$LOG_FILE" 2>&1
    systemctl start docker >>"$LOG_FILE" 2>&1

    if getent group docker >/dev/null 2>&1; then
        usermod -aG docker "$USERNAME"
        log_both "Docker installed. User '$USERNAME' added to docker group (logout/login required)."
    else
        log_error "Docker group not found after installation."
    fi
}

install_zsh_and_configure() {
    if [[ "$INSTALL_ZSH" != "Y" ]]; then
        log_both "Skipping zsh installation."
        return
    fi

    log_both "Installing zsh..."
    apt-get install -y zsh >>"$LOG_FILE" 2>&1

    USER_HOME=$(eval echo "~$USERNAME")
    ZSHRC="${USER_HOME}/.zshrc"

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
        log_file "Created default .zshrc for '$USERNAME'."
    fi

    log_both "Setting zsh as default shell for '$USERNAME'..."
    chsh -s "$(command -v zsh)" "$USERNAME" >>"$LOG_FILE" 2>&1
}

enable_fastfetch_in_shells() {
    USER_HOME=$(eval echo "~$USERNAME")

    BASHRC="${USER_HOME}/.bashrc"
    FASTFETCH_SNIPPET=$'\n# Run fastfetch on interactive login\nif command -v fastfetch >/dev/null 2>&1; then\n    fastfetch\nfi\n'

    if [[ -f "$BASHRC" ]]; then
        if ! grep -q "fastfetch" "$BASHRC" 2>/dev/null; then
            log_both "Enabling fastfetch for '$USERNAME' in ${BASHRC}..."
            printf "%s" "$FASTFETCH_SNIPPET" >> "$BASHRC"
            chown "$USERNAME":"$USERNAME" "$BASHRC"
        else
            log_both "fastfetch already referenced in ${BASHRC}, not adding again."
        fi
    fi
}

summary() {
    log_console
    log_console "========================================"
    log_console "Bootstrap complete."
    log_console "User:         $USERNAME"
    log_console "Sudo:         $([[ "$ADD_SUDO" =~ ^[Yy]$ ]] && echo yes || echo no)"
    log_console "SSH key:      $([[ "$ADD_SSH" =~ ^[Yy]$ ]] && echo added || echo skipped)"
    log_console "Dev packages: $([[ "$INSTALL_DEV_PACKAGES" == "Y" ]] && echo installed || echo skipped)"
    log_console "Docker:       $([[ "$INSTALL_DOCKER" == "Y" ]] && echo installed || echo skipped)"
    log_console "zsh:          $([[ "$INSTALL_ZSH" == "Y" ]] && echo installed/configured || echo skipped)"
    log_console "fastfetch:    installed (if package found) and hooked into bash/zsh where configured."
    log_console "Log file:     $LOG_FILE"
    log_console "========================================"

    log_file "Bootstrap finished successfully."
}

main() {
    init_logging
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
