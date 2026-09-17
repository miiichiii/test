# -*- coding: utf-8 -*-
"""Mafb and companion transcription factors across the three ovarian populations."""
import numpy as np, pandas as pd
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter, NullFormatter, LogLocator

NUM = FuncFormatter(lambda v, _: f"{v:g}")

BASE = "/home/user/test/gse283393"
D, F = f"{BASE}/data", f"{BASE}/figures"
THEME = {
 "light": dict(surface="#fcfcfb", ink="#0b0b0b", ink2="#52514e", grid="#e6e5e1",
               series=["#2a78d6", "#eb6834", "#1baf7a"]),
 "dark":  dict(surface="#1a1a19", ink="#ffffff", ink2="#c3c2b7", grid="#34332f",
               series=["#3987e5", "#d95926", "#199e70"]),
}
GROUPS = ["MNGC", "Macrophage", "Stroma"]
LABEL = {"MNGC": "MNGC", "Macrophage": "Ovarian macrophage", "Stroma": "Stroma"}

tpm = pd.read_csv(f"{D}/gene_tpm.csv.gz", index_col=0)
samples = pd.read_csv(f"{D}/samples.csv")
PANEL = ["Mafb", "Spi1", "Mef2c", "Nfatc1", "Fos", "Jun"]
SUB = {"Mafb": "macrophage identity", "Spi1": "PU.1, myeloid identity",
       "Mef2c": "macrophage identity", "Nfatc1": "osteoclast master regulator",
       "Fos": "immediate-early", "Jun": "immediate-early"}

def strip(ax, gene, t, show_legend=False):
    ax.set_facecolor(t["surface"])
    for s in ("top", "right"): ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(t["grid"]); ax.spines[s].set_linewidth(1)
    ax.tick_params(colors=t["ink2"], labelsize=8.5, length=3, width=1)
    rng = np.random.default_rng(7)
    for i, g in enumerate(GROUPS):
        runs = samples[samples.group == g].run
        y = np.maximum(tpm.loc[gene, runs].astype(float).values, 0.1)
        x = i + (rng.random(len(y)) - .5) * .28
        ax.scatter(x, y, s=62, color=t["series"][i], edgecolors=t["surface"],
                   linewidths=1.6, zorder=3, label=LABEL[g] if show_legend else None)
        ax.plot([i - .26, i + .26], [np.mean(y)] * 2, color=t["ink"], lw=1.8, zorder=4)
    ax.set_yscale("log")
    vals = np.maximum(tpm.loc[gene, samples.run].astype(float).values, 0.1)
    decades = np.log10(vals.max() / vals.min())
    ax.yaxis.set_major_formatter(NUM)
    if decades < 1.5:
        ax.yaxis.set_minor_locator(LogLocator(subs=(2., 3., 5.)))
        ax.yaxis.set_minor_formatter(NUM)
        ax.tick_params(axis="y", which="minor", labelsize=7.5, colors=t["ink2"])
    else:
        ax.yaxis.set_minor_formatter(NullFormatter())
    ax.set_xticks(range(3)); ax.set_xticklabels(["MNGC", "Mac", "Stroma"], fontsize=8.5)
    ax.set_xlim(-.55, 2.55)
    ax.grid(axis="y", color=t["grid"], lw=.8); ax.set_axisbelow(True)
    ax.set_title(f"{gene}", fontsize=11, loc="left", pad=14, color=t["ink"], weight="bold")
    ax.text(0, 1.02, SUB[gene], transform=ax.transAxes, fontsize=8,
            color=t["ink2"], va="bottom")

for mode, t in THEME.items():
    fig, axes = plt.subplots(2, 3, figsize=(8.4, 6.0))
    fig.patch.set_facecolor(t["surface"])
    for j, gene in enumerate(PANEL):
        strip(axes.flat[j], gene, t, show_legend=(j == 0))
    for ax in axes[:, 0]: ax.set_ylabel("TPM (log scale)", color=t["ink2"], fontsize=9)
    fig.suptitle("Mafb stays at macrophage level in MNGC; the immediate-early genes do not",
                 x=.012, ha="left", fontsize=12.5, color=t["ink"])
    h, l = axes.flat[0].get_legend_handles_labels()
    leg = fig.legend(h, l, frameon=False, fontsize=9, ncol=3, loc="lower center",
                     bbox_to_anchor=(.5, -.035))
    for txt in leg.get_texts(): txt.set_color(t["ink2"])
    fig.text(.012, -.05, "Horizontal bars are group means. Each dot is one animal (n=4 per group). Values below 0.1 TPM are drawn at 0.1.",
             fontsize=8.5, color=t["ink2"])
    fig.tight_layout(rect=[0, .02, 1, .96])
    fig.savefig(f"{F}/mafb_panel.{mode}.png", dpi=170, bbox_inches="tight",
                facecolor=t["surface"])
    plt.close(fig)
print("wrote", F)
