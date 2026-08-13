#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
tmp_paths="$(mktemp)"
trap 'rm -f "$tmp_paths"' EXIT

scan_paths() {
  if [[ -s "$tmp_paths" ]] && ! xargs -0 ripsecrets --strict-ignore < "$tmp_paths" >/dev/null 2>&1; then
    echo "Secret scan failed. Run ripsecrets locally for details." >&2
    return 1
  fi
}

case "$mode" in
  staged)
    git diff --cached --name-only --diff-filter=ACMR -z > "$tmp_paths"
    while IFS= read -r -d '' path; do
      name="${path##*/}"
      case "$name" in
        .env.example|.env.sample|.env.template) ;;
        .env|.env.*)
          echo "Refusing to commit credential-bearing environment file: $path" >&2
          exit 1
          ;;
      esac
    done < "$tmp_paths"
    scan_paths
    ;;
  tree)
    git ls-files -z > "$tmp_paths"
    scan_paths
    ;;
  range)
    base="${2:-origin/main}"
    git rev-parse --verify "$base^{commit}" >/dev/null
    gitleaks git --redact --no-banner --log-opts="$base..HEAD" .
    ;;
  *)
    echo "Usage: $0 staged|tree|range [base]" >&2
    exit 2
    ;;
esac
