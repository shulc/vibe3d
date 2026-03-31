#!/bin/bash
set -xe

# Compile and run the HTTP endpoint test

echo "Compiling HTTP endpoint test..."

temp_dir=$(mktemp -d)

# Compile the test
for f in tests/test_*.d; do
    of=${f%.d}
    of=${of#tests/}
    dmd -Isource $f -of=$temp_dir/$of
done

./vibe3d &

sleep 1

for f in $(find $temp_dir -type f -perm +111); do
    $f
done

pkill vibe3d

rm -rf $temp_dir
