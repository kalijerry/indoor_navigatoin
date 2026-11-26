import os
from pathlib import Path
import sys,math,glob,numpy as np, appbias, load
W=os.environ.get("HPASS_PRIVATE","work/private"); CS=0.5
def sess(site):
    out=[]
    for d in sorted(glob.glob(f"{W}/{site}/build/*")):
        s=load.load_session(d)
        if s is None: continue
        a=s["a"]; xy=a[:,1:3]
        bh=np.hypot(a[:,5],a[:,6])
        out.append(dict(name=s["name"],xy=xy,S=np.stack([a[:,3],a[:,4],bh],1),V=np.stack([a[:,5],a[:,6],a[:,4]],1)))
    return out
def grid(ss,key,shape):
    acc=np.zeros(shape+(3,));n=np.zeros(shape)
    for s in ss:
        i=(s["xy"][:,0]/CS).astype(int); j=(s["xy"][:,1]/CS).astype(int)
        ok=(i>=0)&(j>=0)&(i<shape[1])&(j<shape[0])
        np.add.at(acc,(j[ok],i[ok]),s[key][ok]); np.add.at(n,(j[ok],i[ok]),1)
    G=np.full(shape+(3,),np.nan); m=n>=3; G[m]=acc[m]/n[m][:,None]; return G
def resample(xy,f,step=0.5):
    keep=[0]
    for k in range(1,len(xy)):
        if np.hypot(*(xy[k]-xy[keep[-1]]))>=step: keep.append(k)
    return xy[keep],f[keep]
def evaluate(site,L,key,rots=np.radians(np.arange(0,360,10))):
    ss=sess(site); allxy=np.concatenate([s["xy"] for s in ss]); shape=(int(allxy[:,1].max()/CS)+3,int(allxy[:,0].max()/CS)+3)
    res=[]
    for h in ss:
        G=grid([s for s in ss if s is not h],key,shape)
        cov=np.argwhere(~np.isnan(G[:,:,0]))
        if len(cov)<20: continue
        T=(cov[:,::-1]+0.5)*CS
        xy,f=resample(h["xy"],h[key]); n=int(L/0.5)
        for s0 in range(0,len(xy)-n,6):
            P=xy[s0:s0+n]; F=f[s0:s0+n].copy(); end=P[-1]; rel=P-end
            # truth must be on map
            ii=(P[:,0]/CS).astype(int); jj=(P[:,1]/CS).astype(int)
            if np.isnan(G[jj,ii,0]).mean()>0.2: continue
            best=[]
            for a in rots:
                c,sn=math.cos(a),math.sin(a); R=np.array([[c,-sn],[sn,c]])
                r=rel@R.T; Fo=F.copy()
                if key=="V": Fo[:,:2]=F[:,:2]@R.T
                pos=T[:,None,:]+r[None]
                gi=(pos[...,0]/CS).astype(int); gj=(pos[...,1]/CS).astype(int)
                ok=(gi>=0)&(gj>=0)&(gi<shape[1])&(gj<shape[0])
                gi=np.clip(gi,0,shape[1]-1); gj=np.clip(gj,0,shape[0]-1)
                M=G[gj,gi]; M[~ok]=np.nan
                valid=~np.isnan(M[...,0]); frac=valid.mean(1)
                Mm=np.where(valid[...,None],M,0); cnt=np.maximum(valid.sum(1),1)[:,None]
                mm=Mm.sum(1)/cnt; fm=(Fo[None]*valid[...,None]).sum(1)/cnt
                d=((Mm-mm[:,None])-(Fo[None]-fm[:,None]))*valid[...,None]
                rms=np.sqrt((d**2).sum((1,2))/(3*cnt[:,0]))
                rms[frac<0.8]=np.inf
                best.append(np.stack([rms,T[:,0],T[:,1],np.full(len(T),a)],1))
            B=np.concatenate(best); B=B[np.isfinite(B[:,0])]
            if not len(B): continue
            k=np.argmin(B[:,0]); dist=np.hypot(B[:,1]-end[0],B[:,2]-end[1])
            near=dist<=2.0; far=dist>=3.0
            if not near.any() or not far.any(): continue
            ok_best=dist[k]<=2.0
            ratio=B[far,0].min()/B[near,0].min()
            res.append((ok_best, ok_best and ratio>=1.25))
    r=np.array(res)
    return len(r), r[:,0].mean() if len(r) else np.nan, r[:,1].mean() if len(r) else np.nan
if __name__=="__main__":
    for site in sys.argv[1].split(","):
        for L in (5,10,15,20):
            for key in ("S","V"):
                n,b,u=evaluate(site,L,key)
                print(f"{site} {L:>2} m {'标量|B|,Bz,Bh' if key=='S' else '三轴矢量'}: 窗口 {n}，最像的就是真位置 {b:.0%}，且领先第二名 25% 以上 {u:.0%}",flush=True)
