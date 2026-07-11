#!/usr/bin/env bash
#
# prepare.sh — configure the current shell for the Pi sample you are in.
#
# Run this from INSIDE a sample directory, SOURCED so the environment changes
# stay in your shell:
#
#     cd samples/001-helloworld
#     source ./prepare.sh        # or:  . ./prepare.sh
#
# It does two things:
#   1. Loads the nearest .env files (walking up to the filesystem root) so the
#      AZURE_PI_TEST_* variables are available. A nearer .env wins over a parent
#      one, and variables already set in your shell are preserved.
#   2. Sets PI_CODING_AGENT_DIR to this directory, so Pi discovers the sample's
#      models.json / settings.json and creates bin/, sessions/, and any dump/
#      folders here.
#
# This is the bash counterpart of Env.psm1 + prepare.ps1. It must be SOURCED,
# not executed: a child process would not carry the environment changes back
# into your shell.

# Refuse to run if executed instead of sourced. When this file is sourced in
# bash, $0 is the shell name while BASH_SOURCE[0] is this script, so they
# differ; when run as `bash ./prepare.sh` they are equal. (In zsh, BASH_SOURCE
# is unset, so a `source ./prepare.sh` there just skips this check.)
if [ -n "${BASH_SOURCE:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "prepare.sh must be SOURCED, not executed." >&2
    echo "  Use:  source ./prepare.sh    (or:  . ./prepare.sh)" >&2
    echo "  Not:  bash ./prepare.sh      — that sets the variables in a" >&2
    echo "        subshell that disappears, so pi sees no API key." >&2
    exit 1
fi

_pi_prepare() {
    local sample_dir dir parent env_file line key val already_set
    sample_dir="$(pwd)"

    # Walk up from the sample directory toward the root. Because we skip keys
    # that are already set, the nearest .env (visited first) wins.
    dir="$sample_dir"
    while :; do
        env_file="$dir/.env"
        if [ -f "$env_file" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                # Trim leading whitespace; skip blanks and comments.
                line="${line#"${line%%[![:space:]]*}"}"
                [ -z "$line" ] && continue
                case "$line" in \#*) continue ;; esac
                # Drop an optional 'export ' prefix; require KEY=VALUE.
                line="${line#export }"
                case "$line" in *=*) ;; *) continue ;; esac
                key="${line%%=*}"
                val="${line#*=}"
                # Trim spaces around the key and strip matching outer quotes.
                key="$(printf '%s' "$key" | tr -d '[:space:]')"
                case "$val" in
                    \"*\") val="${val#\"}"; val="${val%\"}" ;;
                    \'*\') val="${val#\'}"; val="${val%\'}" ;;
                esac
                # Preserve anything already set (shell env or a nearer .env).
                eval "already_set=\${$key+set}"
                [ "$already_set" = set ] && continue
                export "$key=$val"
            done < "$env_file"
        fi
        parent="$(dirname "$dir")"
        [ "$parent" = "$dir" ] && break
        dir="$parent"
    done

    export PI_CODING_AGENT_DIR="$sample_dir"
    echo "Pi configured for sample: $sample_dir"
}

_pi_prepare
unset -f _pi_prepare
