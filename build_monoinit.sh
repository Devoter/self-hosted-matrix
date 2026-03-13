#!/bin/bash

set -e

# file to write the result to
OUTPUT_FILE="$(pwd)/monoinit.sh"

echo '#!/bin/bash

set -e

# enable monolithic file mode
MONOINIT=1

' > "$OUTPUT_FILE"

# function to read file and escape special characters for use in bash double quotes
read_and_escape_file() {
  local file="$1"
  # read file and escape special characters
  sed 's/\\/\\\\/g; s/"/\\"/g; s/`/\`/g; s/\$/\\$/g' "$file"
}

VAR_NAMES=(
  "CERTBOT_ONCE_YML_TEMPLATE"
  "CLIENT_TEMPLATE"
  "DOCKER_COMPOSE_YML_TEMPLATE"
  "LIVEKIT_YAML_TEMPLATE"
  "MATRIX_CONF_TEMPLATE"
  "SERVER_TEMPLATE"
  "MATRIX_INIT_CONF_TEMPLATE"
)

TEMPLATE_FILES=(
  "templates/certbot-once.in.yml"
  "templates/client.in"
  "templates/docker-compose.in.yml"
  "templates/livekit.in.yaml"
  "templates/matrix.in.conf"
  "templates/server.in"
  "templates/matrix-init.in.conf"
)

# add template contents to variables, escaping special characters
for i in $(seq 0 $((${#VAR_NAMES[@]} - 1))); do
  echo "${VAR_NAMES[$i]}=\"$(read_and_escape_file ./${TEMPLATE_FILES[$i]})\"" >> "$OUTPUT_FILE"
  echo '' >> "$OUTPUT_FILE"
done

# add init.sh content starting from line 16 (after template variable declarations)
tail -n +16 init.sh >> "$OUTPUT_FILE"

chmod +x "$OUTPUT_FILE"

echo "Monolithic script $OUTPUT_FILE created successfully!"
