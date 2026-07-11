#!/bin/bash

set -e

RUN_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd $RUN_PATH

echo ----[ Flake Update ]----
nix --extra-experimental-features 'nix-command flakes' flake update

echo ----[ Operation completed successfully ]----
echo
echo Review the changes to flake.lock, then commit and push.
