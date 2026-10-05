#!/usr/bin/env python3
"""Unicode/binary files, exit status, stderr, and actual CLI output contracts."""
import argparse,hashlib,json,pathlib,subprocess,tempfile,base64,os
from native_support import strict_json,binding,require
from decoder_support import verify_png
from verify_reference import snapshot

def verify(binary,outdir):
 binary=pathlib.Path(binary).resolve();outdir=pathlib.Path(outdir).resolve();outdir.mkdir(parents=True,exist_ok=True)
 before=snapshot();report={'status':'running','binary':binding(binary),'sourceSha256':before,'processes':[]}
 def run(args,ok=True,code=None):
  p=subprocess.run([str(binary),*args],capture_output=True,timeout=30,cwd=outdir)
  row={'args':args,'exitCode':p.returncode,'stdoutBytes':len(p.stdout),'stdoutSha256':hashlib.sha256(p.stdout).hexdigest(),'stderrBytes':len(p.stderr),'stderrSha256':hashlib.sha256(p.stderr).hexdigest()};report['processes'].append(row)
  if ok:require(p.returncode==0 and not p.stderr,'CLI failed: '+p.stderr.decode(errors='replace'))
  else:
   require(p.returncode==2 and not p.stdout and p.stderr.endswith(b'\n'),'CLI failure protocol mismatch')
   if code:require(p.stderr.startswith((code+': ').encode()),'CLI error category mismatch: '+repr(p.stderr))
  return p.stdout
 try:
  text='日本語 é e\u0301 🙂\x00\n';textfile=outdir/'入力 🙂.txt';textfile.write_text(text)
  binarydata=bytes(range(256));bytefile=outdir/'binary.bin';bytefile.write_bytes(binarydata)
  args=['--text-file',str(textfile),'--eci','26','--mode','byte','--format','json']
  q=strict_json(run(args));require(q['diagnostics']['input_bytes']==len(text.encode()),'CLI Unicode length')
  output=outdir/'画像 QR.png';run(args[:-2]+['--format','png','--output',str(output)])
  png,luma,dim=verify_png(output.read_bytes().hex(),q['matrix'],8);require(dim==(len(q['matrix'])+8)*8,'Implicit scale differs')
  require(run(args[:-2]+['--format','png'])==png,'PNG stdout differs from file')
  q2=strict_json(run(['--bytes-file',str(bytefile),'--format','json']))
  require(q2['diagnostics']['input_bytes']==256,'Binary length')
  matrix=strict_json(run(['--bytes-file',str(bytefile),'--format','matrix']));require(matrix==q2['matrix'],'Matrix CLI differs')
  dataurl=run(['--text','A','--format','png-data-url']).strip();require(dataurl.startswith(b'data:image/png;base64,'),'PNG URL prefix')
  require(base64.b64decode(dataurl.split(b',')[1],validate=True)==run(['--text','A','--format','png']),'PNG URL roundtrip')
  plan=strict_json(run(['--text','12345','--plan']));require(plan['ok'] and not plan['diagnostics']['codewords_built'],'Planning must be arithmetic')
  sa=strict_json(run(['--bytes-file',str(bytefile),'--structured-append','--version','2','--format','json']));require(2<=sa['total']<=16 and len(sa['symbols'])==sa['total'],'SA CLI')
  require(b'Usage:' in run(['--help']),'Missing help')
  require(b'SpecQR Nim 0.1.0' in run(['--version-info']),'Missing version')
  cases=[([], 'INVALID_INPUT'),(['--text','A','--text','B'],'INVALID_INPUT'),(['--text','A','--unknown'],'INVALID_INPUT'),(['--text','A','--format','gif'],'INVALID_OUTPUT'),(['--text','A','--ecc','oops'],'INVALID_ECC_LEVEL'),(['--text','A','--scale','99999999999999999999999'],'INVALID_INPUT'),(['--text','A','--version','41'],'INVALID_VERSION'),(['--text','A','--print-dpi','nan'],'INVALID_INPUT'),(['--text','A','--foreground','url(x)'],'INVALID_COLOR'),(['--text','A','--mode','numeric'],'INVALID_MODE'),(['--text','a'*3000],'DATA_TOO_LONG'),(['--text-file',str(outdir/'does-not-exist')],'IO_ERROR'),(['--text','A','--output',str(outdir/'absent'/'output.svg')],'IO_ERROR'),(['--text','A','--plan','--structured-append'],'INVALID_MODE'),(['--text','A','--structured-append'],'INVALID_OUTPUT')]
  cases += [(["--text","A","--version","0"],"INVALID_VERSION"),(["--text","A","--mask","-1"],"INVALID_INPUT"),(["--text","A","--eci","-1"],"INVALID_ECI")]
  for args,code in cases:run(args,False,code)
  invalid=outdir/'malformed.txt';invalid.write_bytes(b'\xe0\x80\x80');run(['--text-file',str(invalid)],False,'INVALID_INPUT')
  big=outdir/'oversize.bin';big.write_bytes(b'x'*1000001);run(['--bytes-file',str(big)],False,'DATA_TOO_LONG')
  report['sourceStable']=snapshot()==before;require(report['sourceStable'],'Source changed');report['status']='passed'
 except BaseException as e:report.update(status='failed',error=repr(e));raise
 finally:(outdir/'report.json').write_text(json.dumps(report,indent=2)+'\n')
 return report
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--output',required=True);a=p.parse_args();r=verify(a.binary,a.output);print(json.dumps({'status':r['status'],'processes':len(r['processes'])}))
