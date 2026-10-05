#!/usr/bin/env python3
"""Install exact official Nim Linux x86-64 assets with fixed SHA-256 pins.

2.2.12 digest is also published by GitHub's official release API. The older
2.2.0 asset predates that API field; its pin was recorded from the official
asset. Neither compiler is bundled with the runtime library.
"""
import argparse,hashlib,json,pathlib,tarfile,urllib.request,sys
PINS={
 '2.2.0':('2024-10-02-version-2-2-78983f1876726a49c69d65629ab433ea1310ece1','942e047879fd81193b2ff3c105436a0c5016800c4e97864f90039ae204f89ded'),
 '2.2.12':('2026-09-08-version-2-2-8e8fbf60693418dc95bb0d762fd660231d08a583','7df1611449a6842af69322aa2c1206942982650a5f6bc0d37bc8ec109932f638')}
def install(version,destination):
 tag,digest=PINS[version];destination=pathlib.Path(destination).resolve();destination.mkdir(parents=True,exist_ok=True)
 url=f'https://github.com/nim-lang/nightlies/releases/download/{tag}/nim-{version}-linux_x64.tar.xz'
 archive=destination/f'nim-{version}.tar.xz'
 if not archive.exists():
  with urllib.request.urlopen(url,timeout=120) as response:
   data=response.read(64*1024*1024+1)
  if len(data)>64*1024*1024:raise RuntimeError('Toolchain archive exceeds download budget')
  archive.write_bytes(data)
 actual=hashlib.sha256(archive.read_bytes()).hexdigest()
 if actual!=digest:raise RuntimeError('Official toolchain checksum mismatch')
 with tarfile.open(archive) as tar:
  for member in tar.getmembers():
   path=pathlib.PurePosixPath(member.name)
   if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0]!=f'nim-{version}':raise RuntimeError('Unsafe archive member')
  tar.extractall(destination,filter='data')
 report={'version':version,'url':url,'sha256':actual,'binary':str(destination/f'nim-{version}/bin/nim')}
 (destination/f'nim-{version}-receipt.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--version',choices=PINS,required=True);p.add_argument('--tools',required=True);a=p.parse_args();install(a.version,a.tools)
