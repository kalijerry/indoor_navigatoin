import os
from pathlib import Path
import sys,math,glob,numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'route_verification')); sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
import appbias, load
from flat import load as lf, contrast
W=os.environ.get("HPASS_PRIVATE","work/private")
def circ_med(a):
    best=None
    for c in np.linspace(-math.pi,math.pi,361):
        d=np.abs((a-c+math.pi)%(2*math.pi)-math.pi); s=np.median(d)
        if best is None or s<best[0]: best=(s,c)
    return best[1]
for site,name in [("site-f54b0f","办公室"),("site-c9ff6a","Tesco"),("site-83f196","10月门店")]:
    F,S,cs=lf(f"{site}.full.json"); c,_=contrast(F,cs)
    allE=[];allC=[];allBh=[];allB=[]
    for d in sorted(glob.glob(f"{W}/{site}/build/*")):
        s=load.load_session(d)
        if s is None: continue
        a=s["a"]; ang=np.arctan2(a[:,6],a[:,5]); m=circ_med(ang)
        err=np.degrees((ang-m+math.pi)%(2*math.pi)-math.pi)
        ii=(a[:,1]*100//cs).astype(int); jj=(a[:,2]*100//cs).astype(int)
        cv=np.array([c[j,i] if 0<=j<c.shape[0] and 0<=i<c.shape[1] else np.nan for i,j in zip(ii,jj)])
        allE+=list(err); allC+=list(cv); allBh+=list(np.hypot(a[:,5],a[:,6])); allB+=list(a[:,3])
        print(f"  {name} {s['name']}: n={len(a)} |B|中位 {np.median(a[:,3]):.1f} Bh中位 {np.median(np.hypot(a[:,5],a[:,6])):.1f} 罗盘偏差 |e| P50 {np.median(np.abs(err)):.1f}° P90 {np.percentile(np.abs(err),90):.1f}°")
    E=np.abs(np.array(allE));C=np.array(allC);B=np.array(allB)
    print(f"{name}: 全部 |e| P50 {np.median(E):.1f}° P90 {np.percentile(E,90):.1f}°")
    for lo,hi,lab in [(-1,1,"<1"),(1,2,"1-2"),(2,4,"2-4"),(4,99,">4")]:
        k=(C>=lo)&(C<hi)
        if k.sum()>50: print(f"   1m对比度 {lab} µT: {k.mean():.0%} 样本, 罗盘偏差 P50 {np.median(E[k]):.1f}° P90 {np.percentile(E[k],90):.1f}°")
