#!/usr/bin/env python3
"""Install a single-ID native messaging host for this OS user only."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import sys

NAME='com.bnstechsystems.spar_vault'
def private_write(path,text):
    path.parent.mkdir(parents=True,exist_ok=True)
    if os.name!='nt':path.parent.chmod(0o700)
    # Refuse links: do not overwrite arbitrary files through install paths.
    if path.is_symlink():raise ValueError('Refusing a symbolic link')
    with path.open('w',encoding='utf8') as f:f.write(text)
    if os.name!='nt':path.chmod(0o600)
def main():
    p=argparse.ArgumentParser();p.add_argument('--extension-id',required=True);p.add_argument('--state-file',required=True);p.add_argument('--host-executable',help='Windows requires a locally built native host .exe');a=p.parse_args()
    if not re.fullmatch('[a-p]{32}',a.extension_id):p.error('Use the ID from chrome://extensions')
    state=Path(a.state_file).expanduser().absolute()
    root=Path(os.environ['LOCALAPPDATA'])/'SparVault'/'BrowserHost' if os.name=='nt' else Path.home()/'.local'/'share'/'spar-vault'/'browser-host'
    root.mkdir(parents=True,exist_ok=True)
    if os.name!='nt':root.chmod(0o700)
    private_write(root/'host-config.json',json.dumps({'extensionId':a.extension_id,'stateFile':str(state)}))
    if os.name=='nt':
        if not a.host_executable or not Path(a.host_executable).is_file():p.error('Build host.py with PyInstaller and pass --host-executable path/to/spar_native_host.exe')
        host=root/'spar_native_host.exe';shutil.copyfile(a.host_executable,host)
    else:
        host=root/'spar_native_host';source=Path(__file__).with_name('host.py').read_text();source=source.replace('#!/usr/bin/env python3','#!'+sys.executable,1);private_write(host,source);host.chmod(0o700)
    manifest={'name':NAME,'description':'Spar Vault confirmed local autofill','path':str(host),'type':'stdio','allowed_origins':[f'chrome-extension://{a.extension_id}/']}
    if os.name=='nt':
        import winreg
        target=root/(NAME+'.json');private_write(target,json.dumps(manifest))
        for vendor in ['Google\\Chrome','Microsoft\\Edge','Chromium']:
            with winreg.CreateKey(winreg.HKEY_CURRENT_USER,'Software\\'+vendor+'\\NativeMessagingHosts\\'+NAME) as key:winreg.SetValueEx(key,'',0,winreg.REG_SZ,str(target))
    else:
        for profile in ['google-chrome','chromium','microsoft-edge']:
            target=Path.home()/'.config'/profile/'NativeMessagingHosts'/(NAME+'.json');private_write(target,json.dumps(manifest))
    print('Native host installed for this user and extension ID. Restart the browser.')
if __name__=='__main__':main()
