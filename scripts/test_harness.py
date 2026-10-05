#!/usr/bin/env python3
"""Real subprocess failure controls. These do not simulate Nim execution."""
import hashlib,json,pathlib,tempfile,unittest,sys,struct,zlib
from prepare_ci import inventory,verify
from native_support import strict_json
from verify_reference import compare,enrich
from verification_support import execute,finish_clients,expected_fnc1_outcome,check_fnc1_outcome
from auxiliary_process import run_auxiliary,json_records,version_text,exact_number,png_stream
class SourceTests(unittest.TestCase):
 def test_manifest_roundtrip_and_mutation(self):
  with tempfile.TemporaryDirectory() as td:
   root=pathlib.Path(td);(root/'a.nim').write_text('echo 1');(root/'SOURCE-SHA256.json').write_text(json.dumps({'schema':1,'files':inventory(root)}));verify(root)
   (root/'a.nim').write_text('echo 2')
   self.assertRaises(RuntimeError,verify,root)
 def test_added_file(self):
  with tempfile.TemporaryDirectory() as td:
   root=pathlib.Path(td);(root/'SOURCE-SHA256.json').write_text(json.dumps({'schema':1,'files':{}}));(root/'extra').write_text('x');self.assertRaises(RuntimeError,verify,root)
 def test_symlink(self):
  with tempfile.TemporaryDirectory() as td:
   root=pathlib.Path(td);(root/'a').write_text('x');(root/'b').symlink_to('a');self.assertRaises(RuntimeError,inventory,root)
 def test_strict_json(self):
  for data in ['{"a":1,"a":2}','NaN','Infinity','1e999']:
   self.assertRaises((RuntimeError,ValueError),strict_json,data)
 def test_strict_comparison(self):
  self.assertRaises(RuntimeError,compare,1,True);self.assertRaises(RuntimeError,compare,{'x':1},{})
  self.assertRaises(RuntimeError,enrich,{'matrix':['01']})
class ProcessHarnessTests(unittest.TestCase):
 """Fake-process failure controls only; these are not native Nim verification."""
 def tearDown(self):finish_clients(raise_errors=False,timeout=0.5)
 def command(self,ending=''):
  code='import sys\nfor line in sys.stdin:\n print(\'{"value":1}\', flush=True)\n'+ending
  return [sys.executable,'-u','-c',code]
 def test_clean_process_receipt(self):
  self.assertEqual(execute(self.command(),[{},{}]),[{'value':1},{'value':1}])
  report={};rows=finish_clients(report,timeout=2);self.assertEqual(rows,report['nativeProcesses'])
  self.assertEqual(rows[0]['exitCode'],0);self.assertEqual(rows[0]['responses'],2)
  self.assertEqual(rows[0]['stdoutSha256'],hashlib.sha256(b'{"value":1}\n'*2).hexdigest())
  self.assertEqual(rows[0]['stderrBytes'],0);self.assertEqual(rows[0]['trailingStdoutBytes'],0)
 def rejected_shutdown(self,ending):
  execute(self.command(ending),[{}]);report={}
  with self.assertRaises(RuntimeError):finish_clients(report,timeout=2)
  self.assertEqual(report['nativeProcesses'][0]['status'],'failed');return report['nativeProcesses'][0]
 def test_nonzero_exit_rejected(self):self.assertEqual(self.rejected_shutdown('sys.exit(7)')['exitCode'],7)
 def test_extra_stdout_rejected(self):
  row=self.rejected_shutdown('print(\'{"extra":true}\',flush=True)')
  self.assertEqual(row['trailingStdoutBytes'],len(b'{"extra":true}\n'))
  self.assertEqual(row['trailingStdoutSha256'],hashlib.sha256(b'{"extra":true}\n').hexdigest())
 def test_late_stderr_rejected(self):
  row=self.rejected_shutdown('print("late error",file=sys.stderr,flush=True)')
  self.assertEqual(row['stderrBytes'],len(b'late error\n'))
  self.assertEqual(row['stderrSha256'],hashlib.sha256(b'late error\n').hexdigest())
 def test_original_exit_extra_output_reproducer(self):
  row=self.rejected_shutdown('print(\'{"extra":true}\',flush=True)\nsys.exit(7)')
  self.assertEqual(row['exitCode'],7);self.assertEqual(row['trailingStdoutLines'],1)
 def test_shutdown_timeout_rejected(self):
  execute(self.command('import time; time.sleep(60)'),[{}]);report={}
  with self.assertRaises(RuntimeError):finish_clients(report,timeout=0.1)
  self.assertTrue(report['nativeProcesses'][0]['shutdownTimeout'])
 def test_query_timeout_rejected(self):
  command=[sys.executable,'-u','-c','import time; time.sleep(60)']
  with self.assertRaises(Exception):execute(command,[{}],timeout=0.1)
  rows=finish_clients(raise_errors=False,timeout=2)
  self.assertEqual(rows[0]['status'],'failed');self.assertTrue(rows[0]['queryTimeout'])
 def test_all_children_finalized_after_one_failure(self):
  execute(self.command('sys.exit(7)'),[{}]);execute(self.command(),[{}]);report={}
  with self.assertRaises(RuntimeError):finish_clients(report,timeout=2)
  self.assertEqual([r['exitCode'] for r in report['nativeProcesses']],[7,0])
  self.assertEqual(finish_clients(),[])
 def test_strict_native_json(self):
  for value in ['{"value":1,"value":2}','{"value":NaN}']:
   with self.subTest(value=value):
    command=[sys.executable,'-u','-c','import sys; sys.stdin.readline(); print('+repr(value)+',flush=True)']
    with self.assertRaises((ValueError,RuntimeError)):execute(command,[{}])
    finish_clients(raise_errors=False,timeout=2)
 def test_fnc1_exact_fixture_outcomes(self):
  root=pathlib.Path(__file__).resolve().parents[1]
  vectors=json.loads((root/'verification/fixtures/expected-contract-vectors.json').read_text())['vectors']
  expected=[expected_fnc1_outcome(v) for v in vectors]
  self.assertEqual([expected.count(x) for x in ['success','INVALID_MODE','DATA_TOO_LONG']],[44,34,24])
  # The old blanket-error branch accepted all 68 non-alpha failures. These 44
  # independently fitting vectors must now reject that false-pass control.
  for vector in vectors:
   if expected_fnc1_outcome(vector)=='success':
    with self.subTest(vector=vector['id']),self.assertRaises(RuntimeError):
     check_fnc1_outcome(vector,{'error':'specqr_data_too_long','code':'DATA_TOO_LONG'})
   else:
    with self.subTest(vector=vector['id']),self.assertRaises(RuntimeError):check_fnc1_outcome(vector,{})

