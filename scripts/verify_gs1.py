#!/usr/bin/env python3
"""Run all1,411 GS1 requests against current TypeScript plus explicit residuals."""
import argparse,json,pathlib,collections
from verification_support import execute,finish_clients,binary_command,snapshot
from native_support import require
from gs1_contract import load_main,contract,compare_contract,accepted,load_serialization
ROOT=pathlib.Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args();a.output.parent.mkdir(parents=True,exist_ok=True)
 source=load_main();current=source['current'];overrides=source['residual'];restored=source['restored']
 report={'status':'running','sourceSha256':snapshot(),'fixtures':source['artifacts'],'currentTypeScript':current['source'],'cases':0,'currentTsMatches':0,'currentTsDifferences':0,'restoredCases':0,'restorationAcceptanceCases':0,'restorationNormalizationCases':0,'residualCategories':{},'residualRejectionBuckets':source['rejectedBuckets'],'diagnosticMigrations':source['diagnosticMigrations']}
 observed=collections.Counter()
 try:
  for row in current['cases']:
   i=row['caseId'];expected=overrides.get(i,row)['expected'];request={'command':'gs1-fixture',**row['request']}
   actual=execute(binary_command(a.binary),[request])[0]
   try:
    require(isinstance(actual,dict) and 'value' in actual,'Missing GS1 value envelope');compare_contract(expected,actual['value'],f'GS1[{i}] {row["request"]["op"]}')
    if i in restored:
     compare_contract(row['expected'],actual['value'],f'Restored current TS[{i}]');require(accepted(actual['value']),'Restored positive request was rejected');report['restoredCases']+=1
     report['restorationAcceptanceCases' if restored[i]['originalCategory']=='accepted-to-rejected' else 'restorationNormalizationCases']+=1
    if contract(actual['value'])==contract(row['expected']):report['currentTsMatches']+=1
    else:
     require(i in overrides,'Undeclared difference from current TypeScript');report['currentTsDifferences']+=1;observed[overrides[i]['category']]+=1
   except Exception:
    a.output.with_suffix('.failure.json').write_text(json.dumps({'caseId':i,'request':request,'currentTsExpected':row['expected'],'expected':expected,'actual':actual},indent=2));raise
   report['cases']+=1
  report['residualCategories']=dict(observed)
  require((report['cases'],report['currentTsMatches'],report['currentTsDifferences'],report['restoredCases'],report['restorationAcceptanceCases'],report['restorationNormalizationCases'])==(1411,1243,168,80,77,3),'Incorrect final GS1 cardinality')
  require(dict(observed)==source['categoryCounts'],'Residual category count changed')
  extra=load_serialization();report['serializationFixture']=extra['artifact'];report['serializationControls']=0
  for row in extra['current']['cases']:
   actual=execute(binary_command(a.binary),[{'command':'gs1-fixture',**row['request']}])[0]
   require(isinstance(actual,dict) and 'value' in actual,'Missing serialization value envelope')
   compare_contract(row['expected'],actual['value'],f'URL serialization[{row["caseId"]}]');report['serializationControls']+=1
  require(report['serializationControls']==394,'URL serialization cases missing');finish_clients(report);report['sourceStable']=snapshot()==report['sourceSha256'];require(report['sourceStable'],'Source changed');report['status']='passed'
 except BaseException as error:report.update(status='failed',error=repr(error));raise
 finally:finish_clients(report,raise_errors=False);a.output.write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps({k:report[k] for k in ['status','cases','currentTsMatches','currentTsDifferences','restoredCases','residualCategories','serializationControls']}))
if __name__=='__main__':main()
