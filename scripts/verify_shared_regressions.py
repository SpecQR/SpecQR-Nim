#!/usr/bin/env python3
import json,pathlib,sys
from verification_support import PKG,execute,finish_clients,check_fnc1_outcome,snapshot,digest,binary_command
ROOT=PKG.parent
import argparse
p=argparse.ArgumentParser();p.add_argument("--binary",required=True);p.add_argument("--output",type=pathlib.Path,required=True);p.add_argument("--python-deps",type=pathlib.Path,required=True);a=p.parse_args()
if not __debug__:raise SystemExit("Verification requires Python assertions; do not use -O or PYTHONOPTIMIZE.")
sys.path.insert(0,str(a.python_deps.resolve()))
import zxingcpp
from decoder_support import verify_png
from gs1_contract import load_shared,compare_contract,accepted

def main():
 corpus=PKG/'verification/fixtures/expected-contract-vectors.json'
 shared=PKG/'verification/fixtures/cross-port-regressions.json'
 vectors=json.loads(corpus.read_text());issues=json.loads(shared.read_text())['issues']
 binary=pathlib.Path(a.binary).resolve()
 report={'status':'running','sourceSha256':snapshot(),'binarySha256':digest(binary),'corpusSha256':digest(corpus),'sharedSha256':digest(shared),'counts':{},'intentionalDifferences':['High-level FNC1 percent uses byte fallback; forced alphanumeric rejects.','Creation safely places dot-only qualifiers into query, including explicit pathAis.','Print DPI is always validated conservatively at maximum symbol geometry.','Nim accepts only validated scalar ECC strings and rejects invalid names.']}
 counts={'percentVectors':0,'successfulPercentVectors':0,'decodedPngs':0,'forcedAlphaRejections':0,'capacityRejections':0,'manualSemantics':0,'digitalLinkOperations':0,'printDpiCases':0,'bridgeEccCases':0}
 try:
  requests=[{'text':v['input'],'options':v['options'],'pngScale':3} for v in vectors['vectors']]
  for v,q in zip(vectors['vectors'],execute(binary_command(binary),requests)):
   counts['percentVectors']+=1
   expected_outcome=check_fnc1_outcome(v,q)
   if expected_outcome=='INVALID_MODE':counts['forcedAlphaRejections']+=1;continue
   if expected_outcome=='DATA_TOO_LONG':counts['capacityRejections']+=1;continue
   counts['successfulPercentVectors']+=1
   _,pixels,dim=verify_png(q['png'],q['matrix'],3)
   found=zxingcpp.read_barcode(memoryview(pixels).cast('B',shape=(dim,dim)),text_mode=zxingcpp.TextMode.Plain)
   indicator=v['options'].get('fnc1Second','').encode()
   expected=indicator+bytes.fromhex(v['expectedPayloadUtf8Hex'])
   assert found is not None and found.valid and found.bytes==expected,(v['id'],None if found is None else found.bytes.hex(),expected.hex());counts['decodedPngs']+=1
  assert (counts['successfulPercentVectors'],counts['forcedAlphaRejections'],counts['capacityRejections'])==(44,34,24),counts
  for v in vectors['manualVectors']:
   request={'segments':v['controls']+v['data'],'pngScale':3}
   q=execute(binary_command(binary),[request])[0];assert 'error' not in q,q
   _,pixels,dim=verify_png(q['png'],q['matrix'],3)
   found=zxingcpp.read_barcode(memoryview(pixels).cast('B',shape=(dim,dim)),text_mode=zxingcpp.TextMode.Plain)
   prefix=next((c['applicationIndicator'] for c in v['controls'] if c['mode']=='fnc1-second'),'').encode()
   assert found is not None and found.valid and found.bytes==prefix+bytes.fromhex(v['expectedPayloadUtf8Hex']);counts['manualSemantics']+=1;counts['decodedPngs']+=1
  assert counts['manualSemantics']==4 and counts['decodedPngs']==48,counts
  gs1=load_shared()
  report['gs1IndependentOracles']=gs1['artifacts']
  counts.update(authorityOperations=0,authorityPositiveOperations=0,authorityRejectedOperations=0,gs1SharedAccepted=0,gs1SharedRejected=0,gs1SharedOverrides=0)
  for row in gs1['current']['cases']:
   override=gs1['residual'].get(row['id'])
   expected=(override or row)['expected']
   response=execute(binary_command(binary),[{'command':'gs1-fixture',**row['request']}])[0]
   assert 'value' in response,(row['id'],response)
   compare_contract(expected,response['value'],'Shared GS1 '+row['id'])
   ok=accepted(response['value'])
   assert ok==accepted(expected),(row['id'],'acceptance changed')
   counts['gs1SharedAccepted' if ok else 'gs1SharedRejected']+=1
   counts['gs1SharedOverrides']+=int(override is not None)
   if row['sourceFixture']=='strict-authority-vectors.json':
    counts['authorityOperations']+=1
    counts['authorityPositiveOperations' if ok else 'authorityRejectedOperations']+=1
    if ok:compare_contract(row['expected'],response['value'],'Current TS authority '+row['id'])
   else:counts['digitalLinkOperations']+=1
  for dpi,version in [(5e-324,1),(1e-305,1),(1e-304,1),(1e-304,40),(300,1)]:
   for command in [None,'estimate','structured-append']:
    q=execute(binary_command(binary),[{'command':command,'text':'A'*80 if command=='structured-append' else 'A','options':{'printDpi':dpi,'version':version}}])[0]
    assert ('error' not in q) if dpi==300 else q.get('code')=='INVALID_INPUT',(dpi,command,q)
    counts['printDpiCases']+=1
  for name in issues['inheritedEccKeys']['inputs']:
   for command in [None,'estimate','structured-append','capacity']:
    q=execute(binary_command(binary),[{'command':command,'text':'A','options':{'errorCorrectionLevel':name,'version':1}}])[0]
    assert q.get('code')=='INVALID_ECC_LEVEL',q;counts['bridgeEccCases']+=1
  assert counts=={'percentVectors':102,'successfulPercentVectors':44,'decodedPngs':48,'forcedAlphaRejections':34,'capacityRejections':24,'manualSemantics':4,'digitalLinkOperations':28,'printDpiCases':15,'bridgeEccCases':20,'authorityOperations':21,'authorityPositiveOperations':18,'authorityRejectedOperations':3,'gs1SharedAccepted':25,'gs1SharedRejected':24,'gs1SharedOverrides':3},('Exact regression cardinality changed',counts)
  finish_clients(report)
  assert snapshot()==report['sourceSha256'],'Source changed during verification'
  report['status']='passed'
 except BaseException as error:report.update(status='failed',error=repr(error));raise
 finally:
  finish_clients(report,raise_errors=False)
  report.update(counts=counts,sourceStable=snapshot()==report['sourceSha256']);a.output.write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
