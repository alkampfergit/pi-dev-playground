#!/usr/bin/env bash

# ROT13 is symmetric: run this script again on its output to decode it.
printf '%s\n' "$1" | tr 'A-Za-z' 'N-ZA-Mn-za-m'
