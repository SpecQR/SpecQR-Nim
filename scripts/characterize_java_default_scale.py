#!/usr/bin/env python3
"""Characterize Java detection at default scale 8, without hiding rejections.

This is an additional detector control, not a substitute for either the full
C++ scale-8 gate or the strict Java scale-3 suite. Candidate and independent PNGs
must have identical pixels; matrix decoding and C++ decoding remain positive
controls. Java rejection pairs are reported, never counted as successful PNGs.
"""
import argparse,base64,hashlib,importlib.metadata,io,json,pathlib,subprocess,sys
from verification_support import execute,finish_clients,snapshot,digest,binary_command,PKG
from decoder_support import cases,verify_png,independent_png,verify_control_pixels
from auxiliary_process import run_auxiliary,json_records,version_text
if not __debug__:raise SystemExit('Characterization requires Python without -O.')

def main():
 p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--java',type=pathlib.Path,required=True);p.add_argument('--jar',type=pathlib.Path,required=True);p.add_argument('--python-deps',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
 a.output=a.output.resolve();assert not a.output.exists(),'Use a new receipt path';a.output.parent.mkdir(parents=True,exist_ok=True)
 sys.path.insert(0,str(a.python_deps.resolve()));import zxingcpp
 assert importlib.metadata.version('zxing-cpp')=='3.1.1'
 assert digest(a.jar)=='71de5d89341b5fcf5dd89da7f44e84d825d0e084cdf3ec77c9abe26b0f0ceb13'
 work=a.output.parent/'java-default8-controls';work.mkdir(exist_ok=True)
 report={'status':'running','purpose':'Java scale-8 detector characterization; rejections remain rejections','sourceSha256':snapshot(),'javaJarSha256':digest(a.jar),'scale':8,'cases':[],'auxiliaryProcesses':[]}
 def java_decode(lines):
  f=work/'inputs.txt';f.write_text('\n'.join(lines)+'\n')
  cmd=[str(a.java),'-XX:ActiveProcessorCount=2','-Djava.awt.headless=true','--class-path',str(a.jar),str(PKG/'scripts/zxing-java/DecodeSymbols.java'),str(f)]
  def parse_output(data):
   (work/'java.stdout.jsonl').write_bytes(data)
   return json_records(data,len(lines))
  rows=run_auxiliary(cmd,report,'java-default8-decode',timeout=120,validator=parse_output)
  (work/'java.stderr').write_bytes(b'')
  assert all(type(row.get('ordinal')) is int and row['ordinal']==i for i,row in enumerate(rows))
  return rows
 try:
  report['java']=run_auxiliary([str(a.java),'--version'],report,'java-version',validator=lambda data:version_text(data,('openjdk ','java ')))
  selected=cases(False)[:7]+[x for x in cases(False) if x[0] in ('version-1','version-7','version-40')]
  assert len(selected)==10,'Expected exactly ten fixed characterization cases'
  requests=[{**req,'pngScale':8} for _,req,_ in selected]
  results=execute(binary_command(a.binary),requests)
  assert len(results)==10
  lines=[]
  for (name,req,want),q in zip(selected,results):
   assert 'error' not in q,(name,q)
   png,luma,dim=verify_png(q['png'],q['matrix'],8)
   control=independent_png(q['matrix'],8);verify_control_pixels(control,luma,dim)
   candidate=work/(name+'-candidate.png');independent=work/(name+'-independent.png');small=work/(name+'-independent-scale3.png')
   candidate.write_bytes(png);independent.write_bytes(control);small.write_bytes(independent_png(q['matrix'],3))
   cpp=zxingcpp.read_barcode(memoryview(luma).cast('B',shape=(dim,dim)),text_mode=zxingcpp.TextMode.Plain)
   assert cpp is not None and cpp.valid and cpp.bytes==want['bytes'],name
   lines.extend(['png\t'+str(candidate),'png\t'+str(independent),'matrix\t'+','.join(q['matrix']),'png\t'+str(small)])
   report['cases'].append({'name':name,'request':requests[len(report['cases'])],'candidatePngSha256':digest(candidate),'independentPngSha256':digest(independent),'scale3PngSha256':digest(small),'identicalScale8Pixels':True,'pixels':dim*dim,'cppPayloadVerified':True,'expectedData':q['data']})
  actual=java_decode(lines)
  for i,record in enumerate(report['cases']):
   candidate,control,matrix,small=actual[i*4:i*4+4]
   assert 'error' not in matrix and 'error' not in small,(record['name'],matrix,small)
   for decoded in [matrix,small]:assert base64.b64decode(decoded['rawBytesBase64'],validate=True).hex()==record['expectedData']
   if 'error' in candidate or 'error' in control:
    assert candidate.get('error') in ('NotFoundException','FormatException','ChecksumException') and candidate.get('error')==control.get('error'),(record['name'],candidate,control)
    record['javaScale8Outcome']='rejected-identical-pixel-pair';record['javaScale8Error']=candidate['error']
   else:
    assert base64.b64decode(candidate['rawBytesBase64'],validate=True).hex()==base64.b64decode(control['rawBytesBase64'],validate=True).hex()==record['expectedData']
    record['javaScale8Outcome']='decoded-identical-pixel-pair'
   record['matrixAndScale3ControlsPassed']=True
  finish_clients(report);assert snapshot()==report['sourceSha256'],'Source changed'
  report['counts']={'cases':len(report['cases']),'decodedScale8Pairs':sum(x['javaScale8Outcome'].startswith('decoded') for x in report['cases']),'rejectedScale8Pairs':sum(x['javaScale8Outcome'].startswith('rejected') for x in report['cases']),'matrixPositiveControls':len(report['cases']),'scale3PositiveControls':len(report['cases'])}
  report['status']='passed-characterization'
 except BaseException as e:report.update(status='failed',error=repr(e));raise
 finally:
  finish_clients(report,raise_errors=False);report['sourceStable']=snapshot()==report['sourceSha256'];a.output.write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps({'status':report['status'],'counts':report['counts']}))
if __name__=='__main__':main()
