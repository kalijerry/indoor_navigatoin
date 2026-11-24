"""Translation-only robust segment pose graph with magnetic-vector match edges."""
import sys, math, numpy as np
from segments import split, subsample, Ref, pair_resid
from load import load_session

COLS=[5,6,4]
OFF=[(dx*0.25,dy*0.25) for dx in range(-6,7) for dy in range(-6,7)]

def load(dirs):
    segs=[]
    for d in dirs:
        s=load_session(d)
        if s is None: continue
        for k,idx in enumerate(split(s["a"])):
            sub=subsample(s["a"],idx)
            segs.append({"name":f"{s['name'][-6:]}#{k}","sess":s["name"],"k":k,"a":s["a"][sub].copy()})
    return segs

def match(si, sj, cols=COLS):
    """offset o such that si shifted by o matches sj; returns (z, cov, rmin, r0, overlap) or None"""
    ref=Ref(sj["a"][:,1:3], sj["a"][:,cols])
    f=si["a"][:,cols]
    r0,ov0=pair_resid(si["a"][:,1:3], f, ref)
    if r0 is None or ov0<3: return None
    L=[]
    for o in OFF:
        r,ov=pair_resid(si["a"][:,1:3]+np.array(o), f, ref)
        if r is not None and ov>=0.7*ov0: L.append((o,r))
    o=np.array([x[0] for x in L]); r=np.array([x[1] for x in L])
    k=np.argmin(r); rmin=r[k]
    # pseudo-likelihood: residual ~ noise; weight exp(-(r-rmin)/tau)
    tau=0.08*rmin+0.05
    w=np.exp(-(r-rmin)/tau); w/=w.sum()
    mu=(w[:,None]*o).sum(0)
    d=o-mu; cov=(w[:,None,None]*np.einsum('ni,nj->nij',d,d)).sum(0)+np.eye(2)*0.15**2
    return dict(z=o[k], mu=mu, cov=cov, rmin=rmin, r0=r0, ov=ov0)

def solve(segs, edges, robust=True, c=2.5, iters=10):
    n=len(segs); N=2*n
    rows=[]  # (J (2xN), r target (2), info (2x2), kind, idx)
    def add(coef, target, info, kind, ref):
        J=np.zeros((2,N))
        for i,a in coef:
            J[:,2*i:2*i+2]+=a*np.eye(2)
        rows.append([J,np.array(target,float),info,kind,ref,1.0])
    for i,s in enumerate(segs):
        d=float(np.median(s["a"][:,8])); s["dAnchor"]=d
        sig=math.hypot(0.5,0.05*d)
        add([(i,1)],[0,0],np.eye(2)/sig**2,"prior",i)
    for i in range(n-1):
        a,b=segs[i],segs[i+1]
        if a["sess"]==b["sess"] and b["k"]==a["k"]+1:
            L=np.sum(np.linalg.norm(np.diff(a["a"][:,1:3],axis=0),axis=1))
            sig=0.05+0.03*L
            add([(i,-1),(i+1,1)],[0,0],np.eye(2)/sig**2,"cont",(i,i+1))
    for (i,j),m in edges.items():
        add([(i,1),(j,-1)],m["mu"],np.linalg.inv(m["cov"]),"mag",(i,j))
    x=np.zeros(N)
    for it in range(iters):
        H=np.zeros((N,N)); g=np.zeros(N)
        for R in rows:
            J,t,I,kind,ref,w=R
            H+=w*J.T@I@J; g+=w*J.T@I@t
        x=np.linalg.solve(H,g)
        if not robust: break
        for R in rows:
            if R[3]!="mag": continue
            e=R[0]@x-R[1]; m2=float(e@R[2]@e)
            R[5]=1.0/(1.0+m2/c**2)   # Cauchy
    cov=np.linalg.inv(H)
    out=[]
    for R in rows:
        if R[3]=="mag":
            e=R[0]@x-R[1]; out.append((R[4],float(e@R[2]@e),R[5]))
    return x.reshape(-1,2), cov, out

def run(dirs, inject=None):
    segs=load(dirs)
    if inject: inject(segs)
    edges={}
    for i,a in enumerate(segs):
        for j,b in enumerate(segs):
            if i<j and a["sess"]!=b["sess"]:
                m=match(a,b)
                if m: edges[(i,j)]=m
    x,cov,out=solve(segs,edges)
    return segs,edges,x,cov,out

if __name__=="__main__":
    segs,edges,x,cov,out=run(sys.argv[1:])
    print(len(segs),"segs",len(edges),"mag edges")
    deg={}
    for (i,j),m2,w in out:
        for k in (i,j): deg.setdefault(k,[]).append((m2,w))
    for i,s in enumerate(segs):
        sd=math.sqrt(max(cov[2*i,2*i],cov[2*i+1,2*i+1]))
        e=deg.get(i,[])
        print(f"{s['name']:>10} dA={s['dAnchor']:5.1f} corr=({x[i,0]:+.2f},{x[i,1]:+.2f}) |{np.hypot(*x[i]):.2f}| sd={sd:.2f} edges={len(e)} outl={sum(1 for m2,w in e if m2>9.21)}")
