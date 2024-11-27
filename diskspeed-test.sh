#!/bin/bash

# Define test parameters
TEST_PATHS=(
  "/Users/shuv/testfile"
  "/Volumes/SMB_Test/testfile"
  "/Users/shuv/datashare/shares/downloads/testfile"
)

TESTS=(
  "seq_read"
  "seq_write"
  "rand_read"
  "rand_write"
)

BLOCK_SIZES=(
  "4k"
  "64k"
  "1M"
)

RUNTIME=60    # Duration for each test in seconds
SIZE="1G"     # Total size of data to read/write

# Loop over test paths
for TEST_PATH in "${TEST_PATHS[@]}"; do
  # Ensure the directory exists
  TEST_DIR=$(dirname "$TEST_PATH")
  if [ ! -d "$TEST_DIR" ]; then
    echo "Directory $TEST_DIR does not exist. Skipping."
    continue
  fi

  # Loop over tests
  for TEST_TYPE in "${TESTS[@]}"; do
    # Loop over block sizes
    for BS in "${BLOCK_SIZES[@]}"; do

      # Construct test name
      TEST_NAME="$(basename $TEST_DIR)_${TEST_TYPE}_bs${BS}"

      # Determine read/write pattern
      case $TEST_TYPE in
        "seq_read")
          RW="read"
          ;;
        "seq_write")
          RW="write"
          ;;
        "rand_read")
          RW="randread"
          ;;
        "rand_write")
          RW="randwrite"
          ;;
        *)
          echo "Unknown test type $TEST_TYPE"
          continue
          ;;
      esac

      # Run fio test
      fio --filename="$TEST_PATH" --size="$SIZE" --time_based --runtime="$RUNTIME" \
          --name="$TEST_NAME" --rw="$RW" --bs="$BS" --direct=1 --iodepth=32 \
          --numjobs=4 --output="${TEST_NAME}_output.txt"

      # Optional: Remove test file after write tests
      if [[ "$RW" == "write" || "$RW" == "randwrite" ]]; then
        rm -f "$TEST_PATH"
      fi

    done
  done
done
