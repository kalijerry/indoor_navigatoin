import json,glob,sys,csv,math,os
import numpy as np
sys.path.insert(0,'.'); from flat import load,contrast
def summ(tag,site,mode,bins=False):
    E=[];W=[];C=[];U=[];fixed=0;tot=0;pts=0;refpts=0
    for f in sorted(glob.glob(f"out/{tag}/{site}/{mode}/*.json")):
        if f.endswith(".field.json"): continue
        for r in json.load(open(f)):
            tot+=1; e=r["errorsCm"]; E+=e; pts+=r["points"]; refpts+=r["refPoints"]
            if e: fixed+=1
        if bins:
            fp=f.replace(".json",".field.json"); F,S,cs=load(fp); c,_=contrast(F,cs)
            for row in csv.DictReader(open(f.replace(".json",".csv"))):
                if not row["est_x"] or row["converged"]!="1": continue
                ex,ey,rx,ry=map(float,(row["est_x"],row["est_y"],row["ref_x"],row["ref_y"]))
                i,j=int(rx//cs),int(ry//cs)
                cv=c[j,i] if 0<=j<c.shape[0] and 0<=i<c.shape[1] else np.nan
                W.append(math.hypot(ex-rx,ey-ry)); C.append(cv)
    E=np.array(E)
    s=f"{site} {mode}: n={len(E)} cov={pts/max(refpts,1):.2f} med {np.median(E):.0f} p90 {np.percentile(E,90):.0f} ≤1m {np.mean(E<=100):.0%} >5m {np.mean(E>500):.1%} fixed {fixed}/{tot}" if len(E) else f"{site} {mode}: no fixes"
    print(s)
    if bins and W:
        W=np.array(W);C=np.array(C)
        for lo,hi,lab in [(-1,1,"<1"),(1,2,"1-2"),(2,4,"2-4"),(4,99,">4")]:
            m=(C>=lo)&(C<hi)
            if m.sum(): print(f"   对比度 {lab} µT: {m.mean():.0%} 点, 误差中位 {np.median(W[m]):.0f} P90 {np.percentile(W[m],90):.0f}")
        m=np.isnan(C); print(f"   无磁场图: {m.mean():.0%} 点, 误差中位 {np.median(W[m]) if m.sum() else 0:.0f}")
if __name__=="__main__":
    tag=sys.argv[1]; b="-b" in sys.argv
    for site in ["site-f54b0f","site-c9ff6a","site-83f196"]:
        for mode in ["track","cold"]:
            if os.path.isdir(f"out/{tag}/{site}/{mode}"): summ(tag,site,mode,b)
