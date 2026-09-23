"""Explicit developer fixture download; does not install or initialize the GUI app."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.request

root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / 'Sources/WithinApp/Resources/model-manifest.json').read_text())
destination = root / '.development/models/parakeet-tdt-0.6b-v3-coreml'
def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()
def download(item):
    target = destination / item['path']
    if target.exists() and target.stat().st_size == item['size'] and sha(target) == item['sha256']:
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + '.partial')
    url = f'https://huggingface.co/{manifest["repository"]}/resolve/{manifest["revision"]}/{item["path"]}'
    try:
        with urllib.request.urlopen(url, timeout=180) as response, temporary.open('wb') as stream:
            while chunk := response.read(1024 * 1024):
                stream.write(chunk)
                if stream.tell() > item['size']:
                    raise ValueError('Unexpected artifact size')
        assert temporary.stat().st_size == item['size'] and sha(temporary) == item['sha256'], item['path']
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    list(pool.map(download, manifest['files']))
print(f'Verified {len(manifest["files"])} pinned model artifacts in the development fixture directory.')
