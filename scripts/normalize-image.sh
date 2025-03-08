#!/usr/bin/env sh

# Script Name: normalize-image.sh
# Description: Removes the host/port and version (tag) parts of a container image name.
#              The script accepts an image name as input, normalizes it by stripping
#              out any registry host/port and version tag, and outputs the cleaned image name.
# Usage: ./normalize-image.sh <image_name>
#
# Examples:
#   $ ./normalize-image.sh "localhost:5000/myrepo/myimage:latest"
#   myrepo/myimage
#
#   $ ./normalize-image.sh "docker.io/library/ubuntu:18.04"
#   library/ubuntu
#
# Notes:
#   - Implemented with a hopefully portable awk script.
#   - Uses the same logic to detect image name segments as Docker does internally.

if [ $# -ne 1 ]; then
    echo "Error: $0 expects exactly one argument." >&2
    exit 1
fi

echo "$1" | awk '
    function join(arr, sep, start, end) {
        result = arr[start]
        for (k = start + 1; k <= end; k++)
            result = result sep arr[k]
        return result
    }

    function subarray(arr, len, start, end) {
        # transfer selected values to tmp
        for (k = start; k <= end; k++)
            tmp[k - start + 1] = arr[k]

        # delete old values
        for (k = 1; k <= len; k++)
            delete arr[k]

        # transfer new values from tmp to arr
        new_len = end - start + 1
        for (k = 1; k <= new_len; k++)
            arr[k] = tmp[k]

        return new_len
    }

    {
        # remove host and port
        parts_len = split($0, parts, "/")
        if (parts_len > 1) {
            if (parts[1] == "localhost" || parts[1] ~ /[.:]/) {
                parts_len = subarray(parts, parts_len, 2, parts_len)
            }
        }

        # remove version (aka tag)
        last_path_parts_len = split(parts[parts_len], last_path_parts, ":")
        if (last_path_parts_len > 1) {
            parts[parts_len] = join(last_path_parts, ":", 1, last_path_parts_len - 1)
        }

        print join(parts, "/", 1, parts_len)
    }
'
