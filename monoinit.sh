#!/bin/bash

set -e

# enable monolithic file mode
MONOINIT=1


CERTBOT_ONCE_YML_TEMPLATE="services:
  nginx:
    image: nginx:latest
    container_name: nginx-certbot
    restart: \"no\"
    ports:
      - \"80:80\"
      - \"443:443\"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d
      - ./nginx/html:/var/www/html
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
    networks:
      - matrix

  certbot-once:
    image: certbot/certbot:latest
    container_name: certbot-once
    volumes:
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
    command: >
      certonly --webroot -w /var/www/certbot -d \${DOMAIN} --email \${EMAIL} --agree-tos --no-eff-email --non-interactive
    depends_on:
      - nginx
    networks:
      - matrix

networks:
  matrix:
    driver: bridge"

CLIENT_TEMPLATE="{
  \"m.homeserver\": {
    \"base_url\": \"https://\${DOMAIN}\"
  },
  \"org.matrix.msc4143.rtc_foci\": [
    {
      \"type\": \"livekit\",
      \"livekit_service_url\": \"https://\${DOMAIN}\"
    }
  ]
}"

DOCKER_COMPOSE_YML_TEMPLATE="services:
  db:
    image: postgres:17-alpine
    container_name: synapse-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: synapse
      POSTGRES_USER: synapse
      POSTGRES_PASSWORD_FILE: /var/pg_passwd
      POSTGRES_INITDB_ARGS: \"--encoding=UTF-8 --lc-collate=C --lc-ctype=C\"
    volumes:
      - ./secrets/pg_passwd:/var/pg_passwd:ro
      - ./db:/var/lib/postgresql/data
    healthcheck:
      test: [\"CMD-SHELL\", \"pg_isready -U synapse\"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - matrix

  synapse:
    image: matrixdotorg/synapse:latest
    container_name: synapse
    restart: unless-stopped
    volumes:
      - ./synapse/data:/data
    environment:
      SYNAPSE_CONFIG_PATH: /data/homeserver.yaml
    # do not expose ports on host, only within network
    # expose:
      # - \"8008\"
      # - \"8448\"
    networks:
      - matrix

  livekit:
    image: livekit/livekit-server:latest
    container_name: livekit
    restart: unless-stopped
    ports:
      - \"7880:7880\"      # HTTP API
      - \"7881:7881\"      # TCP for TURN
      - \"\${TURN_PORT_RANGE_START}-\${TURN_PORT_RANGE_END}:\${TURN_PORT_RANGE_START}-\${TURN_PORT_RANGE_END}/udp\"  # UDP for TURN
      - \"5349:5349\"      # TURN TCP over TLS (if using)
      - \"3478:3478/udp\"  # TURN UDP over TLS (if using)
    volumes:
      - ./livekit/config:/config
      - ./livekit/data:/data
      - ./certbot/conf:/etc/letsencrypt  # so LiveKit can see certificates (optional)
    command: --config /config/livekit.yaml
#    depends_on:
#      - redis
    networks:
      - matrix

  auth-service:
    image: ghcr.io/element-hq/lk-jwt-service:latest
    container_name: auth-service
    hostname: auth-service
    environment:
      LIVEKIT_JWT_BIND: \":8080\"
      LIVEKIT_URL: wss://\${DOMAIN}/livekit/sfu
      LIVEKIT_KEY: \${LIVEKIT_KEY}
      LIVEKIT_SECRET: \${LIVEKIT_SECRET}
      LIVEKIT_FULL_ACCESS_HOMESERVERS: \"\${DOMAIN}\"
    volumes:
      - /etc/ssl/certs:/etc/ssl/certs:ro
    restart: unless-stopped
    # ports:
    #   - \"8070:8080\"
    networks:
      - matrix
    extra_hosts:
      - \"\${DOMAIN}:host-gateway\"

#  redis:
#    image: redis:7-alpine
#    container_name: redis
#    environment:
#      REDIS_PASSWORD: \"\${REDIS_PASSWORD}\"
#    restart: unless-stopped
#    volumes:
#      - ./redis/data:/data
#    networks:
#      - matrix

  nginx:
    image: nginx:latest
    container_name: nginx
    restart: unless-stopped
    ports:
      - \"80:80\"
      - \"443:443\"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d
      - ./nginx/html:/var/www/html
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
    depends_on:
      - synapse
      - livekit
    networks:
      - matrix

  certbot:
    image: certbot/certbot:latest
    container_name: certbot
    volumes:
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
    # command will be overridden for certificate acquisition and renewal
    entrypoint: \"/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait \$\${!}; done;'\"
    # run service, but it will sleep and check for updates every 12 hours
    restart: unless-stopped
    networks:
      - matrix

networks:
  matrix:
    driver: bridge"

LIVEKIT_YAML_TEMPLATE="# main server settings
port: 7880
bind_addresses:
  - \"0.0.0.0\"

# WebRTC settings
rtc:
  tcp_port: 7881
  port_range_start: \${TURN_PORT_RANGE_START}
  port_range_end: \${TURN_PORT_RANGE_END}
  use_external_ip: false
room:
  auto_create: false
logging:
  level: error

# TURN settings (separate block)
turn:
  enabled: true
  domain: \${DOMAIN} # your domain
  udp_port: 3478
  tls_port: 5349
  external_tls: false
  # if using your own certificates (recommended for TLS)
  cert_file: /etc/letsencrypt/live/\${DOMAIN}/fullchain.pem
  key_file: /etc/letsencrypt/live/\${DOMAIN}/privkey.pem
  # alternatively, you can use Let's Encrypt via automatic acquisition,
  # but this requires additional configuration (see documentation)

# API keys (map key -> secret)
keys:
  \"\${LIVEKIT_KEY}\": \"\${LIVEKIT_SECRET}\" # generate your own keys
# redis:
#   address: redis:6379
#   username: \"\"
#   password: \"\${REDIS_PASSWORD}\"
#   db: 0"

MATRIX_CONF_TEMPLATE="server {
    listen 80;
    server_name \${DOMAIN};

    # for domain verification by certbot (webroot)
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # redirect all other requests to HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen 8448 ssl;
    http2 on;
    server_name \${DOMAIN};

    # paths to certificates (will be mounted from certbot volume)
    ssl_certificate /etc/letsencrypt/live/\${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/\${DOMAIN}/privkey.pem;

    # proxy other _matrix paths (e.g., /_matrix/keys) to client port
    location ~ ^(/_matrix|/_synapse/client|/_synapse/admin) {
        proxy_pass http://synapse:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
	    client_max_body_size 50M;
    }

    location /sfu/get {
	    proxy_pass http://auth-service:8080/sfu/get;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # WebRTC requires WebSocket
    location /livekit/sfu {
        proxy_pass http://livekit:7880/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
	    # proxy_buffering off;
        proxy_read_timeout 86400s;
    }

    # static well-known (if needed to serve without proxy)
    location /.well-known/matrix/ {
        alias /var/www/html/;
	    add_header Access-Control-Allow-Origin *;
	    add_header Content-Type application/json;
        try_files \$uri =404;
    }
}"

SERVER_TEMPLATE="{ \"m.server\": \"\${DOMAIN}:443\" }"

MATRIX_INIT_CONF_TEMPLATE="server {
    listen 80;
    server_name \${DOMAIN};

    # for domain verification by certbot (webroot)
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
}"


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
