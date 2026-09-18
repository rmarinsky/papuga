#!/bin/bash

set -euo pipefail

for path in "$@"; do
    [ -e "$path" ] || continue
    name="$(basename "$path")"
    case "$name" in
        .env.example|.env.sample|.env.template)
            ;;
        .env|.env.*|*.p8|*.p12|*.pem|*.key|*.mobileprovision)
            echo "Refusing credential-bearing file: $path" >&2
            exit 1
            ;;
    esac
done
