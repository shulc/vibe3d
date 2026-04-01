#!/bin/bash
set -xe


# Compile and run the HTTP endpoint test

echo "Compiling HTTP endpoint test..."

temp_dir=$(mktemp -d)

# Compile the test
for f in tests/test_*.d; do
    of=${f%.d}
    of=${of#tests/}
    dmd -unittest $f -w -of=$temp_dir/$of
done

dub build
./vibe3d 2>run.log &

while true; do
    if grep "HTTP server started on port 8080" -q run.log; then
        break;
    fi
    sleep 1
done

for f in $(find $temp_dir -type f -perm +111); do
    $f
done

pkill vibe3d

rm -rf $temp_dir
