#!/usr/bin/env python3
"""Source-immutable verification staging, with no dependence on git or network."""
import argparse,hashlib,json,pathlib,shutil,zipfile,sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
MANIFEST='SOURCE-SHA256.json'
IGNORE={'.git','__pycache__','nimcache'}
def digest(p):return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def inventory(root):
 root=pathlib.Path(root).resolve();out={}
 for p in sorted(root.rglob('*')):
  if any(x in IGNORE for x in p.relative_to(root).parts):continue
  if p.is_symlink():raise RuntimeError('Source symlink is not supported: '+str(p))
  if p.is_file() and p.name!=MANIFEST:out[p.relative_to(root).as_posix()]=digest(p)
 return out
def verify(root):
 root=pathlib.Path(root).resolve();stored=json.loads((root/MANIFEST).read_text());actual=inventory(root)
 if stored.get('schema')!=1 or stored.get('files')!=actual:raise RuntimeError('Source manifest differs from current bytes or inventory')
 return {'status':'passed','files':len(actual),'manifestSha256':digest(root/MANIFEST),'sourceSha256':actual}
def main():
 p=argparse.ArgumentParser();p.add_argument('command',choices=['manifest','verify','stage']);p.add_argument('--root',type=pathlib.Path,default=ROOT);p.add_argument('--output',type=pathlib.Path);a=p.parse_args();root=a.root.resolve()
 if a.command=='manifest':
  (root/MANIFEST).write_text(json.dumps({'schema':1,'files':inventory(root)},indent=2,sort_keys=True)+'\n');print(json.dumps(verify(root)));return
 if a.command=='verify':print(json.dumps(verify(root)));return
 if a.output is None:raise RuntimeError('Staging requires output')
 output=a.output.resolve()
 if output==root or root in output.parents or output.exists():raise RuntimeError('Stage must be a new directory outside source')
 checked=verify(root);shutil.copytree(root,output,ignore=shutil.ignore_patterns(*IGNORE))
 if verify(output)!=checked:raise RuntimeError('Staged source differs')
 print(json.dumps({'status':'passed','source':str(output),**checked}))
if __name__=='__main__':main()
