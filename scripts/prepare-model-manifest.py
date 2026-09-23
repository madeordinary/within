"""Developer-only: pin public model artifacts. Never called by the application.

Metadata is read from a previously fetched official API response. Small Git blobs
are independently matched to their recorded Git object ID; LFS hashes are preserved.
The resulting full SHA-256 manifest is bundled in the built app, not fetched at runtime.
"""
import hashlib
import json
from pathlib import Path
import urllib.request

root = Path(__file__).resolve().parent.parent
metadata = json.loads((root / '.development/research/parakeet-model-metadata.json').read_text())
revision = metadata['sha']
assert revision == '7dd20fe6b1797d35f5e3307e8b1732d9a178edfe'
components = {'Preprocessor.mlmodelc', 'Encoder_v2.mlmodelc', 'Decoder.mlmodelc', 'JointDecisionv3.mlmodelc', 'parakeet_vocab.json'}
files = []
cache = root / '.development/models/parakeet-tdt-0.6b-v3-coreml'
for entry in metadata['siblings']:
    name = entry['rfilename']
    if name.split('/')[0] not in components:
        continue
    digest = entry.get('lfs', {}).get('sha256')
    if not digest:
        url = f'https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/{revision}/{name}'
        data = urllib.request.urlopen(url, timeout=90).read()
        assert len(data) == entry['size']
        git_digest = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
        assert git_digest == entry['blobId'], name
        digest = hashlib.sha256(data).hexdigest()
        target = cache / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    files.append({'path': name, 'size': entry['size'], 'sha256': digest})
manifest = {
    'schema': 1,
    'name': 'Parakeet TDT v3 · English',
    'repository': 'FluidInference/parakeet-tdt-0.6b-v3-coreml',
    'revision': revision,
    'license': 'CC-BY-4.0',
    'licenseURL': 'https://creativecommons.org/licenses/by/4.0/',
    'sourceURL': 'https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml',
    'encoder': 'int8-v2',
    'files': sorted(files, key=lambda f: f['path'])
}
output = root / 'Sources/WithinApp/Resources/model-manifest.json'
output.write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Pinned {len(files)} artifacts; {sum(f["size"] for f in files):,} bytes. Small metadata artifacts verified against Git object IDs.')
