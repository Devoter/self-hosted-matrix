# Matrix Server Initialization Script

Initialization script for deploying a Matrix Synapse homeserver with LiveKit integration in Docker containers.

## Overview

This project provides an automated setup for deploying:

- **Matrix Synapse** - Full-featured Matrix homeserver
- **LiveKit** - WebRTC SFU for real-time audio/video communication (optional, can be disabled with `--no-livekit`)
- **JWT Authentication** - Element-compatible authentication service for LiveKit
- **Automatic SSL** - Let's Encrypt certificates via Certbot with auto-renewal
- **Nginx Reverse Proxy** - Handles HTTPS termination and WebSocket connections
- **PostgreSQL** - Production-ready database backend
- **Redis** - Optional cache for LiveKit clustering (with `--use-redis`, not needed for single-server deployments)

All services run in Docker containers with pre-configured settings.

## Prerequisites

Before running the initialization script, ensure you have:

- **Docker** with **Docker Compose plugin** installed
- **Domain name** with DNS A record pointing to your server
- **Open ports** on your firewall:
  - `80/tcp` - HTTP (for Let's Encrypt certificate verification)
  - `443/tcp` - HTTPS (Matrix client connections)
- **sudo privileges** (only if Docker requires sudo on your system)

The script automatically detects whether Docker requires sudo or not.

Additional ports will be used by the services (see [Ports](#ports) section).

## Requirements

- Domain name with DNS records pointing to your server

## Quick Start

### Run the initialization script

The `init.sh` script sets up the entire Matrix server environment:

```bash
./init.sh --domain=matrix.example.com --email=admin@example.com [options]
```

The script will:
- Check Docker availability (with or without sudo)
- Generate random secrets and passwords (or use provided ones)
- Create directory structure
- Download yq utility (cached for subsequent runs)
- Generate Synapse configuration
- Obtain SSL certificates from Let's Encrypt
- Create `docker-compose.yml` and all service configurations
- Optionally configure Redis support

### Available options

| Short | Long                                   | Description                                                  |
|-------|----------------------------------------|--------------------------------------------------------------|
| `-d`  | `--domain=<domain>`                    | Synapse server domain (required)                             |
| `-e`  | `--email=<email>`                      | Synapse server admin email (required)                        |
| `-p`  | `--db-password=<password>`             | Postgres password (auto-generated if not provided)           |
| `-P`  | `--redis-password=<password>`          | Redis password (auto-generated if not provided)              |
| `-r`  | `--use-redis`                          | Enable Redis for LiveKit (clustering/high load only)         |
| `-S`  | `--turn-port-range-start=<port>`       | Starting port for TURN (default: 50100)                      |
| `-E`  | `--turn-port-range-end=<port>`         | Ending port for TURN (default: 50200)                        |
| `-k`  | `--livekit-key=<key>`                  | LiveKit API key (auto-generated if not provided)             |
| `-s`  | `--livekit-secret=<secret>`            | LiveKit API secret (auto-generated if not provided)          |
| `-L`  | `--no-livekit`                         | Disable LiveKit (no WebRTC support)                          |
|       | `--skip-cert-receiving`                | Skip SSL certificate receiving stage                         |
|       | `--cert-receiving-only`                | Receive SSL certificate and exit                             |
|       | `--clear-only`                         | Clear all created files and directories                      |
| `-h`  | `--help`                               | Show help message (output to stderr)                         |
| `-v`  | `--version`                            | Print script version                                         |

### Example

```bash
./init.sh --domain=matrix.example.com --email=admin@example.com --db-password=MySecurePassword123
```

### Example with Redis

```bash
./init.sh --domain=matrix.example.com --email=admin@example.com --use-redis --redis-password=RedisSecret123
```

### Example without LiveKit

To deploy Matrix server without LiveKit (WebRTC) support:

```bash
./init.sh --domain=matrix.example.com --email=admin@example.com --no-livekit
```

This will skip LiveKit and auth-service deployment.

### Example: Skip Certificate Receiving

To skip SSL certificate receiving (e.g., if you already have certificates):

```bash
./init.sh --domain=matrix.example.com --email=admin@example.com --skip-cert-receiving
```

### Example: Certificate Receiving Only

To only receive SSL certificates without full initialization:

```bash
./init.sh --domain=matrix.example.com --email=admin@example.com --cert-receiving-only
```

This is useful for renewing certificates or pre-installing them before
running the full initialization later.

### Example: Clear Created Files

To remove all created files and directories:

```bash
./init.sh --clear-only
```

## Monolithic Mode (monoinit.sh)

The `monoinit.sh` script performs the same function as `init.sh`, but contains all configuration templates embedded within itself. This means it does not require the `templates/` directory or any additional files to run.

### Building monoinit.sh

To create the monolithic script:

```bash
./build_monoinit.sh
```

This generates `monoinit.sh` in the current directory.

### Using monoinit.sh

```bash
./monoinit.sh --domain=matrix.example.com --email=admin@example.com [options]
```

**Use cases:**
- Deploying to remote servers (single file to transfer)
- Distribution as a standalone installer
- Simplified version control (single file)

The generated `monoinit.sh` accepts the same options as `init.sh`.

## Project Structure

```
matrix/
├── init.sh                 # Main initialization script (requires templates/)
├── monoinit.sh             # Standalone initialization script (self-contained)
├── build_monoinit.sh       # Script to build monoinit.sh from templates
├── templates/              # Configuration templates (used by init.sh)
│   ├── docker-compose.in.yml
│   ├── matrix.in.conf
│   ├── matrix-init.in.conf
│   ├── livekit.in.yaml
│   ├── certbot-once.in.yml
│   ├── client.in
│   └── server.in
├── certbot/                # Let's Encrypt certificates (created by init.sh)
├── synapse/                # Synapse configuration (created by init.sh)
├── livekit/                # LiveKit configuration (created by init.sh)
├── nginx/                  # Nginx configuration (created by init.sh)
├── db/                     # PostgreSQL data (created by init.sh)
├── redis/                  # Redis data (optional, created by init.sh)
└── secrets/                # Sensitive credentials (created by init.sh)
```

**Note:** After running `init.sh`, the following files are generated:
- `docker-compose.yml` - Docker Compose configuration
- `synapse/data/homeserver.yaml` - Synapse configuration
- `livekit/config/livekit.yaml` - LiveKit configuration
- `nginx/conf.d/matrix.conf` - Nginx configuration
- `certbot-once.yml` - Temporary Certbot configuration

## Architecture

```
                    ┌─────────────────┐
                    │     Nginx       │
                    │  (Reverse Proxy)│
                    └────────┬────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
        ▼                    ▼                    ▼
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│    Synapse    │   │   LiveKit     │   │ Auth Service  │
│   (Port 8008) │   │ (Port 7880)   │   │  (Port 8080)  │
└───────┬───────┘   └───────┬───────┘   └───────────────┘
        │                   │
        ▼                   ▼
┌───────────────┐   ┌───────────────┐
│  PostgreSQL   │   │    Redis      │
│   (Port 5432) │   │  (optional)   │
└───────────────┘   └───────────────┘
```

**Notes:**
- Redis is only deployed when using the `--use-redis` option
- LiveKit and Auth Service are not deployed when using `--no-livekit`

## Services

| Service | Image | Description |
|---------|-------|-------------|
| `db` | postgres:17-alpine | PostgreSQL database |
| `synapse` | matrixdotorg/synapse:latest | Matrix homeserver |
| `livekit` | livekit/livekit-server:latest | WebRTC SFU (not deployed with `--no-livekit`) |
| `auth-service` | ghcr.io/element-hq/lk-jwt-service:latest | JWT authentication for LiveKit (not deployed with `--no-livekit`) |
| `redis` | redis:7-alpine | Redis cache (optional, with `--use-redis`) |
| `nginx` | nginx:latest | Reverse proxy |
| `certbot` | certbot/certbot:latest | SSL certificate management |

## Configuration

### Synapse

The Synapse configuration is auto-generated during initialization. Key settings:

- Listeners on ports 8008 (client) and 8448 (federation)
- PostgreSQL database backend
- HTTP (non-TLS) listeners behind nginx proxy

### LiveKit

LiveKit configuration (`livekit/config/livekit.yaml`):

- WebRTC settings with TCP port 7881
- TURN server integration
- SSL certificates from Let's Encrypt
- API key authentication
- Redis support (when enabled with `--use-redis`)

**Note:** LiveKit is not deployed when using `--no-livekit`.

### Redis (Optional)

When enabled with `--use-redis`:

- Redis service added to `docker-compose.yml`
- LiveKit configured to use Redis for state management
- Redis password stored in `secrets/redis_passwd`
- Data persisted in `redis/data/`

**Note:** Redis is only required for LiveKit clustering (multiple LiveKit servers) or high-availability setups. For a single-server deployment with moderate load, Redis is not necessary. LiveKit can operate without Redis in standalone mode.

### Nginx

Nginx handles:

- SSL termination with Let's Encrypt certificates
- Reverse proxy to Synapse (Matrix API)
- WebSocket proxy for LiveKit SFU
- JWT authentication endpoint for LiveKit
- Static `.well-known` Matrix discovery files

## Post-Initialization

After running `init.sh`, the server environment is ready to start.

### 1. Check generated secrets

```bash
ls -la secrets/
cat secrets/pg_passwd
```

### 2. Review generated configuration files

- `docker-compose.yml` - Docker services configuration
- `synapse/data/homeserver.yaml` - Synapse configuration
- `livekit/config/livekit.yaml` - LiveKit configuration
- `nginx/conf.d/matrix.conf` - Nginx configuration

### 3. Start the services

```bash
docker-compose up -d
```

### 4. Check service status

```bash
docker-compose ps
docker-compose logs -f
```

### 5. Configure firewall

<a id="ports"></a>
Ensure the following ports are open:

```bash
# TCP ports
80      # HTTP (certificates)
443     # HTTPS (Matrix clients)
7880    # LiveKit API
7881    # LiveKit TURN TCP
5349    # TURN TCP over TLS

# UDP ports
3478    # TURN
50100-50200  # TURN port range
```

## Client Configuration

### Element Web/Desktop

Connect to your homeserver:

```
https://matrix.example.com
```

### Element Mobile

1. Open Element app
2. Tap "Sign in"
3. Enter your domain: `matrix.example.com`
4. Continue with your credentials

## Maintenance

### Renew SSL certificates

Certificates are automatically renewed by the Certbot container every 12 hours.

Manual renewal:

```bash
docker-compose run --rm certbot certbot renew
```

### Update services

The initialization script generates configuration files based on templates. To update:

1. Pull latest images:
```bash
docker-compose pull
docker-compose up -d
```

2. If you need to regenerate configuration with updated templates, run `init.sh` again (existing data will be preserved).

### View logs

```bash
# All services
docker-compose logs -f

# Specific service
docker-compose logs -f synapse
docker-compose logs -f livekit
docker-compose logs -f nginx
```

### Backup

```bash
# Stop services
docker-compose down

# Backup data directories
tar -czf matrix-backup-$(date +%Y%m%d).tar.gz \
    synapse/data \
    db \
    livekit/data \
    redis/data \
    certbot/conf \
    secrets
```

## Troubleshooting

### Certificate issues

Check Certbot logs:

```bash
docker-compose logs certbot
```

Ensure ports 80 and 443 are accessible from the internet.

### Synapse issues

Check Synapse logs:

```bash
docker-compose logs synapse
```

Verify database connection:

```bash
docker-compose logs db
```

### LiveKit issues

Check LiveKit logs:

```bash
docker-compose logs livekit
docker-compose logs auth-service
```

Verify WebSocket connections in browser console.

### Redis issues

If using Redis, check its status:

```bash
docker-compose logs redis
docker-compose exec redis redis-cli ping
```

Ensure Redis password matches in `secrets/redis_passwd` and `docker-compose.yml`.

## Security Notes

- All secrets are stored in the `secrets/` directory with restricted permissions (600)
- Database passwords are auto-generated using OpenSSL if not provided
- All communication is encrypted via HTTPS/TLS
- TURN server requires proper firewall configuration
- Redis password is auto-generated if not provided (when using `--use-redis`)

## License

This project is licensed under the BSD-3-Clause License - see the [LICENSE](LICENSE) file for details.

## Support

For Matrix-related issues:
- [Synapse Documentation](https://matrix-org.github.io/synapse/)
- [Matrix Community](https://matrix.org/)

For LiveKit-related issues:
- [LiveKit Documentation](https://docs.livekit.io/)
- [LiveKit GitHub](https://github.com/livekit/livekit)
