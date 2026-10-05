#!/usr/bin/env python3
"""Independent actual-PNG detection, bytes, ECI, GS1, SA metadata checks."""
import argparse,base64,hashlib,json,pathlib,sys,subprocess,time,importlib,importlib.metadata
from verification_support import PKG,execute,finish_clients,digest,snapshot,binary_command
ROOT=PKG.parent
if not __debug__:raise SystemExit('Decoder verification requires Python assertions; do not use -O or PYTHONOPTIMIZE.')
# This imports test-only decoder utilities, not an encoder runtime.
from decoder_support import verify_png,cases
from auxiliary_process import run_auxiliary,json_records,version_text

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--binary',required=True);ap.add_argument('--decoder',choices=['cpp','java'],required=True);ap.add_argument('--scale',type=int);ap.add_argument('--python-deps',type=pathlib.Path);ap.add_argument('--java',type=pathlib.Path);ap.add_argument('--jar',type=pathlib.Path);ap.add_argument('--output',type=pathlib.Path,required=True);a=ap.parse_args();a.binary=str(pathlib.Path(a.binary).resolve());a.output=a.output.resolve()
 if a.output.exists():raise RuntimeError('Output receipt already exists; use a fresh attempt path')
 scale=a.scale or (8 if a.decoder=='cpp' else 3)
 work=a.output.parent/f'decode-{a.decoder}-scale{scale}';work.mkdir(parents=True,exist_ok=True)
 report={'status':'running','decoder':a.decoder,'scale':scale,'sourceSha256':snapshot(),'binarySha256':digest(pathlib.Path(a.binary)),'counts':{},'failures':[]}
 inputs=[];expected=[];counts={'pngDecodes':0,'matrixDecodes':0,'pixels':0,'fnc1SecondSymbols':0,'structuredAppendHeaders':0,'highLevelSets':0,'highLevelSymbols':0}
 try:
  if a.decoder=='cpp':
   if a.python_deps:sys.path.insert(0,str(a.python_deps.resolve()))
   import zxingcpp as zxing
   assert importlib.metadata.version('zxing-cpp')=='3.1.1'
   native=importlib.import_module('zxingcpp.zxingcpp');report['decoderVersion']='3.1.1';report['decoderSha256']=digest(pathlib.Path(native.__file__))
  else:
   assert a.java and a.jar,'Java verification requires --java and --jar'
   java=a.java.resolve();jar=a.jar.resolve()
   assert digest(jar)=='71de5d89341b5fcf5dd89da7f44e84d825d0e084cdf3ec77c9abe26b0f0ceb13'
   report['decoderVersion']='3.5.4';report['decoderSha256']=digest(jar);report['java']=run_auxiliary([str(java),'--version'],report,'java-version',validator=lambda data:version_text(data,('openjdk ','java '))).splitlines()[0]
  # Exercise the actual implicit renderer default, independently of pngScale.
  # Each output is pixel-checked and decoded, then compared byte-for-byte with
  # an explicit scale=8 rendering of the same input and QR options.
  if a.decoder=='cpp':
   default_cases=[({'text':'A','options':{'version':1}},b'A'),({'text':'SpecQR 日本語 🙂','options':{'version':7,'mode':'byte','eci':26}},'SpecQR 日本語 🙂'.encode()),({'bytes':list(range(200)),'options':{'version':40,'errorCorrectionLevel':'H'}},bytes(range(200)))]
   counts['implicitDefaultPngCases']=0;counts['implicitExplicitPngEquality']=0
   for request,payload in default_cases:
    implicit=execute(binary_command(a.binary),[{**request,'renders':True}])[0]
    explicit=execute(binary_command(a.binary),[{**request,'options':{**request['options'],'scale':8},'pngScale':8}])[0]
    assert 'error' not in implicit and 'error' not in explicit,(request,implicit,explicit)
    png=base64.b64decode(implicit['pngDataUrl'].split(',',1)[1],validate=True)
    assert png.hex()==explicit['png'] and implicit['matrix']==explicit['matrix']
    _,pixels,dimension=verify_png(png.hex(),implicit['matrix'],8)
    decoded=zxing.read_barcode(memoryview(pixels).cast('B',shape=(dimension,dimension)),text_mode=zxing.TextMode.Plain)
    assert decoded is not None and decoded.valid and decoded.bytes==payload
    counts['implicitDefaultPngCases']+=1;counts['implicitExplicitPngEquality']+=1
  tests=cases(a.decoder=='cpp')
  for index,payload in enumerate(['ABC\x1dDEF','ABC\x1d\x1dDEF','ABC%DEF','ABC%%DEF','ABC\x1d%DEF','A'*30+'\x1d\x1d'+'B'*30,'A'*30+'\x1d%'+'B'*30]):
   tests.append((f'fnc1-edge-{index}',{'text':payload,'options':{'fnc1':True}}, {'text':payload,'bytes':payload.encode(),'identifier':']Q3'}))
   if a.decoder=='cpp':tests.append((f'second-edge-{index}',{'text':payload,'options':{'fnc1Second':'A'}},{'bytes':b'A'+payload.encode(),'identifier':']Q5'}))
  for start in range(0,len(tests),4):
   group=tests[start:start+4];results=execute(binary_command(a.binary),[{**req,'pngScale':scale} for _,req,_ in group])
   for (name,req,want),q in zip(group,results):
    assert 'error' not in q,(name,q)
    png,luma,dim=verify_png(q['png'],q['matrix'],scale);counts['pixels']+=dim*dim
    counts['structuredAppendHeaders']+=int(name.startswith('sa-'));counts['fnc1SecondSymbols']+=int(name.startswith('second-'))
    if a.decoder=='cpp':
     found=zxing.read_barcode(memoryview(luma).cast('B',shape=(dim,dim)),text_mode=zxing.TextMode.Plain)
     identifier=want.get('identifier',']Q1');prop=']Q1' if identifier==']Q2' else identifier
     assert found is not None and found.valid,(name,'no PNG detection')
     assert found.bytes==want['bytes'],(name,found.bytes.hex(),want['bytes'].hex())
     assert found.symbology_identifier==prop,(name,found.symbology_identifier,prop)
     assert found.ec_level==q['ecc'] and found.extra['Version']==str(q['version']) and found.extra['DataMask']==q['mask'],name
     if identifier==']Q2':
      eci=zxing.read_barcode(memoryview(luma).cast('B',shape=(dim,dim)),text_mode=zxing.TextMode.ECI)
      assert eci is not None and eci.valid and eci.text==']Q2\\000026'+want['text'],(name,eci)
     counts['pngDecodes']+=1
    else:
     f=work/(name+'.png');f.write_bytes(png)
     for route,value in [('matrix',','.join(q['matrix'])),('png',str(f))]:inputs.append(route+'\t'+value);expected.append((name,route,{**want,'data':q['data'],'ecc':q['ecc'],'allByteData':all(s['mode'] in ('byte','eci','fnc1','fnc1-second','structured-append') for s in q['segments'])}))
   print(a.decoder,start+len(group),'/',len(tests),flush=True)
  groups=[('numeric',{'text':'0123456789'*13,'options':{'version':1,'mode':'numeric'}},('0123456789'*13).encode()),('alpha',{'text':'SPECQR / 12345 '*10,'options':{'version':2,'mode':'alphanumeric'}},('SPECQR / 12345 '*10).encode()),('unicode',{'text':'e\u0301🙂漢字'*12,'options':{'version':2,'mode':'byte'}},('e\u0301🙂漢字'*12).encode()),('binary',{'bytes':list(range(256)),'options':{'version':2}},bytes(range(256))),('sixteen',{'bytes':list(range(240)),'options':{'version':1,'errorCorrectionLevel':'L'}},bytes(range(240)))]
  for name,req,payload in groups:
   result=execute(binary_command(a.binary),[{**req,'command':'structured-append','pngScale':scale}])[0]
   assert 'error' not in result,(name,result)
   parity=0
   for b in payload:parity^=b
   assert result['parity']==parity and 2<=result['total']<=16
   if name=='sixteen':assert result['total']==16
   parts=[]
   for index,q in enumerate(result['symbols']):
    png,luma,dim=verify_png(q['png'],q['matrix'],scale);counts['pixels']+=dim*dim;counts['highLevelSymbols']+=1
    if a.decoder=='cpp':
     found=zxing.read_barcode(memoryview(luma).cast('B',shape=(dim,dim)),text_mode=zxing.TextMode.Plain)
     assert found is not None and found.valid,(name,index,'no PNG detection')
     parts.append(found.bytes);counts['pngDecodes']+=1
    else:
     f=work/(f'high-{name}-{index}.png');f.write_bytes(png)
     for route,value in [('matrix',','.join(q['matrix'])),('png',str(f))]:
      inputs.append(route+'\t'+value);expected.append((f'high-{name}-{index}',route,{'data':q['data'],'ecc':q['ecc'],'sequence':index*16+result['total']-1,'parity':parity,'identifier':']Q1'}))
   if a.decoder=='cpp':assert b''.join(parts)==payload,name
   counts['highLevelSets']+=1
  if a.decoder=='java':
   f=work/'inputs.txt';f.write_text('\n'.join(inputs)+'\n')
   actual=run_auxiliary([str(java),'-XX:ActiveProcessorCount=2','-Djava.awt.headless=true','--class-path',str(jar),str(PKG/'scripts/zxing-java/DecodeSymbols.java'),str(f)],report,'java-decode',timeout=600,validator=lambda data:json_records(data,len(expected)))
   assert all(type(row.get('ordinal')) is int and row['ordinal']==i for i,row in enumerate(actual)),'Java response order mismatch'
   for (name,route,want),found in zip(expected,actual):
    if 'error' in found:report['failures'].append({'name':name,'route':route,'error':found});continue
    assert base64.b64decode(found['rawBytesBase64']).hex()==want['data'],(name,'data')
    assert found['ecc']==want['ecc'],(name,'ecc')
    assert found['sequence']==want.get('sequence') and found['parity']==want.get('parity'),(name,found,'SA header')
    assert found['symbologyIdentifier']==want.get('identifier',']Q1'),(name,found,'identifier')
    if 'text' in want:assert base64.b64decode(found['textBase64']).decode()==want['text'],(name,'text')
    if 'bytes' in want and found['byteSegments'] and ('text' not in want or want.get('allByteData',True)):assert b''.join(base64.b64decode(b) for b in found['byteSegments'])==want['bytes'],(name,'bytes')
    counts[route+'Decodes']+=1
  assert not report['failures'],report['failures'][:4]
  finish_clients(report)
  assert snapshot()==report['sourceSha256'],'Source changed during verification'
  report['status']='passed'
 except BaseException as e:report.update(status='failed',error=repr(e));raise
 finally:
  finish_clients(report,raise_errors=False)
  report.update(counts=counts,sourceStable=report['sourceSha256']==snapshot());a.output.write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
