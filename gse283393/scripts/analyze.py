"""GSE283393 (SRP549060) re-analysis: gene-level quantification, QC, PCA, DE, ORA."""
import os, json, pickle, warnings
import numpy as np, pandas as pd
from scipy.stats import hypergeom
warnings.filterwarnings("ignore")

BASE = "/tmp/claude-0/-home-user-test/bba196d7-1d13-534d-8ebb-f255b447503c/scratchpad/geo"
RES = f"{BASE}/results"; os.makedirs(RES, exist_ok=True)
samples = pd.read_csv(f"{BASE}/samples.csv")
t2g = pd.read_csv(f"{BASE}/ref/tx2gene.tsv", sep="\t", header=None,
                  names=["tx", "gene_id", "gene_name"]).set_index("tx")

# ---------- 1. tximport (lengthScaledTPM) ----------
abund, length, counts, qc = {}, {}, {}, []
for r in samples.run:
    d = pd.read_csv(f"{BASE}/quants/{r}/quant.sf", sep="\t").set_index("Name").join(t2g, how="left")
    key = d.gene_name.fillna(d.gene_id)
    abund[r] = d.groupby(key).TPM.sum()
    counts[r] = d.groupby(key).NumReads.sum()
    w = d.TPM.groupby(key).transform("sum")
    frac = (d.TPM / w).where(w > 0)
    el = (d.EffectiveLength * frac).groupby(key).sum()
    length[r] = el.where(el > 0, d.EffectiveLength.groupby(key).mean())
    mi = json.load(open(f"{BASE}/quants/{r}/aux_info/meta_info.json"))
    qc.append(dict(run=r, fragments=mi["num_processed"], mapped=mi["num_mapped"],
                   mapping_rate=round(mi["percent_mapped"], 2)))

A = pd.DataFrame(abund).fillna(0)
L = pd.DataFrame(length).apply(lambda row: row.fillna(row.mean()), axis=1)
C = pd.DataFrame(counts).fillna(0)
cnt = A.mul(L.mean(axis=1), axis=0)
cnt = cnt * (C.sum(axis=0) / cnt.sum(axis=0))
cnt = cnt.round().astype(int)

qc = pd.DataFrame(qc).merge(samples[["run", "gsm", "group"]], on="run")
qc["genes_detected"] = [(cnt[r] >= 10).sum() for r in qc.run]
qc = qc[["run", "gsm", "group", "fragments", "mapped", "mapping_rate", "genes_detected"]]
qc.to_csv(f"{RES}/qc_summary.csv", index=False)
A.to_csv(f"{RES}/gene_tpm.csv"); cnt.to_csv(f"{RES}/gene_counts.csv")
print(qc.to_string(index=False))

# ---------- 2. DESeq2 ----------
from pydeseq2.dds import DeseqDataSet
from pydeseq2.ds import DeseqStats
meta = samples.set_index("run")[["group", "gsm"]].loc[cnt.columns]
keep = (cnt >= 10).sum(axis=1) >= 4
X = cnt[keep].T
print(f"\ngenes tested: {X.shape[1]} of {cnt.shape[0]}")
dds = DeseqDataSet(counts=X, metadata=meta, design="~group", refit_cooks=True, quiet=True)
dds.deseq2()
dds.vst(use_design=False)
vst = pd.DataFrame(dds.layers["vst_counts"], index=X.index, columns=X.columns)
vst.to_csv(f"{RES}/vst.csv")

contrasts = [("MNGC", "Macrophage"), ("MNGC", "Stroma"), ("Macrophage", "Stroma")]
de = {}
for a, b in contrasts:
    st = DeseqStats(dds, contrast=["group", a, b], quiet=True)
    st.summary()
    r = st.results_df.sort_values("padj")
    r.index.name = "gene"
    r.to_csv(f"{RES}/DE_{a}_vs_{b}.csv")
    de[(a, b)] = r
    sig = r[(r.padj < 0.05)]
    strong = sig[sig.log2FoldChange.abs() >= 2]
    print(f"{a} vs {b}: padj<0.05 = {len(sig)}  |LFC|>=2 & padj<0.05 = {len(strong)} "
          f"(up {int((strong.log2FoldChange>0).sum())}, down {int((strong.log2FoldChange<0).sum())})")

# ---------- 3. mean TPM per group & MNGC top genes ----------
grp = samples.set_index("run").group
tpm_g = A.groupby(grp, axis=1).mean()
tpm_g.to_csv(f"{RES}/tpm_group_mean.csv")
top = tpm_g.sort_values("MNGC", ascending=False).head(60)
top.to_csv(f"{RES}/MNGC_top60_expressed.csv")
print("\nTop 25 MNGC-expressed genes:\n", top.head(25).round(1).to_string())

# ---------- 4. over-representation analysis ----------
coll = pickle.load(open(f"{BASE}/genesets/msigdb_mouse.pkl", "rb"))
universe = set(X.columns)
def ora(genes, sets, universe, min_n=5, top=25):
    genes = set(genes) & universe; N = len(universe); K = len(genes)
    rows = []
    for name, members in sets.items():
        m = set(members) & universe
        if len(m) < min_n: continue
        k = len(m & genes)
        if k < 3: continue
        p = hypergeom.sf(k - 1, N, len(m), K)
        rows.append((name, len(m), k, k / len(m), p, ";".join(sorted(m & genes)[:25])))
    d = pd.DataFrame(rows, columns=["set", "set_size", "overlap", "ratio", "pval", "genes"])
    if not len(d): return d
    d = d.sort_values("pval")
    d["padj"] = np.minimum(1, d.pval * len(d))
    return d.head(top)

use = {k: coll[k] for k in ["C5:GO:BP", "C5:GO:CC", "H", "C2:CP:KEGG", "C2:CP:REACTOME"] if k in coll}
allsets = {f"{k}|{n}": v for k, s in use.items() for n, v in s.items()}
ora_out = {}
for (a, b), r in de.items():
    sig = r[(r.padj < 0.05) & (r.log2FoldChange.abs() >= 2)]
    for direction, sub in [("up", sig[sig.log2FoldChange > 0]), ("down", sig[sig.log2FoldChange < 0])]:
        o = ora(sub.index, allsets, universe)
        tag = f"{a}_vs_{b}_{direction}"
        o.to_csv(f"{RES}/ORA_{tag}.csv", index=False)
        ora_out[tag] = o
        print(f"\n== ORA {tag} (n={len(sub)}) ==")
        if len(o): print(o[["set", "set_size", "overlap", "pval", "padj"]].head(10).to_string(index=False))

pickle.dump({"de": de, "ora": ora_out}, open(f"{RES}/analysis.pkl", "wb"))
print("\nDONE")
