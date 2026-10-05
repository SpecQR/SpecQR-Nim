#!/usr/bin/env python3
"""Actual compiler, four build/memory lanes, full fixtures, CLI and offline users."""
import argparse,hashlib,json,pathlib,platform,subprocess,os,sys,shutil,time
from prepare_ci import verify
from native_support import require,binding,strict_json
ROOT=pathlib.Path(__file__).resolve().parents[1]

def main():
 p=argparse.ArgumentParser();p.add_argument('--nim',type=pathlib.Path,required=True);p.add_argument('--expect-version',required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args();a.nim=a.nim.resolve();a.output=a.output.resolve()
 require(not a.output.exists(),'Output must be a fresh directory');a.output.mkdir(parents=True)
 initial=verify(ROOT);report={'status':'running','compiler':binding(a.nim),'expectedVersion':a.expect_version,'host':{'os':platform.system(),'arch':platform.machine(),'python':platform.python_version()},'source':initial,'processes':[],'lanes':[]};start=time.monotonic()
 env=os.environ.copy();env.update(PYTHONDONTWRITEBYTECODE='1',PYTHONUTF8='1',TZ='UTC')
 def run(cmd,label,cwd=ROOT,env=env,expect=None,stderr_empty=False,timeout=1800):
  log=a.output/(label+'.log');log.parent.mkdir(parents=True,exist_ok=True)
  started=time.monotonic();r=subprocess.run([str(x) for x in cmd],cwd=cwd,env=env,capture_output=True,timeout=timeout)
  log.write_bytes(r.stdout+b'\n--- stderr ---\n'+r.stderr)
  row={'label':label,'argv':[str(x) for x in cmd],'exitCode':r.returncode,'stdoutBytes':len(r.stdout),'stderrBytes':len(r.stderr),'stdoutSha256':hashlib.sha256(r.stdout).hexdigest(),'stderrSha256':hashlib.sha256(r.stderr).hexdigest(),'elapsedSeconds':round(time.monotonic()-started,3),'log':binding(log)};report['processes'].append(row)
  require(r.returncode==0,label+' failed: '+r.stderr.decode(errors='replace')[-1200:])
  if stderr_empty:require(not r.stderr,label+' unexpected stderr')
  if expect is not None:require(r.stdout==expect,label+' unexpected stdout')
  return r.stdout
 try:
  version=run([a.nim,'--version'],'compiler-version',stderr_empty=True).decode();require('Nim Compiler Version '+a.expect_version+' [' in version,'Wrong compiler version');report['compilerVersion']=version
  require(platform.system()=='Linux' and platform.machine() in ['x86_64','amd64'],'This validation profile is Linux x86-64 only')
  run([sys.executable,ROOT/'scripts/test_harness.py'],'harness-tests')
  for config,mm in [('debug','orc'),('release','orc'),('debug','arc'),('release','arc')]:
   label=config+'-'+mm;dest=a.output/label;dest.mkdir();lane={'label':label,'status':'running','binaries':{},'unitGroups':{}}
   report['lanes'].append(lane);print('Building '+label,flush=True)
   def compile(source,name):
    output=dest/name
    cmd=[a.nim,'c','--hints:off','--warnings:off','--mm:'+mm,'--path:'+str(ROOT/'src'),'--nimcache:'+str(dest/'cache'), '--out:'+str(output)]
    if config=='release':cmd+=['-d:release']
    cmd+=[source];run(cmd,label+'/build-'+name);lane['binaries'][name]=binding(output);return output
   for test,count in [('test_core',11),('test_render',4),('test_gs1',26),('test_structured_append',19)]:
    binary=compile(ROOT/'tests'/(test+'.nim'),test);text=run([binary],label+'/'+test,stderr_empty=True).decode()
    require(text.count('[OK]')==count and '[FAILED]' not in text and '[SKIPPED]' not in text,test+' unit suite incomplete');lane['unitGroups'][test]=count
   bridge=compile(ROOT/'scripts/bridge.nim','bridge');runtime=strict_json(run([bridge,'--runtime'],label+'/runtime',stderr_empty=True));require(runtime=={'nim':a.expect_version,'os':'linux','arch':'amd64','wordSize':64},'Unexpected native runtime');lane['runtime']=runtime
   run([sys.executable,ROOT/'scripts/verify_reference.py','--binary',bridge,'--output',dest/'reference.json'],label+'/reference',stderr_empty=True)
   run([sys.executable,ROOT/'scripts/verify_negative.py','--binary',bridge,'--output',dest/'negative.json'],label+'/negative',stderr_empty=True)
   cli=compile(ROOT/'src/specqr_cli.nim','specqr_cli');run([sys.executable,ROOT/'scripts/verify_cli.py','--binary',cli,'--output',dest/'cli'],label+'/cli',stderr_empty=True)
   lane['status']='passed';require(verify(ROOT)==initial,'Source changed during lane')
  # Fresh package copy, empty local index, isolated home; no registry dependency.
  package=a.output/'package-copy';shutil.copytree(ROOT,package,ignore=shutil.ignore_patterns('__pycache__'))
  home=a.output/'consumer-home';home.mkdir();nimble_dir=home/'.nimble';nimble_dir.mkdir();(nimble_dir/'packages_official.json').write_text('[]\n')
  consumer_env=env.copy();consumer_env.update(HOME=str(home),NIMBLE_DIR=str(nimble_dir),PATH=str(a.nim.parent)+os.pathsep+env.get('PATH',''))
  nimble=a.nim.parent/'nimble';report['nimble']=binding(nimble)
  # Nimble 0.16.1 checks tracked file names. Use a genuinely fresh local
  # checkout rather than inheriting any unrelated ancestor's Git metadata.
  # This repository has no remote, tags, or registry publication.
  run(['git','init','--initial-branch=main'],'consumer-git-init',cwd=package,env=consumer_env)
  run(['git','add','.'],'consumer-git-add',cwd=package,env=consumer_env)
  run(['git','-c','user.name=SpecQR verification','-c','user.email=verification@example.invalid','commit','-m','Local verification snapshot'],'consumer-git-commit',cwd=package,env=consumer_env)
  run([nimble,'--offline','--nim:'+str(a.nim),'check'],'nimble-check',cwd=package,env=consumer_env)
  run([nimble,'--offline','--nim:'+str(a.nim),'-y','install','--passNim:--nimcache:'+str(a.output/'nimble-cache')],'nimble-install',cwd=package,env=consumer_env)
  installed=list((nimble_dir/'pkgs2').glob('specqr-*/specqr.nim'));require(len(installed)==1,'Package not installed exactly once');package_dir=installed[0].parent
  for src in (ROOT/'src').rglob('*.nim'):
   dest=package_dir/src.relative_to(ROOT/'src');require(dest.is_file() and dest.read_bytes()==src.read_bytes(),'Installed source differs: '+str(src))
  consumer=a.output/'fresh-consumer';consumer.mkdir();shutil.copy(ROOT/'examples/consumer.nim',consumer/'consumer.nim')
  out=consumer/'consumer';run([a.nim,'c','--hints:off','--warnings:off','--path:'+str(package_dir),'--nimcache:'+str(consumer/'cache'),'--out:'+str(out),consumer/'consumer.nim'],'consumer-compile',cwd=consumer,env=consumer_env)
  run([out],'consumer-run',cwd=consumer,env=consumer_env,expect=b'consumer passed\n',stderr_empty=True)
  installed_cli=nimble_dir/'bin/specqr_cli';require(installed_cli.is_file(),'Installed CLI absent');run([installed_cli,'--version-info'],'installed-cli',cwd=consumer,env=consumer_env,expect=('SpecQR Nim 0.1.0; Nim '+a.expect_version+'\n').encode(),stderr_empty=True)
  report['offlineConsumer']={'status':'passed','emptyPackageIndex':True,'sourceCopied':True,'installedSourceExact':True,'registeredPublished':False,'localGitSnapshot':True}
  report['sourceStable']=verify(ROOT)==initial;require(report['sourceStable'],'Source changed');report['status']='passed'
 except BaseException as e:report.update(status='failed',error=repr(e));raise
 finally:
  report['elapsedSeconds']=round(time.monotonic()-start,3);(a.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps({'status':report['status'],'lanes':len(report['lanes']),'elapsedSeconds':report['elapsedSeconds']}))
if __name__=='__main__':main()
