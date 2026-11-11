#!/bin/bash
# Quick build for trying a change: debug, no tests. ./build.sh (release, tests) before committing.
cd "$(dirname "$0")" && TURNOVER_CONFIG=debug TURNOVER_SKIP_TESTS=1 ./build.sh "$@"
