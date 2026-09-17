# -*- coding: utf-8 -*-
"""Build the self-contained HTML report for the GSE283393 re-analysis."""
import base64, io, os, pandas as pd, numpy as np

BASE = "/tmp/claude-0/-home-user-test/bba196d7-1d13-534d-8ebb-f255b447503c/scratchpad/geo"
FIG, RES = f"{BASE}/results/figures", f"{BASE}/results"
OUT = "/home/user/test/gse283393/index.html"

def img(name, caption):
    def b64(mode):
        with open(f"{FIG}/{name}.{mode}.png", "rb") as f:
            return base64.b64encode(f.read()).decode()
    return (f'<figure class="fig">'
            f'<img class="only-light" src="data:image/png;base64,{b64("light")}" alt="{caption}">'
            f'<img class="only-dark" src="data:image/png;base64,{b64("dark")}" alt="{caption}">'
            f'<figcaption>{caption}</figcaption></figure>')

def table(df, cls="", floatfmt=None, index=False):
    d = df.copy()
    if floatfmt:
        for c in d.columns:
            if pd.api.types.is_float_dtype(d[c]): d[c] = d[c].map(floatfmt)
    return d.to_html(index=index, classes=f"tbl {cls}", border=0, escape=False, na_rep="")

samples = pd.read_csv(f"{BASE}/samples.csv")
qc = pd.read_csv(f"{RES}/qc_summary.csv")
mk = pd.read_csv(f"{RES}/marker_panel.csv")
pw = pd.read_csv(f"{RES}/pathway_level_summary.csv")
top = pd.read_csv(f"{RES}/MNGC_top60_expressed.csv", index_col=0)

de_stats = []
for k, lab in [("MNGC_vs_Macrophage", "MNGC vs 卵巣マクロファージ"),
               ("MNGC_vs_Stroma", "MNGC vs ストローマ"),
               ("Macrophage_vs_Stroma", "卵巣マクロファージ vs ストローマ")]:
    r = pd.read_csv(f"{RES}/DE_{k}.csv", index_col=0)
    tested = r.padj.notna().sum(); sig = r[r.padj < 0.05]; st = sig[sig.log2FoldChange.abs() >= 2]
    de_stats.append(dict(比較=lab, 検定遺伝子数=tested, padj005=len(sig),
                         強い変動=len(st), 上昇=int((st.log2FoldChange > 0).sum()),
                         低下=int((st.log2FoldChange < 0).sum())))
de_stats = pd.DataFrame(de_stats).rename(columns={"padj005": "padj&lt;0.05",
                                                  "強い変動": "padj&lt;0.05 かつ |LFC|≥2"})

qc_disp = qc.rename(columns={"run": "SRA run", "gsm": "GEO sample", "group": "群",
                             "fragments": "フラグメント数", "mapped": "マップ数",
                             "mapping_rate": "マップ率 (%)", "genes_detected": "検出遺伝子数"})
qc_disp["フラグメント数"] = qc_disp["フラグメント数"].map("{:,}".format)
qc_disp["マップ数"] = qc_disp["マップ数"].map("{:,}".format)
qc_disp["検出遺伝子数"] = qc_disp["検出遺伝子数"].map("{:,}".format)
GJ = {"MNGC": "MNGC（多核巨細胞）", "Macrophage": "卵巣マクロファージ", "Stroma": "ストローマ"}
qc_disp["群"] = qc_disp["群"].map(GJ)

samp_disp = samples[["run", "gsm", "biosample", "experiment", "cell_type", "group"]].copy()
samp_disp["群"] = samp_disp.group.map(GJ)
samp_disp = samp_disp.drop(columns=["group"]).rename(
    columns={"run": "SRA run", "gsm": "GEO sample", "biosample": "BioSample",
             "experiment": "SRA experiment", "cell_type": "SRA 記載の cell type"})

mk_disp = mk.rename(columns={"gene": "遺伝子", "MNGC": "MNGC (TPM)", "Mac": "マクロファージ (TPM)",
                             "Stroma": "ストローマ (TPM)", "lfc_vs_Mac": "log2FC vs Mac",
                             "padj_vs_Mac": "padj vs Mac", "lfc_vs_Str": "log2FC vs Str",
                             "padj_vs_Str": "padj vs Str"})
if "note" in mk_disp: mk_disp = mk_disp.drop(columns=["note"])

