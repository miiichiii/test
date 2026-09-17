"""Figures for the GSE283393 re-analysis. Renders each panel for light and dark surfaces."""
import os, pickle, numpy as np, pandas as pd
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap

BASE = "/tmp/claude-0/-home-user-test/bba196d7-1d13-534d-8ebb-f255b447503c/scratchpad/geo"
RES, FIG = f"{BASE}/results", f"{BASE}/results/figures"
os.makedirs(FIG, exist_ok=True)

THEME = {
 "light": dict(surface="#fcfcfb", ink="#0b0b0b", ink2="#52514e", grid="#e6e5e1",
               series=["#2a78d6", "#eb6834", "#1baf7a"], pos="#e34948", neg="#2a78d6",
               mid="#f0efec", nsg="#b8b7b1"),
 "dark":  dict(surface="#1a1a19", ink="#ffffff", ink2="#c3c2b7", grid="#34332f",
               series=["#3987e5", "#d95926", "#199e70"], pos="#e66767", neg="#3987e5",
               mid="#383835", nsg="#6b6a64"),
}
GROUPS = ["MNGC", "Macrophage", "Stroma"]
LABEL = {"MNGC": "MNGC", "Macrophage": "Ovarian macrophage", "Stroma": "Stroma"}

samples = pd.read_csv(f"{BASE}/samples.csv")
grp = samples.set_index("run").group
vst = pd.read_csv(f"{RES}/vst.csv", index_col=0)          # samples x genes
tpm = pd.read_csv(f"{RES}/gene_tpm.csv", index_col=0)     # genes x samples
de = {k: pd.read_csv(f"{RES}/DE_{k}.csv", index_col=0)
      for k in ["MNGC_vs_Macrophage", "MNGC_vs_Stroma", "Macrophage_vs_Stroma"]}

def style(ax, t):
    ax.set_facecolor(t["surface"])
    ax.figure.patch.set_facecolor(t["surface"])
    for s in ("top", "right"): ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(t["grid"]); ax.spines[s].set_linewidth(1)
    ax.tick_params(colors=t["ink2"], labelsize=9, length=3, width=1)
    ax.xaxis.label.set_color(t["ink2"]); ax.yaxis.label.set_color(t["ink2"])
    ax.title.set_color(t["ink"])

def save(fig, name, mode):
    fig.savefig(f"{FIG}/{name}.{mode}.png", dpi=170, bbox_inches="tight",
                facecolor=fig.get_facecolor())
    plt.close(fig)

# ---- 1. PCA ----
def pca_fig(mode):
    t = THEME[mode]
    v = vst.loc[[r for r in samples.run]]
    X = v.values - v.values.mean(0)
    sd = X.std(0); X = X[:, sd > 0]
    top = np.argsort(-X.std(0))[:2000]; X = X[:, top]
    U, S, Vt = np.linalg.svd(X, full_matrices=False)
    pc = U[:, :2] * S[:2]; var = (S**2 / (S**2).sum())[:2] * 100
    fig, ax = plt.subplots(figsize=(5.4, 4.2))
    style(ax, t)
    ax.axhline(0, color=t["grid"], lw=1, zorder=0); ax.axvline(0, color=t["grid"], lw=1, zorder=0)
    for i, g in enumerate(GROUPS):
        m = (grp.loc[v.index] == g).values
        ax.scatter(pc[m, 0], pc[m, 1], s=110, color=t["series"][i], label=LABEL[g],
                   edgecolors=t["surface"], linewidths=2, zorder=3)
        ax.annotate(LABEL[g], (pc[m, 0].mean(), pc[m, 1].mean()),
                    textcoords="offset points", xytext=(0, 16), ha="center",
                    fontsize=10, color=t["ink"], weight="bold")
    ax.set_xlabel(f"PC1 ({var[0]:.0f}% of variance)")
    ax.set_ylabel(f"PC2 ({var[1]:.0f}% of variance)")
    ax.set_title("Samples separate by cell population", fontsize=12, loc="left", pad=12)
    leg = ax.legend(frameon=False, fontsize=9, loc="best")
    for txt in leg.get_texts(): txt.set_color(t["ink2"])
    save(fig, "pca", mode)

