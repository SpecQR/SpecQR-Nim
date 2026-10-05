"""Independent, request-bound GS1 expectations; no candidate-derived baselines."""
import collections,gzip,hashlib,json,pathlib
from native_support import require,strict_json,binding
from verify_reference import compare
ROOT=pathlib.Path(__file__).resolve().parents[1]
TS_COMMIT='16efc6c0a8e397c9df3d051d20fce6c1eebdfad7'
NIM_COMMIT='4f9154664d35a24cecb30b75cfdba0a9f16ced3e'
PINS={
 'url-serialization-controls394.json':'62c9ddf8b3636ac5564337a2f9bb9c28aeaf82c8597624dff26b9f2c23938283',
 'gs1-upstream.json':'e12c7a2e6ed9ae26cc9865caab9e6e0a7dbeb62438a903a3f5611d6420c865e2',
 'current-ts-gs1-1411.json.gz':'c2e0678be740d935306353ae15c0e5f80a444a641351b070f5126be81057021b',
 'approved-restorations80.json':'08f1e5ae4b2d49163e85ed95507090f4b409924e4ce1d553f092a4efa5ddcd3c',
 'native-intentional-deltas168.json':'332e993479fcb898e04469230d77540412c7513c673e21e0511b0f7f19dc6055',
 'current-ts-gs1-shared49.json':'a7d568cb2a63ff28695b132c1028c8d7ca898cca0e813316ff6b454fecc447e1',
 'diagnostic-migrations5.json':'e4ed5e221cb5297551cbf75cb6131c149b54a53a3d111eb94f4d8438f14685e7',
 'native-shared-gs1-deltas3.json':'dd5a7dd6efeba47d490c895ae39b9a985dc045bc6f111ce601b29b37c7094f89',
}
def digest_bytes(value):return hashlib.sha256(value).hexdigest()
def request_sha(value):return digest_bytes(json.dumps(value,ensure_ascii=True,sort_keys=True,separators=(',',':')).encode())
def fixture(name,root=ROOT):
 path=pathlib.Path(root)/'verification/fixtures'/name;raw=path.read_bytes();require(digest_bytes(raw)==PINS[name],'Pinned GS1 fixture changed: '+name)
 return strict_json(gzip.decompress(raw) if name.endswith('.gz') else raw)
def contract(value):
 if isinstance(value,list):return [contract(x) for x in value]
 if isinstance(value,dict):
  if 'code' in value and 'message' in value:return {k:contract(value[k]) for k in ['code','reason','count'] if value.get(k) is not None}
  return {k:contract(v) for k,v in value.items() if v is not None and k!='isVariable' and not(k=='errors' and value.get('ok'))}
 return value
def compare_contract(expected,actual,label='GS1'):
 expected=contract(expected);actual=contract(actual)
 compare(expected,actual,label);compare(actual,expected,label+' exact public fields')
def accepted(value):return not(isinstance(value,dict) and ('throws' in value or value.get('ok') is False))
def bind_request(row,expected,identity):
 require(row['request']==expected,'GS1 request mismatch: '+str(identity));require(row['requestSha256']==request_sha(expected),'GS1 request digest mismatch: '+str(identity))
def source_provenance(source,root=ROOT):
 require(source['commit']==TS_COMMIT and source['repository']=='https://github.com/SpecQR/SpecQR','Wrong TypeScript source')
 require(source['tree']=='ca4c2360a7dc0950c1bfd1f76e44616bcd406023','Wrong TypeScript tree')
 require(source['sourceHashes']['src/gs1/digital-link.js']=='a4ea3059c7fa63fc5c099fa5bc1915e59cbfd8f103fe19120397787c49b5eb7a','Wrong Digital Link source')
 require(digest_bytes((pathlib.Path(root)/source['oracleHarness']).read_bytes())==source['oracleHarnessSha256'],'TypeScript oracle harness changed')
def native_provenance(source,root=ROOT):
 require(source['commit']==NIM_COMMIT and source['repository']=='https://github.com/SpecQR/SpecQR-Nim','Wrong independent native source')
 require(source['sourceSha256']=='9df6a11927f265108e4d01e3321a208e1bcd4f9c484ff6aad5f9b8bd42734fa3','Wrong native GS1 source')
 require(digest_bytes((pathlib.Path(root)/'verification/gs1/nim_oracle.nim').read_bytes())==source['oracleHarnessSha256'],'Nim oracle harness changed')
