#!/usr/bin/env python3
"""Read-only diagnostics for one explicitly selected macOS .app bundle."""
import argparse, base64, datetime as dt, hashlib, json, math, os, plistlib, subprocess, sys
from pathlib import Path

SCHEMA_VERSION = 1
CODESIGN = "/usr/bin/codesign"
REQUIRED = ("com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-write", "com.apple.security.files.bookmarks.app-scope", "com.apple.security.network.client")
DEBUG = "com.apple.security.get-task-allow"
def json_safe(v):
    if v is None or isinstance(v, (str, int, float, bool)): return v
    if isinstance(v, bytes): return {"type":"bytes", "base64":base64.b64encode(v).decode("ascii")}
    if isinstance(v, dict): return {str(k):json_safe(x) for k,x in v.items()}
    if isinstance(v, (list, tuple)): return [json_safe(x) for x in v]
    return {"type":type(v).__name__, "repr":repr(v)}
def item(state, reason, evidence=None):
    r={"status":state,"reason":reason}
    if evidence is not None: r["evidence"]=json_safe(evidence)
    return r
def inside(path, root):
    try: path.relative_to(root); return True
    except ValueError: return False
def text(v): return v.decode("utf-8", "replace") if isinstance(v,bytes) else "" if v is None else str(v)
def digest(path):
    h=hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda:f.read(1048576),b""): h.update(b)
    return h.hexdigest()
def run_command(argv, timeout=10, runner=subprocess.run):
    e={"argv":list(argv),"returncode":None,"stdout":"","stderr":"","timed_out":False,"unavailable":False,"exception":None}
    try:
        p=runner(argv,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding="utf-8",errors="replace",timeout=timeout,check=False)
        e.update(returncode=p.returncode,stdout=text(p.stdout),stderr=text(p.stderr))
    except subprocess.TimeoutExpired as x:
        e.update(timed_out=True,stdout=text(x.stdout),stderr=text(x.stderr),exception=f"TimeoutExpired: {x}")
    except FileNotFoundError as x: e.update(unavailable=True,exception=f"FileNotFoundError: {x}")
    except Exception as x: e["exception"]=f"{type(x).__name__}: {x}"
    return e
def parse_entitlements(output):
    at=output.find("<?xml")
    if at<0: at=output.find("<plist")
    if at<0: raise ValueError("codesign output did not contain an entitlement plist")
    value=plistlib.loads(output[at:].encode())
    if not isinstance(value,dict): raise ValueError("entitlements plist is not a dictionary")
    return value
def bool_value(d,k):
    if k not in d:return {"state":"missing"}
    if d[k] is True:return {"state":"true","value":True}
    if d[k] is False:return {"state":"false","value":False}
    return {"state":"invalid","value":json_safe(d[k])}
