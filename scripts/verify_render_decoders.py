#!/usr/bin/env python3
import base64,hashlib,json,pathlib,subprocess,sys,urllib.parse,xml.etree.ElementTree as ET,os,io
from verification_support import PKG,execute,finish_clients,snapshot,digest,binary_command
from auxiliary_process import run_auxiliary,version_text,png_stream
import argparse
ROOT=PKG.parent
if not __debug__:raise SystemExit("Use Python without -O/PYTHONOPTIMIZE.")
import importlib.metadata

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--binary',type=pathlib.Path,required=True);ap.add_argument('--rasterizer',type=pathlib.Path,required=True);ap.add_argument('--python-deps',type=pathlib.Path);ap.add_argument('--output',type=pathlib.Path,required=True);opts=ap.parse_args()
 if opts.python_deps:sys.path.insert(0,str(opts.python_deps.resolve()))
 import zxingcpp,PIL
 from PIL import Image
 opts.output=opts.output.resolve();opts.output.parent.mkdir(parents=True,exist_ok=True)
 if opts.output.exists():raise RuntimeError("Output receipt already exists; use a fresh attempt path")
 requests=[]
 for version in [1,2,7,10,27,40]:
  for ecc in 'LMQH':requests.append({'text':'HELLO','options':{'version':version,'errorCorrectionLevel':ecc,'maskPattern':(version+ord(ecc))%8,'scale':3},'pngScale':3,'renders':True})
 binary=opts.binary.resolve()
 report={'status':'running','sourceSha256':snapshot(),'binarySha256':digest(binary),'cases':0,'svgPngDecodes':0,'directPngDecodes':0,'dataUrlRoundTrips':0,'pillowVersion':PIL.__version__,'zxingCppVersion':importlib.metadata.version('zxing-cpp')}
 converter=opts.rasterizer.resolve()
 env=os.environ.copy();env['LD_LIBRARY_PATH']=str(converter.parents[1]/'lib/x86_64-linux-gnu')+os.pathsep+env.get('LD_LIBRARY_PATH','')
 try:
  report['svgRasterizer']=run_auxiliary([str(converter),'--version'],report,'svg-version',env=env,validator=lambda data:version_text(data,'rsvg-convert ',single_line=True));report['rasterizerSha256']=digest(converter)
  for req,actual in zip(requests,execute(binary_command(binary),requests)):
   assert 'error' not in actual,actual
   svg=actual['svg'];root=ET.fromstring(svg);assert root.tag=='{http://www.w3.org/2000/svg}svg'
   assert urllib.parse.unquote_to_bytes(actual['svgDataUrl'].split(',',1)[1])==svg.encode();report['dataUrlRoundTrips']+=1
   png=base64.b64decode(actual['pngDataUrl'].split(',',1)[1]);assert png.hex()==actual['png'];report['dataUrlRoundTrips']+=1
   raster=run_auxiliary([str(converter)],report,'svg-rasterize',input=svg.encode(),env=env,timeout=30,validator=png_stream)
   dims=(len(actual['matrix'])+8)*3
   a=Image.open(io.BytesIO(png)).convert('RGBA');b=Image.open(io.BytesIO(raster)).convert('RGBA')
   assert a.size==b.size==(dims,dims);assert a.tobytes()==b.tobytes()
   for kind,image in [('directPngDecodes',a),('svgPngDecodes',b)]:
    decoded=zxingcpp.read_barcode(image,text_mode=zxingcpp.TextMode.Plain)
    assert decoded is not None and decoded.valid and decoded.bytes==b'HELLO',req
    report[kind]+=1
   report['cases']+=1
  finish_clients(report)
  assert snapshot()==report['sourceSha256'],'Source changed during verification'
  report['status']='passed'
 except BaseException as error:report.update(status='failed',error=repr(error));raise
 finally:
  finish_clients(report,raise_errors=False)
  report['sourceStable']=snapshot()==report['sourceSha256'];opts.output.write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
