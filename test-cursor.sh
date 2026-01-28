#!/bin/bash
# Test DECSCUSR cursor style sequences

echo "Testing cursor styles..."
echo "Watch the cursor shape change!"
echo ""

echo "1. Blinking block (CSI 1 SP q)"
printf '\e[1 q'
sleep 2

echo "2. Steady block (CSI 2 SP q)"
printf '\e[2 q'
sleep 2

echo "3. Blinking underline (CSI 3 SP q)"
printf '\e[3 q'
sleep 2

echo "4. Steady underline (CSI 4 SP q)"
printf '\e[4 q'
sleep 2

echo "5. Blinking bar (CSI 5 SP q)"
printf '\e[5 q'
sleep 2

echo "6. Steady bar (CSI 6 SP q)"
printf '\e[6 q'
sleep 2

echo "0. Default (CSI 0 SP q)"
printf '\e[0 q'
sleep 2

echo ""
echo "Done! If cursor didn't change, DECSCUSR isn't working."
