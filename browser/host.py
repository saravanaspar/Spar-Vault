#!/usr/bin/env python3
"""Bounded native-messaging transport. No credential logging or persistence."""
import http.client
import json
import os
from pathlib import Path
import stat
import struct
import sys
import time

HOST_NAME = 'com.bnstechsystems.spar_vault'
MAX_FRAME = 8192

def read_frame(stream):
    size = stream.read(4)
    if not size:
        return None
    if len(size) != 4:
        raise ValueError('truncated')
    count, = struct.unpack('<I', size)
    if count > MAX_FRAME or count == 0:
        raise ValueError('bounded')
    data = stream.read(count)
    if len(data) != count:
        raise ValueError('truncated')
    return json.loads(data)

def write_frame(stream, value):
    encoded = json.dumps(value, separators=(',', ':')).encode()
    if len(encoded) > MAX_FRAME:
        encoded = b'{"error":"response too large"}'
    stream.write(struct.pack('<I', len(encoded)) + encoded)
    stream.flush()

def private_json(path):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > 4096:
        raise ValueError('invalid state')
    if os.name != 'nt' and (info.st_uid != os.getuid() or info.st_mode & 0o077):
        raise ValueError('private file required')
    with path.open('r', encoding='utf8') as f:
        return json.load(f)

def handle(request, config, caller):
    extension = config['extensionId']
    if caller != f'chrome-extension://{extension}/':
        raise ValueError('wrong caller')
    if not isinstance(request, dict) or set(request) != {'nonce', 'origin'}:
        raise ValueError('request fields')
    import re
    from urllib.parse import urlsplit
    if not isinstance(request['nonce'], str) or not re.fullmatch('[a-f0-9]{32}', request['nonce']):
        raise ValueError('nonce')
    origin = request['origin']
    if not isinstance(origin, str) or len(origin) > 2000:
        raise ValueError('origin')
    url = urlsplit(origin)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.path or url.query or url.fragment:
        raise ValueError('HTTPS origin')
    state = private_json(config['stateFile'])
    if state['extensionId'] != extension or type(state['port']) is not int or not 1024 <= state['port'] <= 65535 or state['expiresAt'] <= time.time()*1000:
        raise ValueError('expired binding')
    if not isinstance(state['token'],str) or not re.fullmatch('[A-Za-z0-9_-]{43}=',state['token']):
        raise ValueError('token')
    connection = http.client.HTTPConnection('127.0.0.1',state['port'],timeout=48)
    try:
        connection.request('POST','/fill',json.dumps(request),{'Authorization':'Bearer '+state['token'],'X-Extension-ID':extension,'Content-Type':'application/json'})
        response=connection.getresponse();data=response.read(MAX_FRAME+1)
        if response.status!=200 or len(data)>MAX_FRAME:
            raise ValueError('refused')
        reply=json.loads(data)
        if reply.get('nonce')!=request['nonce'] or reply.get('origin')!=origin:
            raise ValueError('response binding')
        return reply
    finally:
        connection.close()

def main():
    # Chrome supplies the verified allowed_origin as the first process argument.
    # The adjacent installer config also restricts it to exactly one ID.
    config_path=Path(sys.executable if getattr(sys,'frozen',False) else __file__).resolve().with_name('host-config.json')
    try:
        config=private_json(config_path);caller=sys.argv[1] if len(sys.argv)>1 else ''
        while (request:=read_frame(sys.stdin.buffer)) is not None:
            try:reply=handle(request,config,caller)
            except Exception:reply={'error':'Autofill unavailable, refused or expired'}
            write_frame(sys.stdout.buffer,reply)
    except Exception:
        write_frame(sys.stdout.buffer,{'error':'Host binding unavailable'})

if __name__=='__main__':main()