# ---- 2. volcano ----
def volcano_fig(key, title, mode):
    t = THEME[mode]; r = de[key].dropna(subset=["padj"]).copy()
    r["y"] = -np.log10(r.padj.clip(lower=1e-300))
    sig = (r.padj < 0.05) & (r.log2FoldChange.abs() >= 2)
    fig, ax = plt.subplots(figsize=(5.6, 4.4)); style(ax, t)
    lfc = r.log2FoldChange.clip(-15, 15)
    ax.scatter(lfc[~sig], r.y[~sig], s=6, color=t["nsg"], alpha=.5, linewidths=0)
    up = sig & (r.log2FoldChange > 0); dn = sig & (r.log2FoldChange < 0)
    ax.scatter(lfc[up], r.y[up], s=9, color=t["pos"], linewidths=0,
               label=f"up in {key.split('_vs_')[0]} ({int(up.sum())})")
    ax.scatter(lfc[dn], r.y[dn], s=9, color=t["neg"], linewidths=0,
               label=f"down ({int(dn.sum())})")
    marks = {"Gpnmb": (10, -12), "Cd3e": (12, 8), "Mmp12": (12, 0), "Acp5": (-30, 12),
             "Ctss": (12, -6), "Adgre1": (10, 6), "Csf1r": (-38, -4), "Col1a1": (-40, 6)}
    lim = 15
    for g, off in marks.items():
        if g not in r.index: continue
        x, y = float(np.clip(r.loc[g, "log2FoldChange"], -lim, lim)), r.loc[g, "y"]
        ax.annotate(g, (x, y), fontsize=8.5, color=t["ink"], textcoords="offset points",
                    xytext=off, arrowprops=dict(arrowstyle="-", color=t["ink2"], lw=.8))
        ax.scatter([x], [y], s=30, facecolor="none", edgecolor=t["ink"], linewidths=1.1, zorder=5)
    ax.set_xlim(-lim, lim)
    ax.set_xlabel("log2 fold change (clipped to ±15)"); ax.set_ylabel("-log10 adjusted p")
    ax.set_title(title, fontsize=12, loc="left", pad=12)
    leg = ax.legend(frameon=False, fontsize=9, loc="upper left")
    for txt in leg.get_texts(): txt.set_color(t["ink2"])
    save(fig, f"volcano_{key}", mode)

