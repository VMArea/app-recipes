#!/bin/bash
set -euo pipefail
# shellcheck source=../../lib/recipe-lib.sh
. "$VMAREA_LIB"

vm_log "installing Docker Engine $VM_DOCKER_VERSION"
vm_install_docker
vm_enable_unattended_security_updates

docker info >/dev/null
docker compose version >/dev/null
vm_log "Docker Engine $(docker version --format '{{.Server.Version}}') is running"
