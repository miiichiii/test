#!/bin/bash
set -euo pipefail
BASE=/tmp/claude-0/-home-user-test/bba196d7-1d13-534d-8ebb-f255b447503c/scratchpad/geo
cd $BASE/ref
echo "[$(date +%T)] gffread -> transcripts.fa"
$BASE/tools/gffread-0.12.7.Linux_x86_64/gffread -w transcripts.fa -g genome.fa genes.filt.gtf
echo "transcripts: $(grep -c '^>' transcripts.fa)"
echo "[$(date +%T)] tx2gene"
python3 - <<'PY'
import re
seen={}
for line in open('genes.filt.gtf'):
    c=line.split('\t')
    if len(c)<9 or c[2]!='exon': continue
    a=c[8]
    t=re.search(r'transcript_id "([^"]+)"',a); g=re.search(r'gene_id "([^"]+)"',a)
    n=re.search(r'gene_name "([^"]+)"',a)
    if t and g and t.group(1) not in seen:
        seen[t.group(1)]=(g.group(1), n.group(1) if n else g.group(1))
with open('tx2gene.tsv','w') as o:
    for t,(g,n) in seen.items(): o.write(f"{t}\t{g}\t{n}\n")
print("tx2gene rows",len(seen))
PY
rm -f genome.fa genome.fa.fai
echo "[$(date +%T)] salmon index"
LD_LIBRARY_PATH=$BASE/tools/salmon-latest_linux_x86_64/lib \
  $BASE/tools/salmon-latest_linux_x86_64/bin/salmon index -t transcripts.fa -i salmon_idx -k 31 -p 4 2>&1 | tail -8
rm -f genes.gtf genes.filt.gtf
echo "[$(date +%T)] DONE"; du -sh $BASE/ref; df -h / | tail -1