def load_main(root=ROOT):
 historical=fixture('gs1-upstream.json',root);current=fixture('current-ts-gs1-1411.json.gz',root);restored=fixture('approved-restorations80.json',root);residual=fixture('native-intentional-deltas168.json',root)
 require(len(historical['cases'])==current['caseCount']==len(current['cases'])==1411,'GS1 full corpus cardinality changed')
 require(current['historicalFixtureSha256']==PINS['gs1-upstream.json'],'Historical fixture binding changed');source_provenance(current['source'],root)
 require([x['caseId'] for x in current['cases']]==list(range(1411)),'Missing or reordered TypeScript cases')
 for i,(old,row) in enumerate(zip(historical['cases'],current['cases'])):bind_request(row,{k:v for k,v in old.items() if k!='expected'},i)
 for data,count in [(restored,80),(residual,168)]:
  require(data['caseCount']==len(data['cases'])==count,'GS1 ledger cardinality changed');require(data['historicalFixtureSha256']==PINS['gs1-upstream.json'],'Ledger historical binding changed');require(data['currentTsOracleArtifactSha256']==PINS['current-ts-gs1-1411.json.gz'],'Ledger current TS binding changed')
 source_provenance(restored['source'],root);source_provenance(residual['currentTypeScript'],root);native_provenance(residual['nativeOracle'],root)
 restores={row['caseId']:row for row in restored['cases']};overrides={row['caseId']:row for row in residual['cases']}
 require(len(restores)==80 and len(overrides)==168 and not(set(restores)&set(overrides)),'Duplicate/overlapping GS1 ledger IDs')
 for i,row in restores.items():
  base=current['cases'][i];bind_request(row,base['request'],i);require(row['expected']==base['expected'] and row['operation']==base['request']['op'],'Restoration diverges from pinned TS');require(accepted(row['expected']),'Restoration must be a positive result')
 require(collections.Counter(x['originalCategory'] for x in restores.values())=={'accepted-to-rejected':77,'normalization/data-result':3},'Restoration categories changed')
 categories=collections.Counter();rejected_buckets=collections.Counter()
 for i,row in overrides.items():
  base=current['cases'][i];bind_request(row,base['request'],i);require(row['currentTsExpected']==base['expected'] and row['operation']==base['request']['op'],'Residual TS result changed');require(contract(row['expected'])!=contract(base['expected']),'Redundant residual override')
  category=row['category'];categories[category]+=1
  current_ok=accepted(base['expected']);native_ok=accepted(row['expected'])
  require((current_ok,native_ok)==({'diagnostic-only':(False,False),'accepted-to-rejected':(True,False),'rejected-to-accepted':(False,True)}[category]),'Residual changed its acceptance category')
  if category=='accepted-to-rejected':rejected_buckets[row['historicalBucket']]+=1
 require(categories==residual['categoryCounts']=={'diagnostic-only':132,'accepted-to-rejected':34,'rejected-to-accepted':2},'Residual categories changed')
 require(rejected_buckets=={'strict-percent-unicode':20,'strict-authority':12,'digital-link-context-primary':2},'Residual rejection scope changed')
 migrations=fixture('diagnostic-migrations5.json',root)
 require(migrations['caseCount']==len(migrations['cases'])==5 and {row['caseId'] for row in migrations['cases']}=={930,1038,1056,1269,1272},'Diagnostic migration scope changed')
 require(migrations['baseResidualFixtureSha256']==PINS['native-intentional-deltas168.json'],'Diagnostic migration source changed');source_provenance(migrations['currentTypeScript'],root);native_provenance(migrations['nativeOracle'],root)
 for row in migrations['cases']:
  i=row['caseId'];prior=overrides[i];bind_request(row,prior['request'],i)
  require(prior['category']=='diagnostic-only' and row['priorNativeExpected']==prior['expected'],'Diagnostic migration no longer binds prior native result')
  require(row['expected']==row['independentWitness']['nimExpected'],'Diagnostic migration differs from its independent semantic witness')
  require(not accepted(row['expected']) and not accepted(row['priorNativeExpected']),'Diagnostic migration changed acceptance')
  require(contract(row['expected'])!=contract(current['cases'][i]['expected']),'Diagnostic migration changed residual identity')
  witness=row['independentWitness']['request']
  expected_witness={'op':'linkValidate','input':'https://example.com/01/04912345678904','options':{'primaryAi':'00'}} if i in [930,1038,1056] else {'op':'linkValidate','input':'https://example.com/01/04912345678904?encodingWitness='+('%FF' if i==1269 else '%00')}
  require(witness==expected_witness,'Independent semantic witness changed')
  overrides[i]={**prior,'expected':row['expected'],'diagnosticMigration':True}
 return {'current':current,'restored':restores,'residual':overrides,'categoryCounts':dict(categories),'rejectedBuckets':dict(rejected_buckets),'diagnosticMigrations':5,'artifacts':{name:binding(pathlib.Path(root)/'verification/fixtures'/name) for name in ['gs1-upstream.json','current-ts-gs1-1411.json.gz','approved-restorations80.json','native-intentional-deltas168.json','diagnostic-migrations5.json']}}
