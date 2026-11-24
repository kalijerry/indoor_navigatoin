import sys, math, numpy as np, graph
dirs=sys.argv[1:]
base=graph.run(dirs)
segs0,_,x0,_,_=base
sessions=sorted({s["sess"] for s in segs0})
for cols_name,cols in (("vector",[5,6,4]),("|B|,Bz",[3,4])):
    graph.COLS[:]=cols
    if cols_name!="vector": segs0,_,x0,_,_=graph.run(dirs)
    for kind in ("rot4","shift1"):
        errs=[];errs_none=[]
        for target in sessions:
            inj={}
            def f(segs):
                ss=[s for s in segs if s["sess"]==target]
                p0=ss[0]["a"][0,1:3].copy()
                for s in ss:
                    if kind=="rot4":
                        th=math.radians(4); R=np.array([[math.cos(th),-math.sin(th)],[math.sin(th),math.cos(th)]])
                        new=(s["a"][:,1:3]-p0)@R.T+p0
                    else:
                        new=s["a"][:,1:3]+np.array([0.7,0.7])
                    d=new-s["a"][:,1:3]; s["a"][:,1:3]=new
                    inj[s["name"]]=d.mean(0)
            segs,edges,x,cov,out=graph.run(dirs,inject=f)
            has={k for (i,j) in edges for k in (i,j)}
            for i,s in enumerate(segs):
                if s["name"] in inj and i in has and np.hypot(*inj[s["name"]])>0.3:
                    errs.append(np.hypot(*(x[i]-x0[i]+inj[s["name"]])))
                    errs_none.append(np.hypot(*inj[s["name"]]))
        errs=np.array(errs);en=np.array(errs_none)
        print(f"{cols_name:7} {kind}: n={len(errs)} injected median {np.median(en):.2f} m -> after graph median {np.median(errs):.2f} m, P80 {np.percentile(errs,80):.2f}; improved {np.mean(errs<en)*100:.0f}%")
