import csv,glob,math,numpy as np
from flat import load
rng=np.random.default_rng(0)
def paths(site):
    out=[]
    for f in glob.glob(f"out/r8base/{site}/track/*.csv"):
        P=[(float(r["ref_x"]),float(r["ref_y"])) for r in csv.DictReader(open(f)) if r["run"]=="1" and r["ref_x"]]
        # resample every 50cm
        res=[P[0]]
        for p in P[1:]:
            if math.dist(p,res[-1])>=50: res.append(p)
        out.append(np.array(res))
    return out
def sample(F,cs,xy):
    i=(xy[:,0]//cs).astype(int); j=(xy[:,1]//cs).astype(int)
    ok=(i>=0)&(j>=0)&(i<F.shape[1])&(j<F.shape[0])
    v=np.full((len(xy),3),np.nan); v[ok]=F[j[ok],i[ok]]; return v
for site,name in [("site-f54b0f","办公室"),("site-c9ff6a","Tesco"),("site-83f196","10月门店")]:
    F,S,cs=load(f"{site}.full.json")
    cells=np.argwhere(~np.isnan(F[:,:,0]))*cs+cs/2  # (j,i)
    cand_t=cells[:,::-1]
    res={}
    for L in (5,10,20,30,40):
        n=int(L*2); amb=[]
        for P in paths(site):
            for s0 in range(0,max(len(P)-n,1),max(n//2,4)):
                seg=P[s0:s0+n]
                if len(seg)<n: continue
                obs=sample(F,cs,seg)
                if np.isnan(obs).any(): continue
                obs=obs+rng.normal(0,1.5,obs.shape); obs-=obs.mean(0)
                rel=seg-seg[-1]   # anchor at end point
                cnt=0;tot=0
                for a in np.radians(np.arange(0,360,15)):
                    c,s=math.cos(a),math.sin(a); r=rel@np.array([[c,s],[-s,c]])
                    for t in cand_t[::2]:
                        v=sample(F,cs,r+t)
                        if np.isnan(v).mean()>0.2: continue
                        m=~np.isnan(v[:,0]); vv=v[m]-v[m].mean(0); d=np.sqrt(((vv-obs[m])**2).mean())
                        tot+=1
                        if d<2.0 and np.linalg.norm(t-seg[-1])>300: cnt+=1
                amb.append(cnt/ max(tot,1))
        if amb: res[L]=(np.median(amb),np.mean(np.array(amb)>0),len(amb))
    print(name, "  ".join(f"{L} m: 长得像的候选 {v[0]*100:.2f}% / 有歧义 {v[1]:.0%} (n={v[2]})" for L,v in res.items()))
