#!/bin/bash

set -e

SELF="$0"
MONOINIT=0

# Template file contents (only for MONOINIT=1 mode)
CERTBOT_ONCE_YML_TEMPLATE=""
CLIENT_TEMPLATE=""
DOCKER_COMPOSE_YML_TEMPLATE=""
LIVEKIT_YAML_TEMPLATE=""
MATRIX_CONF_TEMPLATE=""
SERVER_TEMPLATE=""
MATRIX_INIT_CONF_TEMPLATE=""

VERSION="0.0.1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # no Color

# Logging function
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

print_help() {
  cat >&2 << EOF
Usage: $SELF [options]
Example: $SELF --domain=matrix.example.com --email=admin@example.com

Prerequisites:
  - Docker with Docker Compose plugin installed
  - Domain name with DNS A record pointing to this server
  - Open ports: 80/tcp, 443/tcp
  - sudo privileges (if Docker requires sudo)

Options:
  -d, --domain=<domain>                  Synapse server domain
  -e, --email=<email>                    Synapse server admin E-mail
  -p, --db-password=<password>           Postgres password
  -P, --redis-password=<password>        Redis password
  -r, --use-redis                        use Redis for LiveKit
                                         (clustering/high load only)
  -S, --turn-port-range-start=<port>     starting port for TURN connections
  -E, --turn-port-range-end=<port>       ending port for TURN connections
  -L, --no-livekit                       disable LiveKit (no WebRTC support)
  -k, --livekit-key=<key>                LiveKit API key
  -s, --livekit-secret=<secret>          LiveKit API secret
      --skip-cert-receiving              skip SSL cert receiving stage
      --cert-receiving-only              receive SSL cert and exit
      --clear-only                       clear all created files and dirs
  -h, --help                             show this help message
  -v, --version                          print the script version
EOF
}

print_version() {
  echo "version: $VERSION"
}

clear_dir() {
  log_info "Removing all created files and directories"
  sudo rm -rf ./certbot-once.yml \
    ./docker-compose.yml \
    ./certbot \
    ./db \
    ./livekit \
    ./nginx \
    ./redis \
    ./secrets \
    ./synapse \
    ./yq
}

# Check Docker availability
check_docker() {
  if command -v docker &> /dev/null; then
    if docker info &> /dev/null; then
      return 0
    fi
  fi
  return 1
}

PWD="$(pwd)"
# server domain
DOMAIN=""
# admin E-mail
EMAIL=""
# postgres password
DB_PASSWORD=""
# redis password
REDIS_PASSWORD=""
# use Redis (0 = disabled, 1 = enabled)
USE_REDIS=0
# starting port for TURN connections
TURN_PORT_RANGE_START=""
# ending port for TURN connections
TURN_PORT_RANGE_END=""
# do not use livekit
NO_LIVEKIT=0
# livekit key
LIVEKIT_KEY=""
# livekit secret
LIVEKIT_SECRET=""
# stages control
SKIP_CERT_RECEIVING=0
CERT_RECEIVING_ONLY=0

# parse additional parameters
while [[ $# -gt 0 ]]; do
  case $1 in
    -d)
      shift
      DOMAIN="$1"
      shift
      ;;
    --domain=*)
      DOMAIN="${1#*=}"
      shift
      ;;
    -e)
      shift
      EMAIL="$1"
      shift
      ;;
    --email=*)
      EMAIL="${1#*=}"
      shift
      ;;
    -p)
      shift
      DB_PASSWORD="$1"
      shift
      ;;
    --db-password=*)
      DB_PASSWORD="${1#*=}"
      shift
      ;;
    -P)
      shift
      REDIS_PASSWORD="$1"
      shift
      ;;
    --redis-password=*)
      REDIS_PASSWORD="${1#*=}"
      shift
      ;;
    -S)
      shift
      TURN_PORT_RANGE_START="$1"
      shift
      ;;
    --turn-port-range-start=*)
      TURN_PORT_RANGE_START="${1#*=}"
      shift
      ;;
    -E)
      shift
      TURN_PORT_RANGE_END="$1"
      shift
      ;;
    --turn-port-range-end=*)
      TURN_PORT_RANGE_END="${1#*=}"
      shift
      ;;
    -r|--use-redis)
      USE_REDIS=1
      shift
      ;;
    -k)
      shift
      LIVEKIT_KEY="$1"
      shift
      ;;
    --livekit-key=*)
      LIVEKIT_KEY="${1#*=}"
      shift
      ;;
    -s)
      shift
      LIVEKIT_SECRET="$1"
      shift
      ;;
    -L|--no-livekit)
      NO_LIVEKIT=1
      shift
      ;;
    --livekit-secret=*)
      LIVEKIT_SECRET="${1#*=}"
      shift
      ;;
    --skip-cert-receiving)
      SKIP_CERT_RECEIVING=1
      shift
      ;;
    --cert-receiving-only)
      CERT_RECEIVING_ONLY=1
      shift
      ;;
    --clear-only)
      clear_dir
      exit 0
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    -v|--version)
      print_version
      exit 0
      ;;
    *)
      log_warn "Unexpected parameter: $1"
      print_help
      exit 2
      ;;
  esac