def load_shared(root=ROOT):
 current=fixture('current-ts-gs1-shared49.json',root);residual=fixture('native-shared-gs1-deltas3.json',root);source_provenance(current['currentTypeScript'],root);native_provenance(residual['nativeOracle'],root)
 require(current['caseCount']==len(current['cases'])==49 and residual['caseCount']==len(residual['cases'])==3,'Shared GS1 cardinality changed')
 require(residual['currentTsFixtureSha256']==PINS['current-ts-gs1-shared49.json'],'Shared GS1 source binding changed')
 for name,sha in current['sourceFixtures'].items():require(digest_bytes((pathlib.Path(root)/'verification/fixtures'/name).read_bytes())==sha,'Original shared fixture changed')
 rows={row['id']:row for row in current['cases']};overrides={row['id']:row for row in residual['cases']};require(len(rows)==49 and set(overrides)=={'bare-hex-ipv4-4:linkValidate','builder-dot-path:linkCreate','builder-parent-path:linkCreate'},'Shared residual scope changed')
 # Reconstruct every request from the unchanged source vectors, not candidate output.
 expected={}
 authority=strict_json((pathlib.Path(root)/'verification/fixtures/strict-authority-vectors.json').read_bytes())
 for row in authority['vectors']:
  for op in ['linkParse','linkValidate','linkNormalize']:expected[row['id']+':'+op]={'op':op,'input':row['input']}
 original=strict_json((pathlib.Path(root)/'verification/fixtures/cross-port-regressions.json').read_bytes())
 for row in original['issues']['digitalLinkDotLoss']['cases']:
  if 'uri' in row:
   for op in row['operations']:
    name={'parse':'linkParse','validate':'linkValidate','normalize':'linkNormalize'}[op];expected[row['id']+':'+name]={'op':name,'input':row['uri']}
  else:expected[row['id']+':linkCreate']={'op':'linkCreate','elements':row['elements'],'options':row.get('options',{})}
 require(set(expected)==set(rows),'Missing original shared operations')
 for key,row in rows.items():bind_request(row,expected[key],key)
 for key,row in overrides.items():
  bind_request(row,rows[key]['request'],key);require(row['currentTsExpected']==rows[key]['expected'],'Shared current TS expectation changed');require(contract(row['expected'])!=contract(row['currentTsExpected']),'Redundant shared override')
  require((accepted(row['currentTsExpected']),accepted(row['expected']))==((False,False) if key=='bare-hex-ipv4-4:linkValidate' else (False,True)),'Shared override changed acceptance scope')
 final=[overrides.get(key,row)['expected'] for key,row in rows.items()];require(sum(map(accepted,final))==25,'Shared accepted outcome count changed')
 return {'current':current,'residual':overrides,'artifacts':{name:binding(pathlib.Path(root)/'verification/fixtures'/name) for name in ['current-ts-gs1-shared49.json','native-shared-gs1-deltas3.json']}}

def load_serialization(root=ROOT):
 data=fixture('url-serialization-controls394.json',root);source_provenance(data['source'],root)
 require(data['caseCount']==len(data['cases'])==394,'URL serialization cardinality changed')
 require([r['caseId'] for r in data['cases']]==list(range(394)),'URL serialization IDs changed')
 require(collections.Counter(r['category'] for r in data['cases'])=={'path-ascii':89,'base-path-ascii':89,'userinfo-ascii':87,'query-ascii':89,'numeric-ipv4-boundaries':36,'ipv6-zero-ties':4},'URL serialization scope changed')
 for row in data['cases']:
  bind_request(row,row['request'],row['caseId']);require(accepted(row['expected']),'URL serialization controls must be positive')
 require(data['cases'][222]['expected']==data['cases'][223]['expected']=='https://example.com/context%5Eprefix/01/09506000134352','Independent caret serialization expectation changed')
 return {'current':data,'artifact':binding(pathlib.Path(root)/'verification/fixtures/url-serialization-controls394.json')}
