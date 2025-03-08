#!/usr/bin/env sh

# Script Name: json-wrap.sh
# Description: Executes the command passed as arguments and wraps its stdout in a JSON object with a "value" field.
# Usage: ./json-wrap.sh [--ignore-error | -i] <command> [args...]
# Options:
#   -i, --ignore-error  Ignore command execution failures and return an empty JSON object with exit code 0.
#
# Examples:
#   $ ./json-wrap.sh echo "example"
#   { "value": "example" }
#
#   $ ./json-wrap.sh -i false
#   { "value": "" }
#
# Notes:
#   - Useful for Terraform's external data sources.
#   - Automatically escapes backslashes, double quotes, and newlines.
#   - Removes all trailing newlines.
#   - Breaks on carriage returns and null characters.
#   - If the command fails and '--ignore-error' is not set, it returns an empty JSON object and exits with error code 1.

ignore_error=0
case "$1" in
    "--ignore-error" | "-i")
        ignore_error=1
        shift
        ;;
esac

# Ensure a command is provided.
if [ $# -eq 0 ]; then
    echo "Error: $0 expects a command to execute, but none was provided." >&2
    exit 1
fi

# Run the command and capture its output.
if ! raw_output="$("$@" 2>/dev/null)"; then
    printf '{ "value": "" }'
    if [ "${ignore_error}" -eq 1 ]; then
        exit 0
    else
        exit 1
    fi
fi

# Escape backslashes ('\' -> '\\'), double-quotes ('"' -> '\"') and replace newlines with their escape-sequence ('\n').
esc_output=$(printf '%s' "${raw_output}" | awk '{ gsub("\\\\", "\\\\", $0); gsub("\"", "\\\"", $0); printf (NR == 1 ? "" : "\\n") $0 }')

# Format result into JSON object with single "value" field.
printf '{ "value": "%s" }' "${esc_output}"
