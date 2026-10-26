#!/usr/bin/env bash
# server_start.sh home|work — the two Strata profiles are mutually exclusive: everything comes
# down first. home = Strata on the 5070 Ti; work = Strata on the 7900 XTX (HIP) + whisper on
# the 5070 Ti.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

case "${1:-}" in
  home) profile=server_home ;;
  work) profile=server_work ;;
  *) echo "usage: $0 home|work" >&2; exit 1 ;;
esac

podman-compose -f llama-cpp.yml down
podman-compose -f whisper.yml down || true
podman-compose -f llama-cpp.yml --profile "$profile" up -d
if [ "$profile" = server_work ]; then
  podman-compose -f whisper.yml --profile server_work up -d
fi
# a recreated strata comes back on a new container IP and litellm keeps the old one cached
podman restart litellm_server
