#!/bin/bash
# Test script for braille spinners in the terminal

echo "=== Braille Spinner Test ==="
echo ""

# Show all braille spinner frames
echo "Braille spinner frames:"
echo "⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏"
echo ""

# Animated spinner
echo "Animated spinner (press Ctrl+C to stop):"
spinner_frames="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

i=0
while true; do
    frame="${spinner_frames:$i:1}"
    printf "\r  %s Loading..." "$frame"
    i=$(( (i + 1) % 10 ))
    sleep 0.1
done