def safe_name(n): return isinstance(n,str) and n not in ("",".","..") and "/" not in n and "\\" not in n and "\0" not in n
def initial(app):
    return {"schema_version":1,"checked_at":dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z"),"input_path":str(app),"resolved_path":None,"report_complete":False,"checks":{},"rules":{},"tool_errors":[],"commands":[],"overall":item("UNKNOWN","diagnosis did not complete"),"not_checked":["certificate chain trust","notarization/Gatekeeper","actual sandbox file operations","ongoing TCC effectiveness","bookmark restoration across builds","GUI","D-C01a full-stage acceptance"]}
def finish(r, code=None):
    rules=[x for x in r["rules"].values() if x["status"]!="NOT_APPLICABLE"]
    unknown=bool(r["tool_errors"]) or any(x["status"]=="UNKNOWN" for x in rules); failed=any(x["status"]=="FAIL" for x in rules)
    if code is None: code=2 if unknown else 1 if failed else 0
    r["report_complete"]=(code!=2); r["overall"]=item("UNKNOWN" if code==2 else "FAIL" if code==1 else "PASS","required rules evaluated")
    return r,code
def structural(r,reason,evidence=None):
    r["checks"]["artifact"]=item("FAIL",reason,evidence);r["tool_errors"].append("artifact: "+reason);return finish(r,2)
def diagnose(app, timeout=10, runner=subprocess.run):
    r=initial(app)
    if isinstance(timeout,bool) or not isinstance(timeout,(int,float)) or not math.isfinite(timeout) or timeout<=0:
        r["tool_errors"].append("timeout: must be a finite positive number");return finish(r,2)
    try: bundle=Path(app).resolve(strict=True)
    except Exception as x:return structural(r,"input path cannot be resolved",f"{type(x).__name__}: {x}")
    r["resolved_path"]=str(bundle)
    if not bundle.is_dir():return structural(r,"app path is not a directory")
    try:
        contents=(bundle/"Contents").resolve(strict=True)
        if not inside(contents,bundle) or not contents.is_dir() or not os.access(contents,os.R_OK|os.X_OK):return structural(r,"Contents directory is missing, unreadable, or outside the bundle")
        plist=(contents/"Info.plist").resolve(strict=True)
        if not inside(plist,bundle):return structural(r,"Info.plist resolves outside the bundle")
        with plist.open("rb") as f: info=plistlib.load(f)
        if not isinstance(info,dict):return structural(r,"Info.plist is not a dictionary")
    except Exception as x:return structural(r,"Info.plist is missing, unreadable, or invalid",f"{type(x).__name__}: {x}")
    exe=info.get("CFBundleExecutable")
    if not safe_name(exe):return structural(r,"CFBundleExecutable is not a safe single filename")
    try:
        binary=(contents/"MacOS"/exe).resolve(strict=True)
        if not inside(binary,bundle) or not binary.is_file():return structural(r,"bundle executable is missing or resolves outside the bundle")
        r["checks"]["artifact"]=item("PASS","bundle structure is readable",{"info_plist_sha256":digest(plist),"executable_sha256":digest(binary),"CFBundleExecutable":exe,"CFBundleShortVersionString":info.get("CFBundleShortVersionString","missing"),"CFBundleVersion":info.get("CFBundleVersion","missing"),"CFBundleIdentifier":info.get("CFBundleIdentifier","missing")})
    except FileNotFoundError as x:return structural(r,"bundle executable is missing",f"{type(x).__name__}: {x}")
    except Exception as x:return structural(r,"bundle executable cannot be read",f"{type(x).__name__}: {x}")
    bundle_id=info.get("CFBundleIdentifier")
    r["rules"]["expected_bundle_identifier"]=item("PASS" if bundle_id=="first-test.D" else "FAIL","Info bundle identifier must be first-test.D",bundle_id)
    def command(name,argv):
        e=run_command(argv,timeout,runner);r["commands"].append({"name":name,**e})
        if e["exception"]:r["tool_errors"].append(f"{name}: {e['exception']}")
        return e
    display=command("codesign_display",[CODESIGN,"-dvv",str(bundle)]); shown=display["stdout"]+"\n"+display["stderr"]
    unsigned=display["returncode"] not in (None,0) and "not signed at all" in shown.lower()
    if unsigned:
        r["checks"]["signature"]=item("FAIL","codesign reports unsigned",{"classification":"unsigned"});r["rules"].update(signature_present=item("FAIL","application is unsigned"),integrity=item("NOT_APPLICABLE","application is unsigned"),entitlements=item("NOT_APPLICABLE","application is unsigned"));return finish(r)
    if display["returncode"]!=0 or display["exception"]:
        r["checks"]["signature"]=item("UNKNOWN","codesign display did not complete");r["rules"]["signature_present"]=item("UNKNOWN","signature evidence unavailable");return finish(r)
    identifier=next((line.split("=",1)[1] for line in shown.splitlines() if line.startswith("Identifier=")),None); sig=next((line for line in shown.splitlines() if line.startswith("Signature=")),"")
    classification="ad-hoc" if "adhoc" in sig.lower() else "certificate-backed" if "Authority=" in shown else "unknown"
    r["checks"]["signature"]=item("PASS","codesign display completed",{"identifier":identifier,"classification":classification});r["rules"]["signature_present"]=item("PASS","signature exists")
    r["rules"]["identifier_consistency"]=item("PASS" if isinstance(bundle_id,str) and identifier==bundle_id else "UNKNOWN" if identifier is None or not isinstance(bundle_id,str) else "FAIL","bundle and signature identifiers compared",{"bundle":bundle_id,"signature":identifier})
    verify=command("codesign_verify",[CODESIGN,"--verify","--strict",str(bundle)]);r["rules"]["integrity"]=item("PASS" if verify["returncode"]==0 else "UNKNOWN" if verify["exception"] else "FAIL","codesign strict verification")
    ent=command("codesign_entitlements",[CODESIGN,"-d","--entitlements",":-",str(bundle)])
    try:
        if ent["returncode"]!=0 or ent["exception"]:raise ValueError("codesign entitlement command did not complete")
        values=parse_entitlements(ent["stdout"]); evidence={k:bool_value(values,k) for k in REQUIRED+(DEBUG,)}
        for k,v in values.items():
            if k.startswith("com.apple.security.temporary-exception.") or k=="com.apple.security.cs.disable-library-validation":evidence[k]={"state":"present","value":json_safe(v)}
        invalid=[k for k in REQUIRED+(DEBUG,) if evidence[k]["state"]=="invalid"]; library=values.get("com.apple.security.cs.disable-library-validation")
        if library is not None and not isinstance(library,bool):invalid.append("com.apple.security.cs.disable-library-validation")
        if invalid:raise ValueError("selected entitlement values are not boolean: "+", ".join(invalid))
        r["checks"]["entitlements"]=item("PASS","entitlement plist parsed",evidence);r["rules"]["entitlements"]=item("PASS" if all(evidence[k]["state"]=="true" for k in REQUIRED) else "FAIL","required entitlement values evaluated")
        unsafe=[(k,v) for k,v in values.items() if (k.startswith("com.apple.security.temporary-exception.") and v not in (None,"",[],{},False)) or (k=="com.apple.security.cs.disable-library-validation" and v is True)]
        r["rules"]["unsafe_entitlements"]=item("FAIL" if unsafe else "PASS","temporary exceptions and library validation evaluated",unsafe)
    except Exception as x:
        r["checks"]["entitlements"]=item("UNKNOWN","entitlements cannot be reliably parsed",f"{type(x).__name__}: {x}");r["rules"]["entitlements"]=item("UNKNOWN","required entitlement evidence unavailable");r["tool_errors"].append(f"entitlements: {type(x).__name__}: {x}")
    return finish(r)
def write_report(path,report):
    target=Path(path); app=report.get("resolved_path")
    if target.exists() or (app and inside(target.resolve(strict=False),Path(app))):raise ValueError("report path exists or is inside the app bundle")
    with target.open("x",encoding="utf-8") as f:json.dump(report,f,indent=2,ensure_ascii=False);f.write("\n")
def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("--app",required=True);p.add_argument("--report");p.add_argument("--timeout",type=float,default=10,help=argparse.SUPPRESS);a=p.parse_args(argv)
    report,code=diagnose(a.app,a.timeout)
    if a.report:
        try:write_report(a.report,report)
        except Exception as x:report["tool_errors"].append(f"report: {type(x).__name__}: {x}");report,code=finish(report,2)
    print(json.dumps(report,ensure_ascii=False,indent=2));return code
if __name__=="__main__":sys.exit(main())
