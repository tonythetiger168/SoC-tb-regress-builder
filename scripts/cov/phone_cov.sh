#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Coverage closure of the hand-written phone SoC bench. The SoC glue
# (rtl/phone/) is built twice: with traffic models on the subsystem ports
# (TB=phone) and with the real subsystem IPs (TB=phone_real, +PHONE_REAL_IPS).
# Each build runs its part of regress/phone_cov_testlist.txt; the two merged
# coverage files are merged again and scored against scripts/cov/exclude/phone.txt.
#   bash scripts/cov/phone_cov.sh            -> build/cov/phone_both/score.json
# The phone_aon_arb FSMs are closed separately by their unit bench:
#   COV_SCOPE='rtl/phone/phone_aon_arb\.sv' bash scripts/cov/run_cov.sh phone_aon regress/phone_aon_testlist.txt
# Run the builds one at a time (two concurrent Verilator builds can run out of memory).
set -u
cd "$(dirname "$0")/../.."
LIST=${1:-regress/phone_cov_testlist.txt}
SCOPE='^rtl/phone/(phone_(soc_top|noc|iommu|ss_ips)\.sv)$'
COV_SCOPE="$SCOPE" bash scripts/cov/run_cov.sh phone "$LIST" || true
COV_SCOPE="$SCOPE" TOP=phone_tb_top bash scripts/cov/run_cov.sh phone_real "$LIST" || true
D=build/cov/phone_both; mkdir -p "$D"
verilator_coverage --write "$D/merged.dat" build/cov/phone/merged.dat build/cov/phone_real/merged.dat > /dev/null
python3 scripts/cov/score_cov.py "$D/merged.dat" --scope "$SCOPE" \
  --exclude scripts/cov/exclude/phone.txt --json "$D/score.json"