pw_disp = pw.rename(columns={"gene_set": "遺伝子セット", "contrast": "比較", "n_genes": "遺伝子数",
                             "median_LFC": "log2FC 中央値", "median_LFC_excl_mt": "同（mt- 除く）",
                             "pct_sig_up": "有意に上昇 (%)", "pct_sig_down": "有意に低下 (%)"})
top_disp = top.head(30).round(1).reset_index().rename(
    columns={"gene_name": "遺伝子", "MNGC": "MNGC", "Macrophage": "マクロファージ", "Stroma": "ストローマ"})

HTML = f"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>GSE283393 再解析レポート</title>
<style>
  :root {{
    color-scheme: light;
    --surface: #f5f5f7; --card: #ffffff; --ink: #1d1d1f; --ink2: #52514e;
    --line: #e6e5e1; --accent: #2a78d6; --accent2: #eb6834; --accent3: #1baf7a;
    --warn-bg: #fdf3ea; --warn-line: #eb6834; --code-bg: #f2f2f0;
  }}
  @media (prefers-color-scheme: dark) {{
    :root:not([data-theme="light"]) {{
      color-scheme: dark;
      --surface: #111110; --card: #1a1a19; --ink: #ffffff; --ink2: #c3c2b7;
      --line: #34332f; --accent: #3987e5; --accent2: #d95926; --accent3: #199e70;
      --warn-bg: #2a1f17; --warn-line: #d95926; --code-bg: #232321;
    }}
  }}
  :root[data-theme="dark"] {{
    color-scheme: dark;
    --surface: #111110; --card: #1a1a19; --ink: #ffffff; --ink2: #c3c2b7;
    --line: #34332f; --accent: #3987e5; --accent2: #d95926; --accent3: #199e70;
    --warn-bg: #2a1f17; --warn-line: #d95926; --code-bg: #232321;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Hiragino Sans',
                 'Noto Sans JP', Roboto, sans-serif;
    line-height: 1.75; color: var(--ink); background: var(--surface);
    margin: 0; padding: 16px;
  }}
  .container {{ max-width: 980px; margin: 0 auto; }}
  header.hero {{
    background: var(--card); border-radius: 18px; padding: 28px 24px; margin-bottom: 20px;
    box-shadow: 0 4px 14px rgba(0,0,0,.07);
  }}
  h1 {{ font-size: 1.75rem; margin: 0 0 6px; letter-spacing: .01em; }}
  .sub {{ color: var(--ink2); font-size: .95rem; margin: 0; }}
  .card {{
    background: var(--card); border-radius: 18px; padding: 24px; margin-bottom: 20px;
    box-shadow: 0 4px 14px rgba(0,0,0,.07);
  }}
  h2 {{ font-size: 1.3rem; margin: 0 0 14px; padding-bottom: 8px; border-bottom: 2px solid var(--accent); }}
  h3 {{ font-size: 1.05rem; margin: 22px 0 8px; color: var(--ink); }}
  p {{ margin: 10px 0; }}
  ul, ol {{ padding-left: 1.3em; }}
  li {{ margin: 6px 0; }}
  .kpis {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; margin: 16px 0 4px; }}
  .kpi {{ border: 1px solid var(--line); border-radius: 12px; padding: 14px; }}
  .kpi .v {{ font-size: 1.5rem; font-weight: 700; display: block; }}
  .kpi .l {{ font-size: .82rem; color: var(--ink2); }}
  .tblwrap {{ overflow-x: auto; margin: 12px 0; }}
  table.tbl {{ border-collapse: collapse; width: 100%; font-size: .86rem; }}
  table.tbl th, table.tbl td {{ border-bottom: 1px solid var(--line); padding: 7px 10px; text-align: right; white-space: nowrap; }}
  table.tbl th {{ text-align: right; color: var(--ink2); font-weight: 600; }}
  table.tbl th:first-child, table.tbl td:first-child {{ text-align: left; }}
  table.tbl tr:hover td {{ background: rgba(42,120,214,.07); }}
  .fig {{ margin: 18px 0; }}
  .fig img {{ max-width: 100%; height: auto; border-radius: 10px; display: block; }}
  figcaption {{ color: var(--ink2); font-size: .85rem; margin-top: 8px; }}
  .only-dark {{ display: none; }}
  @media (prefers-color-scheme: dark) {{
    :root:not([data-theme="light"]) .only-light {{ display: none; }}
    :root:not([data-theme="light"]) .only-dark {{ display: block; }}
  }}
  :root[data-theme="dark"] .only-light {{ display: none; }}
  :root[data-theme="dark"] .only-dark {{ display: block; }}
  .note {{ background: var(--warn-bg); border-left: 4px solid var(--warn-line);
           border-radius: 8px; padding: 14px 16px; margin: 16px 0; font-size: .92rem; }}
  code {{ background: var(--code-bg); padding: 2px 6px; border-radius: 5px; font-size: .88em; }}
  pre {{ background: var(--code-bg); padding: 14px; border-radius: 10px; overflow-x: auto; font-size: .82rem; }}
  a {{ color: var(--accent); }}
  .tag {{ display: inline-block; font-size: .76rem; padding: 3px 10px; border-radius: 999px;
          border: 1px solid var(--line); color: var(--ink2); margin-right: 6px; }}
  footer {{ color: var(--ink2); font-size: .82rem; text-align: center; padding: 10px 0 30px; }}
