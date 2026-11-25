import os
from pathlib import Path
import json,subprocess,sys,os,concurrent.futures as cf
EVAL=str(Path(__file__).resolve().parents[3]/"ios/HPASSKit/.build/release/hpass-eval")
W=os.environ.get("HPASS_PRIVATE","work/private")
def fold(site,held,builds,mode,tag,extra,runs):
    d=f"{W}/{site}"; out=f"./out/{tag}/{site}/{mode}"; os.makedirs(out,exist_ok=True)
    others=",".join("build/"+b for b in builds if b!=held)
    fl=["--motion","pdr-imu","--carry-motion","--rooms","--stationary-freeze","--no-ble"]+(["--oracle-start"] if mode=="track" else [])+extra
    cmd=[EVAL,"--map","map.json","--build",others,"--test","build/"+held,"--runs",str(runs),*fl,"--json",f"{out}/{held}.json","--track-out",f"{out}/{held}.csv","--field-out",f"{out}/{held}.field.json"]
    p=subprocess.run(cmd,cwd=d,capture_output=True,text=True)
    if p.returncode: print("FAIL",site,held,p.stdout[-500:],p.stderr[-500:])
    return p.stdout
if __name__=="__main__":
    tag=sys.argv[1]; modes=sys.argv[2].split(","); sites=sys.argv[3].split(","); extra=sys.argv[4:] ; runs=int(os.environ.get("RUNS","3"))
    man={s["label"]:s for s in json.load(open(W+"/manifest.json"))}
    jobs=[(s,h,man[s]["build"],m,tag,extra,runs) for s in sites for m in modes for h in man[s]["build"]]
    with cf.ThreadPoolExecutor(os.cpu_count()) as ex: list(ex.map(lambda a: fold(*a), jobs))
