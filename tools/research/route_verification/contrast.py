import os, sys, numpy as np, graph
from segments import Ref, pair_resid
dirs=sys.argv[1:]
segs=graph.load(dirs)
import os
cols=eval(os.environ.get("COLS","[3,4]"))
D=0.75
dirs8=[(D*np.cos(a),D*np.sin(a)) for a in np.arange(8)*np.pi/4]
rows=[]
for i,a in enumerate(segs):
    for j,b in enumerate(segs):
        if i==j or a["sess"]==b["sess"]: continue
        ref=Ref(b["a"][:,1:3],b["a"][:,cols]); f=a["a"][:,cols]; xy=a["a"][:,1:3]
        r0,ov=pair_resid(xy,f,ref)
        if r0 is None or ov<3: continue
        rs=[pair_resid(xy+np.array(d),f,ref)[0] for d in dirs8]
        rs=[r for r in rs if r is not None]
        if len(rs)<4: continue
        contrast=float(np.median(rs))-r0
        vals,m=ref.at(xy); V=np.array([vals[k] for k in range(len(xy)) if m[k]])
        fstd=float(np.mean(np.median(np.abs(V-np.median(V,0)),0)))*1.4826
        # detection: shift a by 1 m in 4 dirs, residual > 2.0?
        det=[]
        for d in ((1,0),(-1,0),(0,1),(0,-1)):
            r,_=pair_resid(xy+np.array(d),f,ref)
            if r is not None: det.append(r>2.0)
        rows.append((r0,contrast,fstd,np.mean(det) if det else np.nan,ov))
R=np.array(rows)
print("pairs",len(R))
print("r0 median %.2f; contrast median %.2f (P25 %.2f P75 %.2f); field std median %.2f"%(np.median(R[:,0]),np.median(R[:,1]),np.percentile(R[:,1],25),np.percentile(R[:,1],75),np.median(R[:,2])))
print("corr(contrast, fieldstd)=%.2f"%np.corrcoef(R[:,1],R[:,2])[0,1])
g=R[R[:,0]<=2.0]
for thr in (0.5,0.75,1.0):
    lo=g[g[:,1]<thr]; hi=g[g[:,1]>=thr]
    print(f"green pairs {len(g)}; contrast<{thr}: {len(lo)} pairs, 1 m shift flagged {np.nanmean(lo[:,3])*100:.0f}% ; >= : {len(hi)} pairs flagged {np.nanmean(hi[:,3])*100:.0f}%")
for thr in (1.5,2.5,3.5):
    lo=g[g[:,2]<thr]; hi=g[g[:,2]>=thr]
    print(f"   fieldstd<{thr}: {len(lo)} flagged {np.nanmean(lo[:,3])*100:.0f}% ; >=: {len(hi)} flagged {np.nanmean(hi[:,3])*100:.0f}%")