</style>
</head>
<body>
<div class="container">

<header class="hero">
  <h1>GSE283393 再解析レポート</h1>
  <p class="sub">加齢卵巣の多核巨細胞（MNGC）レーザーキャプチャー RNA-seq ／ マウス 12 検体を生データから再定量</p>
  <p class="sub" style="margin-top:10px">
    <span class="tag">SRA study SRP549060</span>
    <span class="tag">BioProject PRJNA1193574</span>
    <span class="tag">GSM8661341–GSM8661352</span>
    <span class="tag">Mus musculus</span>
  </p>
</header>

<section class="card">
  <h2>1. まず結論</h2>
  <ul>
    <li><b>データセットの正体</b>：加齢マウス卵巣から <b>レーザーキャプチャーマイクロダイセクション（LCM）</b> で切り出した
        <b>多核巨細胞（MNGC）</b>・<b>非 MNGC ストローマ</b>と、若齢マウス卵巣から F4/80 磁気ビーズで分離した
        <b>初代卵巣マクロファージ</b>を比較した bulk RNA-seq。各群 4 検体、計 12 検体です。</li>
    <li><b>再解析の方法</b>：GEO の配布カウント表には到達できない環境だったため、SRA の生リードを取得し、
        マウス GRCm38 に対して salmon で独立に再定量 → DESeq2 で群間比較しました。</li>
    <li><b>再現性</b>：論文（Converse ら, PLOS Biology 2025）の主要所見はほぼすべて再現しました。
        <b>Gpnmb</b> は MNGC でマクロファージ比 <b>+4.7 log2FC</b>、<b>CD3 複合体（Cd3d/e/g・Cd247）</b>は
        <b>+5.6〜+9.4 log2FC</b> と極めて強く上昇します。</li>
    <li><b>独立に見つかった注意点</b>：MNGC とマクロファージの比較は<b>検体調製法の違いと交絡</b>しています。
        ミトコンドリア転写産物の割合が LCM 由来検体（MNGC 15.2%、ストローマ 15.5%）と
        分離細胞（マクロファージ 1.4%）で 10 倍以上違い、PC1（分散の 44%）はこの軸に一致します。
        「MNGC は酸化的リン酸化が高い」という解釈はこの交絡を織り込んで読む必要があります。</li>
  </ul>
</section>

<section class="card">
  <h2>2. データセットの同定根拠</h2>
  <p>この実行環境では NCBI（GEO・Entrez・SRA の web/FTP）への通信が組織のネットワークポリシーで遮断されていました。
     そこで GEO のページを読む代わりに、<b>AWS Open Data 上の SRA 公開メタデータ</b>
     （<code>s3://sra-pub-metadata-us-east-1</code>、2026-09-16 スナップショット、全 44,249,638 run）を
     Parquet のまま横断検索し、該当 study を同定しました。</p>
  <ol>
    <li>PLOS Biology 本文の Data availability は「transcriptomic raw files and gene count files can be found at GEO Accession: …」と記載
        （PMC 経由の本文では accession のリンク文字列が欠落）。</li>
    <li>SRA メタデータ全走査 → マウス・NovaSeq X Plus・Northwestern Feinberg・2024-12-03 公開の study <b>SRP549060</b> が該当。</li>
    <li>その 12 検体の属性が <code>cell type = Multinucleated giant cell / Stroma / priamary macrophage</code>（原文ママの誤記を含む）
        各 4 検体、<code>tissue = Ovary</code>、<code>genotype = WT</code> で、論文の方法と完全に一致。
        公開日 2024-12-03 は bioRxiv プレプリント公開日と同日です。</li>
  </ol>
  <div class="note">
    <b>限界</b>：GEO accession <code>GSE283393</code> と SRA study <code>SRP549060</code> の対応は、
    上記の状況証拠（論文記述・検体構成・公開日・所属機関）からの推定です。
    NCBI に到達できないため、GEO のページ上で直接照合してはいません。
    ネットワークが通る環境なら <code>https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=GSE283393</code> で 1 分で確認できます。
  </div>
