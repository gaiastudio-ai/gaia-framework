#!/usr/bin/env bash
# NEGATIVE-CONTROL fixture — deliberately contains a hardcoded credential
# pattern so the audit's TC-PUB-11 grep MUST FAIL on this file. NOT a real
# adapter. NEVER moved out of tests/fixtures/.
TOKEN="AKIA0123456789ABCDEF"
echo "$TOKEN"