done

if [[ -z "$DOMAIN" ]] || [[ -z "$EMAIL" ]]; then
  log_error "Domain and E-mail must be set"
  print_help
  exit 2
fi

# Determine if sudo is needed for docker commands
SUDO_CMD=""

if check_docker; then
  log_info "Docker is available without sudo"
else
  if sudo docker info &> /dev/null; then
    log_info "Docker requires sudo privileges"
    SUDO_CMD="sudo"
  else
    log_error "Docker is not available. Please install Docker and Docker Compose plugin."
    exit 1
  fi
fi

# SUDO_CMD_WITH_ENV is used for modifying files created by Docker (as root)
SUDO_CMD_WITH_ENV="sudo -E"

# Check docker compose plugin
if ! $SUDO_CMD docker compose version &> /dev/null; then
  log_error "Docker Compose plugin is not installed. Please install 'docker-compose-plugin'."
  exit 1
fi



if [[ "$CLEAR" -eq 1 ]]; then
  clear_dir
  exit 0
fi

log_info "Project initialization"

if [[ "$SKIP_CERT_RECEIVING" -eq 1 ]] && [[ "$CERT_RECEIVING_ONLY" -eq 1 ]]; then
  log_warn '"--skip-cert-receiving" and "--cert-receiving-only"
  options cannot be used together'
  exit 2
fi

log_info "Checking for templates"

check_templates() {
  # array of template file names to check
  files=(
    "certbot-once.in.yml"
    "client.in"
    "docker-compose.in.yml"
    "livekit.in.yaml"
    "matrix.in.conf"
    "server.in"
    "matrix-init.in.conf"
  )

  # loop through file array
  for file in "${files[@]}"; do
    log_info "Checking file \"$file\""

    if [[ ! -f "$PWD/templates/$file" ]]; then
      log_error "Template file \"$file\" is missing"
      exit 1
    fi
  done
}

if [ "$MONOINIT" -eq 0 ]; then
  log_info "Checking template files"
  check_templates
  TEMPLATES="$PWD/templates"
else
  # in MONOINIT mode, use built-in templates
  TEMPLATES=""  # not used, but variable declared for compatibility
fi

log_info "Creating directories"
mkdir -p certbot db livekit/config nginx/{conf.d,html} redis/data secrets synapse/data

# Check if yq is already downloaded
YQ_PATH="$PWD/yq"
if [[ ! -f "$YQ_PATH" ]]; then
  log_info "Downloading yq utility"

  ARCH="$(uname -m)"
  case "${ARCH}" in
      x86_64)
          YQ_SUFFIX="amd64"
          ;;
      aarch64|arm64)
          YQ_SUFFIX="arm64"
          ;;
      armv6l)
          YQ_SUFFIX="arm"
          ;;
      *)
          YQ_SUFFIX="${ARCH}"
          ;;
  esac

  wget "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$YQ_SUFFIX" -O "$YQ_PATH"
  chmod +x "$YQ_PATH"
fi

if [[ "$SKIP_CERT_RECEIVING" -ne 1 ]]; then
  log_info "Receiving SSL certificates"

  # create nginx configuration file
  if [ "$MONOINIT" -eq 0 ]; then
    cat "$TEMPLATES/matrix-init.in.conf" \
      | sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
      > "$PWD/nginx/conf.d/matrix.conf"
  else
    printf "%s" "$MATRIX_INIT_CONF_TEMPLATE" \
    | sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
    > "$PWD/nginx/conf.d/matrix.conf"
  fi

  log_info "Obtaining SSL certificate using Certbot"
  # create certbot-once.yml from new template for one-time certificate acquisition
  if [ "$MONOINIT" -eq 0 ]; then
    cat "$TEMPLATES/certbot-once.in.yml" \
      | sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
      | sed -e "s/\${EMAIL}/${EMAIL}/g" \
      > "$PWD/certbot-once.yml"
  else
    printf "%s" "$CERTBOT_ONCE_YML_TEMPLATE" \
    | sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
    | sed -e "s/\${EMAIL}/${EMAIL}/g" \
    > "$PWD/certbot-once.yml"
  fi

  # run one-time certificate acquisition procedure
  $SUDO_CMD docker compose -f certbot-once.yml up --abort-on-container-exit
  # after completion, both containers stop automatically
  $SUDO_CMD docker compose -f certbot-once.yml down
  log_info "SSL certificate obtained successfully"