</section>

<section class="card">
  <h2>3. 実験デザイン</h2>
  <div class="tblwrap">{table(samp_disp)}</div>
  <p>MNGC とストローマは 18–20 か月齢 C57BL/6J の凍結卵巣切片から LCM で採取、
     マクロファージは 6–12 週齢マウス卵巣の酵素消化 → F4/80 陽性選択で取得されています。
     ライブラリは SMART-Seq v4 + Nextera XT、NovaSeq X Plus でペアエンド 2×50 bp。</p>
</section>

<section class="card">
  <h2>4. 再解析パイプライン</h2>
  <pre>SRA (.sra, AWS Open Data)  →  fasterq-dump 3.2.1  →  FASTQ (paired)
        ↓
salmon 1.10.0  selective alignment  (GRCm38 / Ensembl, 109,609 transcripts, k=31, --seqBias --gcBias)
        ↓
tximport 相当（lengthScaledTPM）で遺伝子レベルに集約
        ↓
PyDESeq2 0.5.4  (design ~group, Wald 検定, Benjamini–Hochberg)
        ↓
MSigDB（マウス ortholog 変換済み 32,667 セット）で超幾何検定による ORA</pre>
  <p>論文は STAR + htseq-count + DESeq2 という構成です。定量器が違うため個々の数値は一致しませんが、
     方向性と効果量を独立に検証する目的には十分です。</p>
</section>

<section class="card">
  <h2>5. 品質管理</h2>
  <div class="kpis">
    <div class="kpi"><span class="v">12 / 12</span><span class="l">解析に使えた検体</span></div>
    <div class="kpi"><span class="v">80–93%</span><span class="l">マッピング率</span></div>
    <div class="kpi"><span class="v">3,200–4,100 万</span><span class="l">フラグメント数／検体</span></div>
    <div class="kpi"><span class="v">17,322</span><span class="l">検定対象遺伝子</span></div>
  </div>
  <div class="tblwrap">{table(qc_disp)}</div>
  <p>LCM 由来検体（MNGC・ストローマ）のマップ率が 80–90%、分離細胞（マクロファージ）が 93% 前後で、
     凍結組織由来 RNA のほうがわずかに低く出ています。除外が必要な検体はありません。</p>
</section>

<section class="card">
  <h2>6. 全体構造：3 集団はきれいに分かれる</h2>
  {img("pca", "主成分分析。変動の大きい上位 2,000 遺伝子の分散安定化値を使用。PC1 は検体調製法（LCM 組織 vs 分離細胞）、PC2 が MNGC とストローマを分ける軸に対応します。")}
  <p>PC1（44%）はマクロファージと LCM 検体（MNGC・ストローマ）を分け、PC2（23%）が MNGC をストローマから分離します。
     3 群とも 4 検体がまとまっており、外れ値はありません。</p>
</section>

<section class="card">
  <h2>7. 発現変動遺伝子</h2>
  <div class="tblwrap">{table(de_stats)}</div>
  {img("volcano_MNGC_vs_Macrophage", "MNGC と初代卵巣マクロファージの比較。赤＝MNGC で上昇、青＝低下（いずれも padj&lt;0.05 かつ |log2FC|≥2）。")}
  {img("volcano_MNGC_vs_Stroma", "MNGC と非 MNGC ストローマの比較。")}
  <p>論文は MNGC vs マクロファージで p≤0.05 の DEG を 5,436 個、|log2FC|≥2 で上昇 1,239・低下 1,390 と報告しています。
     本再解析では padj&lt;0.05 で 4,937 個、|log2FC|≥2 で上昇 1,387・低下 1,041 と、定量器が違うにもかかわらず同程度の規模になりました。</p>