# ---- 3. marker heatmap ----
PANEL = {
 "Macrophage identity": ["Adgre1", "Csf1r", "Ptprc", "Cd68", "Itgam", "Lyz2", "Mrc1"],
 "MNGC marker": ["Gpnmb", "Trem2", "Lgals3", "Acp5", "Mmp12", "Atp6v0d2", "Dcstamp"],
 "Lysosome / proteolysis": ["Ctsb", "Ctsd", "Ctsk", "Ctsl", "Ctss", "Ctsz", "Lamp1", "Hexb"],
 "Oxidative phosphorylation": ["Ndufa4", "Cox4i1", "Cox5a", "Atp5f1b", "Uqcrb", "Sdhb"],
 "Antioxidant / iron": ["Sod1", "Sod2", "Prdx1", "Hmox1", "Fth1", "Ftl1"],
 "T-cell markers": ["Cd3d", "Cd3e", "Cd3g", "Cd247", "Cd4", "Cd8a", "Lck"],
 "Stromal / ECM": ["Col1a1", "Col3a1", "Dcn", "Lum", "Pdgfrb"],
}
def heatmap_fig(mode):
    t = THEME[mode]
    cmap = LinearSegmentedColormap.from_list("div", [t["neg"], t["mid"], t["pos"]])
    genes, seps, labels = [], [], []
    for k, gs in PANEL.items():
        present = [g for g in gs if g in vst.columns]
        if not present: continue
        labels.append((k, len(genes) + len(present) / 2)); genes += present
        seps.append(len(genes))
    order = [r for g in GROUPS for r in samples[samples.group == g].run]
    M = vst.loc[order, genes].T
    Z = M.sub(M.mean(axis=1), axis=0).div(M.std(axis=1).replace(0, np.nan), axis=0).fillna(0)
    fig, ax = plt.subplots(figsize=(8.6, 0.26 * len(genes) + 2.3)); style(ax, t)
    im = ax.imshow(Z.values, aspect="auto", cmap=cmap, vmin=-2, vmax=2)
    ax.set_yticks(range(len(genes))); ax.set_yticklabels(genes, fontsize=8)
    ax.set_xticks(range(len(order)))
    ax.set_xticklabels([samples.set_index("run").gsm[r] for r in order], rotation=90, fontsize=7)
    for s in seps[:-1]: ax.axhline(s - .5, color=t["surface"], lw=2)
    for i in (4, 8): ax.axvline(i - .5, color=t["surface"], lw=2)
    for k, pos in labels:
        ax.text(len(order) + .4, pos - .5, k, fontsize=8, color=t["ink2"], va="center")
    for i, g in enumerate(GROUPS):
        ax.text(i * 4 + 1.5, -1.0, LABEL[g], ha="center", fontsize=9,
                color=t["series"][i], weight="bold")
    ax.set_title("Marker panel, per-gene z-score of variance-stabilised counts",
                 fontsize=11, loc="left", pad=22)
    cax = fig.add_axes([0.60, 1.008, 0.16, 0.007])
    cb = fig.colorbar(im, cax=cax, orientation="horizontal")
    cb.set_label("z-score", color=t["ink2"], fontsize=8, labelpad=4)
    cb.set_ticks([-2, 0, 2])
    cb.ax.xaxis.set_label_position("top")
    cb.ax.tick_params(colors=t["ink2"], labelsize=8, length=2)
    cb.outline.set_visible(False)
    for s in ("left", "bottom"): ax.spines[s].set_visible(False)
    ax.tick_params(length=0)
    save(fig, "marker_heatmap", mode)

# ---- 4. ORA bars ----
def ora_fig(tag, title, mode, n=12):
    t = THEME[mode]
    o = pd.read_csv(f"{RES}/ORA_{tag}.csv").head(n).iloc[::-1]
    if not len(o): return
    def clean(x):
        x = x.split("|", 1)[1]
        for p_ in ("GOBP_", "GOCC_", "GOMF_", "HALLMARK_", "REACTOME_", "KEGG_"):
            x = x.replace(p_, "")
        x = x.replace("_", " ").lower()
        return x if len(x) <= 56 else x[:55] + "\u2026"
    names = [clean(s) for s in o.set]
    y = np.arange(len(o)); val = -np.log10(o.pval.clip(lower=1e-300))
    fig, ax = plt.subplots(figsize=(7.4, .34 * len(o) + 1.6)); style(ax, t)
    ax.barh(y, val, height=.62, color=t["series"][0], linewidth=0)
    ax.set_yticks(y); ax.set_yticklabels(names, fontsize=8.5)
    for i, (v, k, s) in enumerate(zip(val, o.overlap, o.set_size)):
        ax.text(v + max(val) * .012, i, f"{k}/{s}", va="center", fontsize=8, color=t["ink2"])
    ax.set_xlabel("-log10 p (hypergeometric)")
    ax.set_title(title, fontsize=11, loc="left", pad=12)
    ax.grid(axis="x", color=t["grid"], lw=.8); ax.set_axisbelow(True)
    ax.spines["left"].set_visible(False); ax.tick_params(axis="y", length=0)
    ax.set_xlim(0, max(val) * 1.16)
    save(fig, f"ora_{tag}", mode)

for mode in ("light", "dark"):
    pca_fig(mode)
    volcano_fig("MNGC_vs_Macrophage", "MNGC versus primary ovarian macrophage", mode)
    volcano_fig("MNGC_vs_Stroma", "MNGC versus ovarian stroma", mode)
    heatmap_fig(mode)
    ora_fig("MNGC_vs_Macrophage_up", "Enriched in MNGC versus macrophage", mode)
    ora_fig("MNGC_vs_Macrophage_down", "Depleted in MNGC versus macrophage", mode)
print("figures written to", FIG)
