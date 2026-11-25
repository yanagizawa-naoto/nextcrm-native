#!/usr/bin/env python3
"""Private mail parser C build; consumes checked-in entities without regeneration."""
from pathlib import Path
import argparse,hashlib,json,re,subprocess
HTML_INPUTS=('NativeMailHTMLText.swift','NativeMailParsing.h','CampaignHTML.c','CampaignHTML.h','CampaignHTMLEntities.inc','native_mail_build.py')
def html_inputs(native):return [native/name for name in HTML_INPUTS]
def html_object(native,output,run=None):
    sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
    command=['xcrun','clang','-O2','-Wall','-Wextra','-Werror','-target','arm64-apple-macos13.0','-isysroot',sdk,'-I',sdk+'/usr/include/libxml2','-c',str(native/'CampaignHTML.c'),'-o',str(output)]
    if run is None:subprocess.run(command,check=True)
    else:run('html-c-object',command)
    return output
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser();parser.add_argument('mode',choices=['build','verify']);parser.add_argument('native',type=Path);parser.add_argument('output',type=Path);parser.add_argument('runner',type=Path);parser.add_argument('--exit',type=int,default=0);a=parser.parse_args()
    native=a.native.resolve();out=a.output.resolve();proof=out/'build-inputs.json'
    if a.mode=='build':
        assert out.is_dir() and out != native/'build', 'Use a caller-owned private subdirectory'
        sources=re.findall(r'\$native_dir/([^"/\s]+\.swift)',a.runner.read_text())
        paths=list(dict.fromkeys(html_inputs(native)+[native/x for x in sources]+[native/'NativeMailTransport.c',native/'NativeMailTransport.h',a.runner.resolve()]))
        before={str(p):sha(p) for p in paths};proof.write_text(json.dumps({'inputsSHA256':before,'complete':False},indent=2)+'\n')
        subprocess.run(['xcrun','clang','-std=c11','-O2','-Wall','-Wextra','-Werror','-c',str(native/'NativeMailTransport.c'),'-o',str(out/'NativeMailTransport.o')],check=True)
        html_object(native,out/'CampaignHTML.o')
    else:
        value=json.loads(proof.read_text());value['inputsUnchanged']=all(sha(Path(p))==h for p,h in value['inputsSHA256'].items());value['runnerExit']=a.exit;value['complete']=a.exit==0 and value['inputsUnchanged'];value['objectsSHA256']={p.name:sha(p) for p in out.glob('*.o')};proof.write_text(json.dumps(value,indent=2)+'\n');assert value['inputsUnchanged'],'Mail build inputs changed'
if __name__=='__main__':main()
