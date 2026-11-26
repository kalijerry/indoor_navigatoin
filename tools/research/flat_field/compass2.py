import os
from pathlib import Path
import sys,math,glob,numpy as np
import appbias, load
from compass import circ_med
W=os.environ.get("HPASS_PRIVATE","work/private")
for site,name in [("site-f54b0f","办公室"),("site-c9ff6a","Tesco"),("site-83f196","10月门店")]:
    E=[];B=[];D=[];S=[]
    for d in sorted(glob.glob(f"{W}/{site}/build/*")):
        s=load.load_session(d)
        if s is None or appbias.app_bias(d) is None: continue
        a=s["a"]; ang=np.arctan2(a[:,6],a[:,5]); m=circ_med(ang)
        err=np.degrees((ang-m+math.pi)%(2*math.pi)-math.pi)
        bh=np.hypot(a[:,5],a[:,6]); dip=np.degrees(np.arctan2(np.abs(a[:,4]),bh))
        # local stability: |B| change over +-1 s (~50 samples)
        tot=a[:,3]; st=np.array([np.ptp(tot[max(0,i-25):i+25]) for i in range(len(tot))])
        E+=list(err);B+=list(tot);D+=list(dip);S+=list(st)
    E=np.abs(E);B=np.array(B);D=np.array(D);S=np.array(S)
    Bref=np.median(B); Dref=np.median(D)
    print(f"{name}: n={len(E)} |B|中位 {Bref:.1f} 倾角中位 {Dref:.1f}°  全部 P50 {np.median(E):.1f}° P90 {np.percentile(E,90):.1f}°")
    for tb,td,ts in [(5,5,99),(3,3,99),(3,3,3),(2,2,2)]:
        k=(np.abs(B-Bref)<tb)&(np.abs(D-Dref)<td)&(S<ts)
        print(f"   门控 |ΔB|<{tb} |Δ倾角|<{td}° 1s起伏<{ts}: 保留 {k.mean():.0%}，P50 {np.median(E[k]):.1f}° P90 {np.percentile(E[k],90):.1f}°；其余 P50 {np.median(E[~k]):.1f}°")