class AuxiliaryProcessTests(unittest.TestCase):
 """Actual Python subprocess controls, never simulated Nim or decoder evidence."""
 def command(self,stdout=b'',stderr=b'',code=0):
  script='import sys; sys.stdout.buffer.write('+repr(stdout)+'); sys.stdout.flush(); sys.stderr.buffer.write('+repr(stderr)+'); sys.stderr.flush(); raise SystemExit('+str(code)+')'
  return [sys.executable,'-u','-c',script]
 def reject(self,command,validator=None,timeout=2):
  report={'status':'passed'}
  with self.assertRaises(Exception):run_auxiliary(command,report,'negative-control',validator=validator,timeout=timeout)
  self.assertEqual(report['status'],'failed');self.assertEqual(report['auxiliaryProcesses'][0]['status'],'failed')
  return report['auxiliaryProcesses'][0]
 def test_binary_stdout_preserved(self):
  data=bytes([0,29,128,255,10]);report={}
  self.assertEqual(run_auxiliary(self.command(data),report,'binary'),data)
  row=report['auxiliaryProcesses'][0]
  self.assertEqual(row['stdoutBytes'],len(data));self.assertEqual(row['stdoutSha256'],hashlib.sha256(data).hexdigest())
  self.assertEqual(row['stderrBytes'],0);self.assertEqual(row['exitCode'],0)
 def test_stderr_rejects_exit_zero(self):
  row=self.reject(self.command(b'valid',b'warning\n'))
  self.assertEqual(row['exitCode'],0);self.assertEqual(row['stderrBytes'],8)
  self.assertEqual(row['stderrSha256'],hashlib.sha256(b'warning\n').hexdigest())
 def test_nonzero_exit_recorded(self):
  row=self.reject(self.command(b'valid',code=7));self.assertEqual(row['exitCode'],7)
  self.assertEqual(row['stdoutSha256'],hashlib.sha256(b'valid').hexdigest())
 def test_timeout_retains_partial_output(self):
  command=[sys.executable,'-u','-c','import sys,time; print("partial",flush=True); time.sleep(30)']
  row=self.reject(command,timeout=0.1);self.assertTrue(row['timeout']);self.assertEqual(row['stdoutBytes'],8)
 def test_json_record_count_and_syntax(self):
  for output in [b'',b'bad',b'{}\n{}\n',b'{"x":1,"x":2}\n',b'{"x":NaN}\n',b'[]\n']:
   with self.subTest(output=output):self.reject(self.command(output),lambda data:json_records(data,1))
  self.assertEqual(run_auxiliary(self.command(b'{"x":1}\n'),{},'json',validator=lambda data:json_records(data,1)),[{'x':1}])
 def png(self):
  def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
  return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(b'\x00\x00\x00\x00\xff'))+chunk(b'IEND',b'')
 def test_raster_output_framing(self):
  png=self.png();self.assertEqual(run_auxiliary(self.command(png),{},'png',validator=png_stream),png)
  badcrc=bytearray(png);badcrc[-1]^=1
  for output in [b'not png',png[:-1],png+b'extra output',bytes(badcrc)]:
   with self.subTest(length=len(output)):self.reject(self.command(output),png_stream)
 def test_version_output_controls(self):
  validator=lambda data:version_text(data,'rsvg-convert ',single_line=True)
  self.assertEqual(run_auxiliary(self.command(b'rsvg-convert version 1\n'),{},'version',validator=validator),'rsvg-convert version 1')
  for output in [b'',b'wrong version',b'rsvg-convert version 1\nextra\n']:
   with self.subTest(output=output):self.reject(self.command(output),validator)
 def test_heap_probe_exact_output(self):
  validator=lambda data:exact_number(data,1024)
  self.assertEqual(run_auxiliary(self.command(b'1024'),{},'heap',validator=validator),1024)
  for output in [b'1024\nextra',b'NaN',b'Inf',b'512']:
   with self.subTest(output=output):self.reject(self.command(output),validator)
 def test_launch_failure_recorded(self):
  row=self.reject(['/this-harness-path-does-not-exist/specqr-control'])
  self.assertIsNone(row['exitCode']);self.assertEqual(row['stdoutBytes'],0)

if __name__=='__main__':unittest.main()
