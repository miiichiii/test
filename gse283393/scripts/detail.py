import re, json, pandas as pd, pyarrow.parquet as pq, requests
from httpfile import HTTPRangeFile
B="https://sra-pub-metadata-us-east-1.s3.amazonaws.com"
s=requests.Session()
keys=re.findall(r"<Key>(sra/metadata/[^<]+)</Key>", s.get(f"{B}/?list-type=2&prefix=sra/metadata/&max-keys=300",timeout=120).text)
r=pd.read_csv("cand_novaseqx.csv")
tgt=r[r.sra_study=="SRP549060"]
print("target runs:",len(tgt),"in rowgroups:",sorted(set(zip(tgt._file,tgt._rg))))
accs=set(tgt.acc)
rows=[]
for fi,rg in sorted(set(zip(tgt._file,tgt._rg))):
    f=HTTPRangeFile(f"{B}/{keys[fi]}",session=s); pf=pq.ParquetFile(f)
    df=pf.read_row_group(rg,columns=["acc","sra_study","bioproject","biosample","sample_acc","experiment",
        "sample_name","library_name","instrument","librarylayout","libraryselection","assay_type",
        "releasedate","mbases","mbytes","avgspotlen","center_name","jattr"]).to_pandas()
    rows.append(df[df.acc.isin(accs)])
    print("rg",fi,rg,"dl MB",round(f.nbytes/1e6,1),flush=True)
d=pd.concat(rows).sort_values("acc").reset_index(drop=True)
d.to_json("SRP549060_runs.json",orient="records",indent=1)
for _,x in d.iterrows():
    a=json.loads(x.jattr) if isinstance(x.jattr,str) else {}
    print("="*70)
    print(x.acc, x.experiment, x.sample_acc, x.biosample, "|", x.sample_name, "|", x.library_name)
    print("  mbases",x.mbases,"avgspotlen",x.avgspotlen,x.librarylayout,x.instrument,"released",x.releasedate)
    for k,v in a.items():
        print(f"   {k}: {str(v)[:160]}")
