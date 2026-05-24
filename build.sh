#!/usr/bin/env bash
set -xe
ulimit -n 10240
dub build
