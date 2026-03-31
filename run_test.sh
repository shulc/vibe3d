#!/bin/bash
set -e

# Compile and run the HTTP endpoint test

echo "Compiling HTTP endpoint test..."

# Compile the test
dmd -Isource tests/test_http_endpoint.d -of=test_http_endpoint


./vibe3d &
sleep 1
./test_http_endpoint

pkill vibe3d
