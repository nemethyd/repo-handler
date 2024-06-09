#!/usr/bin/bash

echo "Testing /dev/stdin - 1"
cat /dev/stdin

echo "Testing /dev/stdin - 2"
exec {fd}< /dev/stdin
if [[ $? -eq 0 ]]; then
  echo "/dev/stdin is accessible"
else
  echo "/dev/stdin is not accessible"
fi