fi

if [[ "$CERT_RECEIVING_ONLY" -eq 1 ]]; then
  exit 0
fi

log_info "Generating unset parameters"

if [[ -z "$TURN_PORT_RANGE_START" ]]; then
  TURN_PORT_RANGE_START=50100
  log_info "Starting TURN port set to $TURN_PORT_RANGE_START"
fi

if [[ -z "$TURN_PORT_RANGE_END" ]]; then
  TURN_PORT_RANGE_END=50200
  log_info "Ending TURN port set to $TURN_PORT_RANGE_END"
fi

# generate random secrets if not provided
if [ -z "$DB_PASSWORD" ]; then
  DB_PASSWORD=$(openssl rand -base64 32)
  log_info "Generated random DB_PASSWORD"
fi

if [ -z "$REDIS_PASSWORD" ]; then
    REDIS_PASSWORD=$(openssl rand -base64 32)
    log_info "Generated random REDIS_PASSWORD"
fi

# create secret files
create_secret() {
    local name=$1
    local value=$2
    local file="secrets/${name}"

    echo -n "$value" > "$file"
    chmod 600 "$file"
    log_info "Created secret: $name"
}

create_secret "pg_passwd" "$DB_PASSWORD"
create_secret "redis_passwd" "$REDIS_PASSWORD"

log_info "Generating synapse configuration"

$SUDO_CMD docker run -it --rm \
  -v $PWD/synapse/data:/data \
  -e SYNAPSE_SERVER_NAME=${DOMAIN} \
  -e SYNAPSE_REPORT_STATS=no \
  matrixdotorg/synapse:latest generate

log_info "Correcting generated configuration"

# update listeners configuration
$SUDO_CMD_WITH_ENV "$YQ_PATH" eval '
  .listeners = [
    {
      "port": 8008,
      "resources": [
        {
          "compress": false,
          "names": ["client", "federation"]
        }
      ],
      "tls": false,
      "type": "http",
      "x_forwarded": true
    },
    {
      "port": 8448,
      "tls": false,
      "type": "http",
      "x_forwarded": true,
      "resources": [
        {
          "names": ["federation"]
        }
      ]
    }
  ]' -i "$PWD/synapse/data/homeserver.yaml"

PUBLIC_BASEURL="https://${DOMAIN}" $SUDO_CMD_WITH_ENV "$YQ_PATH" eval '.public_baseurl = env(PUBLIC_BASEURL)' \
  -i "$PWD/synapse/data/homeserver.yaml"

# update database configuration with the DB_PASSWORD variable using inline environment variable
DB_PASSWORD_VAR="$DB_PASSWORD" $SUDO_CMD_WITH_ENV "$YQ_PATH" eval '.database = {
    "name": "psycopg2",
    "args": {
      "user": "synapse",
      "password": env(DB_PASSWORD_VAR),
      "database": "synapse",
      "host": "db",
      "port": 5432,
      "cp_min": 5,
      "cp_max": 10
    }
  }' -i "$PWD/synapse/data/homeserver.yaml"

if [ -z "$LIVEKIT_KEY" ]; then
  LIVEKIT_KEY=$(openssl rand -hex 32)
fi

if [ -z "$LIVEKIT_SECRET" ]; then
  LIVEKIT_SECRET=$(openssl rand -hex 48)
fi

# Generate docker-compose.yml from template
if [[ "$MONOINIT" -eq 0 ]]; then
  cat "$TEMPLATES/docker-compose.in.yml" \
    | sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
    | sed -e "s/\${TURN_PORT_RANGE_START}/${TURN_PORT_RANGE_START}/g" \
    | sed -e "s/\${TURN_PORT_RANGE_END}/${TURN_PORT_RANGE_END}/g" \
    | sed -e "s/\${LIVEKIT_KEY}/${LIVEKIT_KEY}/g" \
    | sed -e "s/\${LIVEKIT_SECRET}/${LIVEKIT_SECRET}/g" \
    | sed -e "s/\${REDIS_PASSWORD}/${REDIS_PASSWORD}/g" \
    > "$PWD/docker-compose.yml"
else
  printf "%s" "$DOCKER_COMPOSE_YML_TEMPLATE" \
    | sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
    | sed -e "s/\${TURN_PORT_RANGE_START}/${TURN_PORT_RANGE_START}/g" \
    | sed -e "s/\${TURN_PORT_RANGE_END}/${TURN_PORT_RANGE_END}/g" \
    | sed -e "s/\${LIVEKIT_KEY}/${LIVEKIT_KEY}/g" \
    | sed -e "s/\${LIVEKIT_SECRET}/${LIVEKIT_SECRET}/g" \
    | sed -e "s/\${REDIS_PASSWORD}/${REDIS_PASSWORD}/g" \
    > "$PWD/docker-compose.yml"
