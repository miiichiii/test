import re, time
import pandas as pd, pyarrow.parquet as pq, requests
from httpfile import HTTPRangeFile
B="https://sra-pub-metadata-us-east-1.s3.amazonaws.com"
s=requests.Session()
keys=re.findall(r"<Key>(sra/metadata/[^<]+)</Key>", s.get(f"{B}/?list-type=2&prefix=sra/metadata/&max-keys=300",timeout=120).text)
COLS=["acc","sra_study","bioproject","organism","instrument","center_name","releasedate",
      "library_name","sample_name","assay_type","mbases","avgspotlen","librarylayout",
      "experiment","sample_acc","biosample","libraryselection","librarysource"]
out=[]; t0=time.time()
for fi,k in enumerate(keys):
    f=HTTPRangeFile(f"{B}/{k}",session=s); pf=pq.ParquetFile(f)
    for rg in range(pf.metadata.num_row_groups):
        df=pf.read_row_group(rg,columns=COLS).to_pandas()
        m=(df.organism.fillna("")=="Mus musculus") & \
          (df.instrument.fillna("").str.contains("NovaSeq X",case=False)) & \
          (df.librarysource.fillna("")=="TRANSCRIPTOMIC") & \
          (pd.to_datetime(df.releasedate,errors="coerce")>=pd.Timestamp("2024-11-01"))
        d=df[m].copy()
        if len(d):
            d["_file"]=fi; d["_rg"]=rg
            out.append(d)
    print(f"[{fi+1}/{len(keys)}] {round(time.time()-t0)}s rows={sum(len(x) for x in out)}",flush=True)
r=pd.concat(out)
r.to_csv("cand_novaseqx.csv",index=False)
print("TOTAL",len(r),"studies",r.sra_study.nunique())
g=r.groupby("sra_study").size().sort_values()
print(g[(g>=6)&(g<=24)].to_string())
