import rdata, warnings, pandas as pd, pickle
warnings.filterwarnings('ignore')
m = rdata.conversion.convert(rdata.parser.parse_file('/tmp/_msigdbr/R/sysdata.rda'))
b = rdata.conversion.convert(rdata.parser.parse_file('/tmp/_babelgene/R/sysdata.rda'))
gs, gsg, genes = m['msigdbr_genesets'], m['msigdbr_geneset_genes'], m['msigdbr_genes']
for d in (gs, gsg, genes): d.columns = [str(c) for c in d.columns]
orth = b['orthologs_df']; orth.columns = [str(c) for c in orth.columns]
mo = orth[orth['taxon_id'] == 10090][['human_entrez','symbol','support_n']].copy()
mo['human_entrez'] = mo['human_entrez'].astype(str)
mo = mo.sort_values('support_n', ascending=False).drop_duplicates('human_entrez')
genes['gene_id'] = genes['gene_id'].astype(str)
gsg['gene_id'] = gsg['gene_id'].astype(str)
g2e = genes.set_index('gene_id')['human_entrez_gene'].astype(str).to_dict()
e2m = mo.set_index('human_entrez')['symbol'].to_dict()
gsg['entrez'] = gsg['gene_id'].map(g2e)
gsg['mouse'] = gsg['entrez'].map(e2m)
gsg = gsg.dropna(subset=['mouse'])
name = gs.set_index('gs_id')[['gs_name','gs_cat','gs_subcat']]
merged = gsg.join(name, on='gs_id')
coll = {}
for (cat, sub), d in merged.groupby(['gs_cat','gs_subcat'], dropna=False):
    key = f"{cat}:{sub}" if isinstance(sub, str) and sub else str(cat)
    sets = d.groupby('gs_name')['mouse'].apply(lambda s: sorted(set(s))).to_dict()
    sets = {k: v for k, v in sets.items() if 5 <= len(v) <= 2000}
    if sets: coll[key] = sets
for k, v in sorted(coll.items()): print(f"{k:18s} {len(v):6d} sets")
pickle.dump(coll, open('msigdb_mouse.pkl','wb'))
print("saved", sum(len(v) for v in coll.values()), "gene sets")
