#!/bin/bash
echo "=== Resize Test ==="
echo "1. Run: seq 1 50"
echo "2. Resize window smaller (fewer rows)"
echo "3. Resize window back to original"
echo "4. Try Shift+PageUp to scroll up"
echo "5. Check if missing numbers are in scrollback"
echo ""
seq 1 50
echo ""
echo "Now resize the window and check scrollback with Shift+PageUp"
