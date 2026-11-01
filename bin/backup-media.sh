#!/usr/bin/env bash
# Copies the originals, which cannot be recreated, and the subtitles and uploaded posters to off-host storage with
# restic. The renditions can be made again from the originals (videoReprocess) and are left out to save space.
# RESTIC_REPOSITORY and RESTIC_PASSWORD_FILE must be set, e.g. in the environment of the cron job.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY}"
: "${RESTIC_PASSWORD_FILE:?set RESTIC_PASSWORD_FILE}"

# The originals, plus subtitles and uploaded posters, which live beside the renditions
restic backup --tag spexflix ./data/media/originals \
  --files-from <(find ./data/media/hls \( -path '*/subtitles/*' -o -name 'poster-uploaded.jpg' \) -type f)
restic forget --tag spexflix --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
