#!/bin/bash

# Test script to demonstrate the new Unicode table format

# Table constants
PADDING_LENGTH=26
TABLE_REPO_WIDTH=$PADDING_LENGTH  # Repository name column width
TABLE_COUNT_WIDTH=8               # Numeric count column width  
TABLE_STATUS_WIDTH=8              # Status column width (simplified for ASCII text)

# Table drawing functions
function draw_table_border() {
    local border_type="${1:-top}" # top, middle, bottom
    
    # Double-line outer border with mixed connectors (exactly as tested)
    case "$border_type" in
        "top")
            local left="╔" middle="╤" right="╗" horizontal="═"
            ;;
        "middle")
            local left="╟" middle="┼" right="╢" horizontal="─"
            ;;
        "bottom")
            local left="╚" middle="╧" right="╝" horizontal="═"
            ;;
    esac
    
    # Build horizontal line strings directly using sed (avoids tr Unicode issues)
    local repo_line
    local count_line  
    local status_line
    
    # Match the exact content width including padding spaces
    repo_line=$(printf "%*s" $((TABLE_REPO_WIDTH + 2)) "" | sed "s/ /$horizontal/g")
    count_line=$(printf "%*s" $((TABLE_COUNT_WIDTH + 2)) "" | sed "s/ /$horizontal/g")
    status_line=$(printf "%*s" $((TABLE_STATUS_WIDTH + 2)) "" | sed "s/ /$horizontal/g")
    
    printf "%s%s%s%s%s%s%s\n" \
        "$left" "$repo_line" "$middle" "$count_line" "$middle" "$status_line" "$right"
}

function draw_table_header() {
    printf "║ %-${TABLE_REPO_WIDTH}s │ %-${TABLE_COUNT_WIDTH}s │ %-${TABLE_STATUS_WIDTH}s ║\n" \
        "Repository" "Total" "Status"
}

function draw_table_row() {
    local repo="$1"
    local count="$2" 
    local status="$3"
    
    # Truncate repository name if it's longer than the allocated width
    local truncated_repo="$repo"
    if [[ ${#repo} -gt $TABLE_REPO_WIDTH ]]; then
        truncated_repo="${repo:0:$((TABLE_REPO_WIDTH-3))}..."
    fi
    
    printf "║ %-${TABLE_REPO_WIDTH}s │ %${TABLE_COUNT_WIDTH}s │ %-${TABLE_STATUS_WIDTH}s ║\n" \
        "$truncated_repo" "$count" "$status"
}

# Test the table output
echo "Testing Unicode Box-Drawing Table:"
echo

# Draw the table
draw_table_border "top"
draw_table_header
draw_table_border "middle"
draw_table_row "my-awesome-project" "142" "Clean"
draw_table_row "copr:copr.fedorainfracloud.org:wezfurlong:wezterm-nightly" "1" "Modified"
draw_table_row "experimental-features" "89" "Clean"
draw_table_row "documentation-site" "234" "Dirty"
draw_table_border "bottom"

echo
echo "Table formatting test complete!"
