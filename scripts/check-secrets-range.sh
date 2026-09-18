#!/bin/bash

set -euo pipefail

base_ref="${1:-origin/main}"
command -v ripsecrets >/dev/null || { echo "ripsecrets is required" >&2; exit 1; }
command -v gitleaks >/dev/null || { echo "gitleaks is required" >&2; exit 1; }
git rev-parse --verify "$base_ref" >/dev/null

changed_files=()
while IFS= read -r path; do
    [ -f "$path" ] && changed_files+=("$path")
done < <(git diff --name-only --diff-filter=ACMR "$base_ref...HEAD")

scripts/check-secret-files.sh "${changed_files[@]}"
if [ "${#changed_files[@]}" -gt 0 ]; then
    ripsecrets --strict-ignore "${changed_files[@]}"
fi
gitleaks git --redact --log-opts="$base_ref..HEAD"
