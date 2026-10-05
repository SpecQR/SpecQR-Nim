import json,math,hashlib,pathlib
def require(value,message):
 if not value:raise RuntimeError(message)
def strict_json(data):
 def number(token):
  n=float(token);require(math.isfinite(n),'Non-finite JSON');return n
 def pairs(items):
  out={}
  for k,v in items:require(k not in out,'Duplicate JSON key');out[k]=v
  return out
 return json.loads(data,object_pairs_hook=pairs,parse_float=number,parse_constant=lambda x:(_ for _ in ()).throw(RuntimeError('Non-finite JSON')))
def binding(p):
 p=pathlib.Path(p);return {'file':p.name,'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
