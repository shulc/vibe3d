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
./vibe3d --test 2>run.log &

while true; do
    if grep "HTTP server started on port 8080" -q run.log; then
        break;
    fi
    sleep 1
done

# Run all compiled test binaries (skip .obj files produced on Windows)
for f in $temp_dir/test_*; do
    case "$f" in *.obj) continue;; esac
    case "$f" in *.o) continue;; esac
    $f
done

# Kill vibe3d cross-platform (pkill on macOS/Linux, taskkill on Windows)
if command -v pkill &>/dev/null; then
    pkill vibe3d
else
    cmd /c "taskkill /IM vibe3d.exe /F"
fi

rm -rf $temp_dir
