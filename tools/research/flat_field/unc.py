import csv,glob,math,sys,numpy as np
from flat import load,contrast
tag=sys.argv[1]
for site in ["site-f54b0f","site-c9ff6a","site-83f196"]:
    R=[];C=[]
    for f in glob.glob(f"out/{tag}/{site}/track/*.csv"):
        F,S,cs=load(f.replace(".csv",".field.json")); c,_=contrast(F,cs)
        for r in csv.DictReader(open(f)):
            if not r["est_x"] or not r["unc_cm"]: continue
            e=math.hypot(float(r["est_x"])-float(r["ref_x"]),float(r["est_y"])-float(r["ref_y"])); u=float(r["unc_cm"])
            i,j=int(float(r["ref_x"])//cs),int(float(r["ref_y"])//cs)
            cv=c[j,i] if 0<=j<c.shape[0] and 0<=i<c.shape[1] else np.nan
            R.append((e,u));C.append(cv)
    R=np.array(R);C=np.array(C)
    print(site, f"err/1σ P50 {np.median(R[:,0]/R[:,1]):.2f}, 误差>2σ {np.mean(R[:,0]>2*R[:,1]):.0%}, unc中位 {np.median(R[:,1]):.0f}")
    for lo,hi,lab in [(-1,2,"<2"),(2,4,"2-4"),(4,99,">4"),(None,None,"无图")]:
        k=np.isnan(C) if lo is None else (C>=lo)&(C<hi)
        if k.sum()>30: print(f"   {lab}: err/1σ P50 {np.median(R[k,0]/R[k,1]):.2f} >2σ {np.mean(R[k,0]>2*R[k,1]):.0%}")