fi

if [[ "$NO_LIVEKIT" -eq 1 ]]; then
  "$YQ_PATH" -i 'del(.services.livekit)' "$PWD/docker-compose.yml"
  "$YQ_PATH" -i 'del(.services.auth-service)' "$PWD/docker-compose.yml"
fi

# Add Redis configuration if USE_REDIS is set
if [[ "$USE_REDIS" -eq 1 ]] && [[ "$NO_LIVEKIT" -ne 1 ]]; then
  # Prepare redis service
  REDIS_PASSWORD_VAR="$REDIS_PASSWORD" "$YQ_PATH" eval '.services.redis = {
    "image": "redis:7-alpine",
    "container_name": "redis",
    "restart": "unless-stopped",
    "volumes": ["./redis/data:/data"],
    "environment": {
      "REDIS_PASSWORD": env(REDIS_PASSWORD_VAR)
    },
    "networks": ["matrix"]
  }' -i "$PWD/docker-compose.yml"

  # Prepare depends_on for livekit
  "$YQ_PATH" eval '.services.livekit.depends_on = ["redis"]' \
    -i "$PWD/docker-compose.yml"

  log_info "Redis configuration enabled"
fi
log_info "docker-compose.yml created from template"

# create livekit.yaml from template
if [[ "$NO_LIVEKIT" -ne 1 ]]; then
  if [ "$MONOINIT" -eq 0 ]; then
    cat "$TEMPLATES/livekit.in.yaml" \
      | sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
      | sed -e "s/\${LIVEKIT_KEY}/${LIVEKIT_KEY}/g" \
      | sed -e "s/\${LIVEKIT_SECRET}/${LIVEKIT_SECRET}/g" \
      | sed -e "s/\${TURN_PORT_RANGE_START}/${TURN_PORT_RANGE_START}/g" \
      | sed -e "s/\${TURN_PORT_RANGE_END}/${TURN_PORT_RANGE_END}/g" \
      | sed -e "s/\${REDIS_PASSWORD}/${REDIS_PASSWORD}/g" \
      > "$PWD/livekit/config/livekit.yaml"
  else
    printf "%s" "$LIVEKIT_YAML_TEMPLATE" \
    | sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
    | sed -e "s/\${LIVEKIT_KEY}/${LIVEKIT_KEY}/g" \
    | sed -e "s/\${LIVEKIT_SECRET}/${LIVEKIT_SECRET}/g" \
    | sed -e "s/\${TURN_PORT_RANGE_START}/${TURN_PORT_RANGE_START}/g" \
    | sed -e "s/\${TURN_PORT_RANGE_END}/${TURN_PORT_RANGE_END}/g" \
    | sed -e "s/\${REDIS_PASSWORD}/${REDIS_PASSWORD}/g" \
    > "$PWD/livekit/config/livekit.yaml"
  fi

  # Add Redis configuration to livekit.yaml if USE_REDIS is set
  if [ "$USE_REDIS" -eq 1 ]; then
    REDIS_PASSWORD_VAR="$REDIS_PASSWORD" "$YQ_PATH" eval '.redis = {
      "address": "redis:6379",
      "username": "",
      "password": env(REDIS_PASSWORD_VAR),
      "db": 0
    }' -i "$PWD/livekit/config/livekit.yaml"
  fi
fi

if [ "$MONOINIT" -eq 0 ]; then
  cat "$TEMPLATES/client.in" \
    | sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
    > "$PWD/nginx/html/client"
else
  printf "%s" "$CLIENT_TEMPLATE" \
    | sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
    > "$PWD/nginx/html/client"
fi
log_info "nginx/html/client created from template"

if [ "$MONOINIT" -eq 0 ]; then
  cat "$TEMPLATES/server.in" \
    | sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
    > "$PWD/nginx/html/server"
else
  printf "%s" "$SERVER_TEMPLATE" \
    | sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
    > "$PWD/nginx/html/server"
fi
log_info "nginx/html/server created from template"

if [ "$MONOINIT" -eq 0 ]; then
  cat "$TEMPLATES/matrix.in.conf" \
    | sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
    > "$PWD/nginx/conf.d/matrix.conf"
else
  printf "%s" "$MATRIX_CONF_TEMPLATE" \
    | sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
    > "$PWD/nginx/conf.d/matrix.conf"
fi

log_info "Initialization completed successfully!"
log_info "Next steps:"
log_info "1. Check files in secrets/ folder"
log_info "2. Edit docker-compose.yml if needed"
log_info "3. Run: docker-compose up -d"
log_info "4. Open the following ports:"
log_info "     80/tcp"
log_info "     443/tcp"
log_info "     3478/udp"
log_info "     5349/tcp"
log_info "     7880/tcp"
log_info "     7881/tcp"
log_info "     50100:50200/udp"
