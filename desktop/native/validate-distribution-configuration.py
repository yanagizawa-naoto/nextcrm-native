#!/usr/bin/env python3
"""Validate public distribution metadata. Never accept secrets or user tokens."""
from pathlib import Path
import argparse,json,re,sys
MAXIMUM_BYTES=16_384

def validate(data):
    if len(data)>MAXIMUM_BYTES:raise ValueError('configuration size')
    value=json.loads(data)
    if not isinstance(value,dict) or set(value)!={'version','google'}:raise ValueError('configuration keys')
    if isinstance(value['version'],bool) or not isinstance(value['version'],(int,float)) or value['version']!=1:raise ValueError('configuration version')
    google=value['google']
    if google is not None:
        if not isinstance(google,dict) or set(google)!={'desktopClientID'}:raise ValueError('Google keys')
        client=google['desktopClientID']
        if not isinstance(client,str) or len(client.encode('utf-8'))>512 or re.fullmatch(r'[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com',client) is None:raise ValueError('Google desktop client ID')
    return value

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('configuration',type=Path)
    parser.add_argument('--output',type=Path,help='New bundle resource path; refuses an existing file')
    parser.add_argument('--require-google',action='store_true',help='Fail when Google login is not configured')
    args=parser.parse_args()
    try:
        with args.configuration.open('rb') as stream:value=validate(stream.read(MAXIMUM_BYTES+1))
        if args.require_google and value['google'] is None:raise ValueError('Google missing')
        if args.output:
            with args.output.open('xb') as stream:stream.write((json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode())
    except (ValueError,OSError,UnicodeError):
        print('配布設定を確認してください。version 1 と google.desktopClientID のみ使用でき、secret・token・Web用設定は同梱できません。',file=sys.stderr)
        return 1
    print('配布設定: Googleログイン設定あり（公開IDのみ）' if value['google'] else '配布設定: Googleログイン未設定')
    return 0
if __name__=='__main__':sys.exit(main())
