#!/bin/bash
echo "=== Basic 16 colors ==="
for i in {0..15}; do printf "\e[48;5;${i}m  \e[0m"; done; echo
echo

echo "=== 256 color cube ==="
for i in {16..231}; do printf "\e[48;5;${i}m  \e[0m"; [ $(((i-15) % 36)) -eq 0 ] && echo; done
echo

echo "=== Grayscale ramp ==="
for i in {232..255}; do printf "\e[48;5;${i}m  \e[0m"; done; echo
echo

echo "=== True color gradients ==="
echo "Red:"
for i in $(seq 0 8 255); do printf "\e[48;2;${i};0;0m \e[0m"; done; echo
echo "Green:"
for i in $(seq 0 8 255); do printf "\e[48;2;0;${i};0m \e[0m"; done; echo
echo "Blue:"
for i in $(seq 0 8 255); do printf "\e[48;2;0;0;${i}m \e[0m"; done; echo
echo

echo "=== Foreground colors ==="
for i in {0..15}; do printf "\e[38;5;${i}m Color $i \e[0m"; done; echo
