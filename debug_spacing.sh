#!/bin/bash

TABLE_COUNT_WIDTH=8
TABLE_STATUS_WIDTH=13

echo "Header format:"
printf "│ %-${TABLE_COUNT_WIDTH}s │ %-${TABLE_STATUS_WIDTH}s ║\n" "Total" "Status"

echo "Content format:"
printf "│ %${TABLE_COUNT_WIDTH}s │ %-${TABLE_STATUS_WIDTH}s ║\n" "142" "✓ Clean"

echo "Character counts:"
printf "│ %-${TABLE_COUNT_WIDTH}s │ %-${TABLE_STATUS_WIDTH}s ║" "Total" "Status" | wc -c
printf "│ %${TABLE_COUNT_WIDTH}s │ %-${TABLE_STATUS_WIDTH}s ║" "142" "✓ Clean" | wc -c
