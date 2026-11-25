import os
from pathlib import Path
import sys,re,bisect,pathlib
sys.path.insert(0,str(Path(__file__).resolve().parents[2])); sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'route_verification'))
import magmap
from calibrate import read_csv
_orig=magmap.raw_field
def app_bias(d):
    L=open(pathlib.Path(d)/"log.txt").read()
    b=re.findall(r"存下本机磁力计偏置（\w+）：(-?\d+), (-?\d+), (-?\d+)",L)
    return tuple(float(x) for x in b[-1]) if b else None
def raw_field(dir_,t,cal):
    r=_orig(dir_,t,cal)
    bb=app_bias(dir_)
    if r is None or bb is None: return r
    field,bias,spread=r
    f2=[tuple(x[k]+bias[k]-bb[k] for k in range(3)) if x is not None else None for x in field]
    return f2,bb,spread
magmap.raw_field=raw_field