</section>

<section class="card">
  <h2>8. MNGC で最も高発現の遺伝子</h2>
  <div class="tblwrap">{table(top_disp)}</div>
  <p>上位には <b>Ftl1 / Fth1</b>（鉄貯蔵）、<b>Apoe</b>（脂質代謝）、<b>Ctsd / Ctss</b>（リソソーム性プロテアーゼ）、
     <b>Lgals3 / Cd63 / B2m / Cd74 / H2-D1</b>（免疫）、<b>mt-</b> 群（電子伝達系）が並びます。
     論文が手作業で分類した 7 つの生物学的プロセス（鉄恒常性・抗酸化・アポトーシス細胞の除去・好気的電子伝達・
     脂質代謝・タンパク質分解・免疫）と、同じ顔ぶれが独立に再現されました。</p>
</section>

<section class="card">
  <h2>9. マーカー遺伝子による検証</h2>
  {img("marker_heatmap", "マーカーパネルの遺伝子ごと z スコア。列は検体、赤が高発現、青が低発現。")}
  <div class="tblwrap">{table(mk_disp)}</div>
  <h3>読みどころ</h3>
  <ul>
    <li><b>Gpnmb</b>：MNGC 1,307 TPM に対しマクロファージ 92、ストローマ 17。論文が提唱する MNGC マーカーを強く支持します。</li>
    <li><b>CD3 複合体</b>：<code>Cd3d +7.2</code>、<code>Cd3e +7.8</code>、<code>Cd3g +9.4</code>、<code>Cd247 +5.6</code>（vs マクロファージ、いずれも padj&lt;0.001）。
        MNGC 領域に T 細胞が入り込んでいるという論文の解釈と整合します。</li>
    <li><b>Cd8a</b>：論文では有意差なしとされていますが、本再解析では上昇が有意でした（log2FC +6.8、padj 4.1×10⁻⁴）。
        ただし発現量自体が 3.1 TPM と低く、解釈には注意が要ります。</li>
    <li><b>破骨細胞様の融合・分解プログラム</b>：<b>Acp5・Mmp12・Ctsk・Atp6v0d2・Trem2</b> がいずれも MNGC で 3–5 log2FC 上昇。</li>
    <li><b>マクロファージ側の遺伝子</b>：<b>Csf1r</b> は MNGC で低下（−1.4）、<b>Adgre1</b>（F4/80）は差なし。
        一方ストローマに対しては両方とも有意に高く、MNGC がマクロファージ系列であることは裏づけられます。</li>
  </ul>
</section>

<section class="card">
  <h2>10. パスウェイ解析</h2>
  {img("ora_MNGC_vs_Macrophage_up", "MNGC で上昇した遺伝子の濃縮解析（上位 12 セット）。数字は「重なり数 / セットサイズ」。")}
  {img("ora_MNGC_vs_Macrophage_down", "MNGC で低下した遺伝子の濃縮解析（上位 12 セット）。")}
  <p>上昇側は <b>T 細胞受容体複合体</b>・<b>適応免疫応答</b>・<b>リンパ球と非リンパ球の免疫調節的相互作用</b>・
     <b>ファゴサイトーシス認識</b>が並び、低下側は <b>組織発生</b>・<b>細胞遊走</b>・<b>形態形成</b>が占めます。
     これは論文の「MNGC は免疫シグナル伝達に特化し、マクロファージに比べて表現型の可塑性が低い」という記述をそのまま支持します。</p>
  <h3>主要プロセスを遺伝子セット単位で見る</h3>
  <div class="tblwrap">{table(pw_disp)}</div>
  <ul>
    <li><b>リソソーム</b>はマクロファージ比（+0.37）でもストローマ比（+0.81）でも上昇しており、<b>MNGC 固有</b>の特徴といえます。</li>
    <li><b>ファゴサイトーシス・アポトーシス細胞の除去</b>はストローマ比では上昇しますが、マクロファージ比では中央値ほぼ 0。
        すなわち<b>マクロファージ系列に共通</b>の機能であって、MNGC を特徴づけるものではありません。</li>
    <li><b>タンパク質分解・脂質代謝</b>もセット全体ではマクロファージ比でわずかに<b>低下</b>側。
        個別のカテプシン類が強く上がる一方で、プロセス全体としては MNGC 特異的ではないという読み方になります。</li>
    <li><b>酸化的リン酸化</b>は KEGG セットでマクロファージ比 +1.16（mt- 遺伝子を除いても +0.97）と上昇しますが、
        ストローマ比では −0.31。次項の交絡と切り離せません。</li>
  </ul>
