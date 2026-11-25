import json,math,sys
import numpy as np
def load(p):
    d=json.load(open(p)); C,R,cs=d["cols"],d["rows"],d["cellCm"]
    F=np.full((R,C,3),np.nan); S=np.full((R,C,3),np.nan)
    for k,v in enumerate(d["cells"]):
        if v: F[k//C,k%C]=v
    for k,v in enumerate(d["sigma"]):
        if v: S[k//C,k%C]=v
    return F,S,cs
def contrast(F,cs,dist=100):
    R,C,_=F.shape; n=int(round(dist/cs)); out=np.full((R,C),np.nan); g=np.full((R,C),np.nan)
    dirs=[(n,0),(-n,0),(0,n),(0,-n),(n,n),(-n,-n),(n,-n),(-n,n)]
    for j in range(R):
        for i in range(C):
            f=F[j,i]
            if np.isnan(f[0]): continue
            ds=[];gs=[]
            for dj,di in dirs:
                jj,ii=j+dj,i+di
                if 0<=jj<R and 0<=ii<C and not np.isnan(F[jj,ii,0]):
                    dd=F[jj,ii]-f; L=math.hypot(dj,di)*cs/100
                    ds.append(math.sqrt((dd**2).mean())*(1/L if L>1.01 else 1)); gs.append(abs(dd[0])/L)
            if len(ds)>=2: out[j,i]=np.mean(ds); g[j,i]=np.max(gs)
    return out,g
def ambiguity(F,tol=3.0,minsep=300,cs=50):
    pts=np.argwhere(~np.isnan(F[:,:,0])); vals=F[~np.isnan(F[:,:,0])]
    res=[]
    for idx,(p,v) in enumerate(zip(pts,vals)):
        d=np.abs(vals-v).max(1)<=tol
        far=np.hypot(*(pts-p).T)*cs>=minsep
        res.append((d&far).sum()/len(pts))
    return np.array(res)
if __name__=="__main__":
    for lab,name in [("site-f54b0f","办公室"),("site-c9ff6a","Tesco"),("site-83f196","10月门店")]:
        F,S,cs=load(f"{lab}.full.json"); c,g=contrast(F,cs); a=ambiguity(F)
        m=~np.isnan(c); tot=F[:,:,0][~np.isnan(F[:,:,0])]
        sig=S[:,:,0][~np.isnan(S[:,:,0])]
        print(f"{name}: cells {np.sum(~np.isnan(F[:,:,0]))} ({np.sum(~np.isnan(F[:,:,0]))*cs*cs/1e4:.0f} m²) |B| P5-P95 {np.percentile(tot,5):.1f}-{np.percentile(tot,95):.1f} sd {tot.std():.1f}; "
              f"1m对比度 P10/P50/P90 {np.nanpercentile(c,10):.2f}/{np.nanpercentile(c,50):.2f}/{np.nanpercentile(c,90):.2f} µT; "
              f"<1µT {np.mean(c[m]<1):.0%} <2µT {np.mean(c[m]<2):.0%}; |∇B|max P50 {np.nanpercentile(g,50):.2f} µT/m; 格子σ|B| P50 {np.median(sig):.2f}; "
              f"3µT内长得像(≥3m外)占比 P50 {np.median(a):.1%} P90 {np.percentile(a,90):.1%}")
