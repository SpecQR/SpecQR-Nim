#!/usr/bin/env python3
"""Bounded malformed-input and exact-capacity rejection regressions."""
import argparse,json,pathlib,random
from verification_support import execute,finish_clients,binary_command,snapshot,digest
from native_support import require

def main():
 p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args();a.output.parent.mkdir(parents=True,exist_ok=True)
 report={'status':'running','sourceSha256':snapshot(),'binarySha256':digest(a.binary),'cases':0}
 cases=[]
 def add(req,code):cases.append((req,code))
 for v in [-9223372036854775808,-1,0,41,9223372036854775807]:add({'text':'A','options':{'version':v}},'INVALID_VERSION')
 for v in [-1,8,1000]:add({'text':'A','options':{'maskPattern':v}},'INVALID_INPUT')
 for v in [-1,1000000,9223372036854775807]:add({'text':'A','options':{'eci':v}},'INVALID_ECI')
 for v in ['', 'AAA','1','漢',1,False]:add({'text':'A','options':{'fnc1Second':v}},'INVALID_MODE' if isinstance(v,str) else 'INVALID_INPUT')
 for level in ['', 'low','__proto__','toString',None,1,True,[],{}]:add({'text':'A','options':{'errorCorrectionLevel':level}},'INVALID_ECC_LEVEL')
 for field in ['optimizeSegments','allowKanji','boostErrorCorrection','gs1','fnc1']:
  for value in [0,1,'true',None,[],{}]:add({'text':'A','options':{field:value}},'INVALID_INPUT')
 for invalid in ['\ud800','\udfff','A\ud800B']:add({'text':invalid},'INVALID_INPUT')
 for mode,text in [('numeric','1a'),('alphanumeric','a'),('kanji','🙂'),('unknown','A')]:add({'text':text,'options':{'mode':mode}},'INVALID_MODE')
 for value in [-1,256,1.5,True,None,'0',{}]:add({'bytes':[value]},'INVALID_INPUT')
 for margin in [-1,1000000001,9223372036854775807]:add({'text':'A','options':{'margin':margin}},'INVALID_INPUT')
 for scale in [-1,0,1000000001]:add({'text':'A','options':{'scale':scale}},'INVALID_INPUT')
 for dpi in [0,-1,1e-305,1e-304,'x',True]:add({'text':'A','options':{'printDpi':dpi}},'INVALID_INPUT')
 for c in ['', '#ggg','url(x)','<script>','x'*65]:add({'text':'A','options':{'foreground':c}},'INVALID_COLOR')
 for count in [3000,4000]:add({'bytes':[0]*count},'DATA_TOO_LONG')
 for modes in [[{'mode':'byte','text':'A'},{'mode':'fnc1'}],[{'mode':'fnc1'},{'mode':'eci','assignmentNumber':26},{'mode':'byte','text':'A'}]]:add({'segments':modes},'INVALID_GS1')
 for maxs in [0,1,17]:add({'command':'structured-append','text':'A'*100,'options':{'version':1,'maxSymbols':maxs}},'INVALID_MODE')
 for ctrl in [{'eci':0},{'fnc1':True},{'fnc1Second':'A'},{'boostErrorCorrection':True}]:add({'command':'structured-append','text':'A'*100,'options':ctrl},'INVALID_MODE')
 add({'command':'structured-append','text':'A','options':{'gs1':True}},'INVALID_GS1')
 add({'command':'structured-append','text':''},'INVALID_INPUT')
 add({'command':'structured-append','text':'A'},'INVALID_INPUT')
 rng=random.Random(917201)
 for i in range(200):
  value=rng.choice([None,True,False,'oops',[],{},[1],{'x':1}])
  add({'bytes':[value]},'INVALID_INPUT')
 try:
  actual=execute(binary_command(a.binary),[r for r,c in cases])
  for (request,code),response in zip(cases,actual):
   require(response.get('isSpecQRError') is True and response.get('code')==code,'Wrong rejection: '+repr((request,response,code)));report['cases']+=1
  finish_clients(report);report['sourceStable']=snapshot()==report['sourceSha256'];require(report['sourceStable'],'Source changed');report['status']='passed'
 except BaseException as e:report.update(status='failed',error=repr(e));raise
 finally:
  finish_clients(report,raise_errors=False);a.output.write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps({'status':report['status'],'cases':report['cases']}))
if __name__=='__main__':main()