</section>

<section class="card">
  <h2>11. 解釈上の注意点</h2>
  <div class="note">
    <b>検体調製法と群が完全に交絡しています。</b>
    MNGC とストローマは凍結組織からの LCM、マクロファージは新鮮組織の酵素消化＋磁気ビーズ分離です。
    ミトコンドリア転写産物の割合は MNGC 15.2%、ストローマ 15.5% に対しマクロファージ 1.4% と 10 倍以上違い、
    これは細胞種の違いではなく調製法の違いを強く示唆します。
    MNGC とマクロファージの差の一部（とくに酸化的リン酸化や電子伝達系）は、この技術的差分を拾っている可能性があります。
  </div>
  <ul>
    <li><b>年齢も交絡</b>：MNGC・ストローマは 18–20 か月齢、マクロファージは 6–12 週齢。論文も MNGC の混入を避ける意図と明記していますが、
        加齢の効果と細胞種の効果は分離できません。</li>
    <li><b>LCM は純粋な単一細胞集団ではありません</b>。CD3 シグナルは、MNGC 自体の発現と、
        MNGC 網目構造に入り込んだ T 細胞の両方を反映します。論文もこの点は免疫染色で切り分けています。</li>
    <li><b>n=4/群</b>。効果量の大きい比較には十分ですが、小さい差の検出力は限られます。</li>
    <li><b>本再解析は GEO 配布のカウント表とは別のパイプライン</b>です。遺伝子ごとの数値は論文の補足表と一致しません。
        一致を求める場合は GEO の gene count ファイルを直接使ってください。</li>
  </ul>
</section>

<section class="card">
  <h2>12. 生成物</h2>
  <ul>
    <li><code>data/gene_counts.csv.gz</code> — 遺伝子 × 検体のカウント行列（lengthScaledTPM 由来）</li>
    <li><code>data/gene_tpm.csv.gz</code> — 遺伝子 × 検体の TPM</li>
    <li><code>data/DE_*.csv</code> — 3 通りの比較の DESeq2 結果（全遺伝子）</li>
    <li><code>data/ORA_*.csv</code> — 上昇／低下遺伝子の濃縮解析結果</li>
    <li><code>data/marker_panel.csv</code>, <code>data/pathway_level_summary.csv</code>, <code>data/qc_summary.csv</code>, <code>data/samples.csv</code></li>
    <li><code>scripts/</code> — 同定・定量・解析・作図の全スクリプト</li>
  </ul>
</section>

<section class="card">
  <h2>13. 出典</h2>
  <ul>
    <li>Converse A, Perry MJ, Dipali SS, ほか. <i>Multinucleated giant cells are hallmarks of ovarian aging with unique
        immune and degradation-associated molecular signatures.</i> PLOS Biology 23(6):e3003204, 2025.
        <a href="https://doi.org/10.1371/journal.pbio.3003204">DOI</a>（PubMed 経由で取得）</li>
    <li>プレプリント：bioRxiv 2024.12.03.626649. <a href="https://doi.org/10.1101/2024.12.03.626649">DOI</a></li>
    <li>解説：Ahmed AA, Pangas SA. <i>The aging ovary stands on the shoulders of giant multinucleated cells.</i>
        PLOS Biology 23(6):e3003216, 2025. <a href="https://doi.org/10.1371/journal.pbio.3003216">DOI</a></li>
    <li>書誌情報は PubMed から取得しました。配列データは NCBI SRA（AWS Open Data 経由）、
        参照ゲノムは Illumina iGenomes の Ensembl GRCm38、遺伝子セットは MSigDB 7.5.1（babelgene でマウスに変換）です。</li>
  </ul>
</section>

<footer>再解析実施日 2026-09-17 ／ salmon 1.10.0 + PyDESeq2 0.5.4</footer>
</div>
</body>
</html>
"""
os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, "w", encoding="utf-8").write(HTML)
print("wrote", OUT, round(os.path.getsize(OUT) / 1e6, 2), "MB")
