#!/usr/bin/env python3
"""Fetch an immutable official Luau revision. MIT. Python >= 3.12."""
import argparse
import json
import os
import pathlib
import re
import shutil
import tarfile
import tempfile
import urllib.request

API = 'https://api.github.com/repos/luau-lang/luau'
ROOT = pathlib.Path(__file__).resolve().parents[1]


def api(path):
    headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'ouro-release-check'}
    if os.environ.get('GH_TOKEN'):
        headers['Authorization'] = 'Bearer ' + os.environ['GH_TOKEN']
    request = urllib.request.Request(API + path, headers=headers)
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def latest():
    release = api('/releases/latest')
    tag = release['tag_name']
    if release['draft'] or release['prerelease'] or not re.fullmatch(r'\d+\.\d+', tag):
        raise ValueError('Expected a stable official release')
    commit = api('/commits/' + tag)['sha']
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Expected a full commit SHA')
    return {'version': tag, 'commit': commit, 'repository': 'https://github.com/luau-lang/luau',
            'license': 'MIT', 'publishedAt': release['published_at']}


def fetch(commit, output):
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Expected a full commit SHA')
    if output.exists():
        raise ValueError('Destination already exists: ' + str(output))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='ouro-source-', dir=output.parent) as temp:
        temp = pathlib.Path(temp)
        archive = temp / 'source.tar.gz'
        request = urllib.request.Request('https://codeload.github.com/luau-lang/luau/tar.gz/' + commit,
                                         headers={'User-Agent': 'ouro-release-check'})
        with urllib.request.urlopen(request, timeout=60) as response, archive.open('wb') as target:
            shutil.copyfileobj(response, target)
        with tarfile.open(archive) as tar:
            tar.extractall(temp / 'source', filter='data')
        entries = list((temp / 'source').iterdir())
        if len(entries) != 1 or not (entries[0] / 'Ast/src/Parser.cpp').is_file():
            raise ValueError('Unexpected upstream archive')
        shutil.move(str(entries[0]), output)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=pathlib.Path, required=True)
    args = ap.parse_args()
    pin = json.loads((ROOT / 'UPSTREAM.json').read_text())
    fetch(pin['commit'], args.output)
    print(args.output)


if __name__ == '__main__':
    main()
