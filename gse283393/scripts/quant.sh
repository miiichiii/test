#!/bin/bash
BASE=/tmp/claude-0/-home-user-test/bba196d7-1d13-534d-8ebb-f255b447503c/scratchpad/geo
SAL=$BASE/tools/salmon-latest_linux_x86_64
export LD_LIBRARY_PATH=$SAL/lib
FQD=$BASE/tools/env/bin/fasterq-dump
mkdir -p $BASE/work $BASE/quants
# wait for salmon index
while ! grep -q "^\[.*\] DONE" $BASE/build_ref.log 2>/dev/null; do sleep 20; done
echo "[$(date +%T)] index ready"
RUNS=$(tail -n +2 $BASE/samples.csv | cut -d, -f1)
for R in $RUNS; do
  if [ -s $BASE/quants/$R/quant.sf ]; then echo "[$(date +%T)] $R already done"; continue; fi
  cd $BASE/work
  echo "[$(date +%T)] $R download"
  curl -sS --retry 4 --retry-delay 5 -o $R.sra "https://sra-pub-run-odp.s3.amazonaws.com/sra/$R/$R" || { echo "DL FAIL $R"; continue; }
  echo "[$(date +%T)] $R fasterq-dump ($(du -h $R.sra | cut -f1))"
  rm -rf fqtmp; mkdir -p fqtmp
  $FQD --split-3 -e 4 -m 2000MB -t fqtmp -O . $R.sra >/dev/null 2>fqd.err || { echo "DUMP FAIL $R"; cat fqd.err; rm -f $R.sra; continue; }
  rm -f $R.sra; rm -rf fqtmp
  ls -la ${R}*.fastq
  echo "[$(date +%T)] $R salmon"
  $SAL/bin/salmon quant -i $BASE/ref/salmon_idx -l A -1 ${R}_1.fastq -2 ${R}_2.fastq \
     -p 4 --validateMappings --seqBias --gcBias -o $BASE/quants/$R > $BASE/quants/$R.salmon.log 2>&1
  grep -i "Mapping rate" $BASE/quants/$R/logs/salmon_quant.log | tail -1
  rm -f ${R}_1.fastq ${R}_2.fastq ${R}.fastq
  df -h / | tail -1
  echo "[$(date +%T)] $R COMPLETE"
done
echo "[$(date +%T)] ALL DONE"
