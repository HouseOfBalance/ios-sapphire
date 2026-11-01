import os, sys, json, subprocess, urllib.request, zipfile

def get_token():
    git_path = r'C:\Program Files\Git\cmd\git.exe'
    proc = subprocess.Popen([git_path, 'credential', 'fill'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    stdout, _ = proc.communicate('protocol=https\nhost=github.com\n\n')
    for line in stdout.splitlines():
        if line.startswith('password='):
            return line.split('=', 1)[1]
    return ''

class NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new_req = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new_req and 'github.com' not in newurl.lower():
            if 'Authorization' in new_req.headers:
                del new_req.headers['Authorization']
            if 'authorization' in new_req.headers:
                del new_req.headers['authorization']
        return new_req

def download_run_artifact(run_id, out_dir='artifacts'):
    token = get_token()
    headers = {'Authorization': f'Bearer {token}', 'User-Agent': 'Mozilla/5.0'}
    
    url = f'https://api.github.com/repos/HouseOfBalance/ios-sapphire/actions/runs/{run_id}/artifacts'
    req = urllib.request.Request(url, headers=headers)
    resp = urllib.request.urlopen(req)
    data = json.loads(resp.read().decode('utf-8'))
    
    artifacts = data.get('artifacts', [])
    print(f"Found {len(artifacts)} artifacts for run {run_id}")
    os.makedirs(out_dir, exist_ok=True)
    
    opener = urllib.request.build_opener(NoAuthRedirect)
    
    downloaded = []
    for art in artifacts:
        name = art['name']
        art_id = art['id']
        dl_url = art['archive_download_url']
        zip_path = os.path.join(out_dir, f"{name}.zip")
        extract_dir = os.path.join(out_dir, name)
        
        print(f"Downloading {name} (id={art_id}, size={art['size_in_bytes']} bytes)...")
        req_dl = urllib.request.Request(dl_url, headers=headers)
        with opener.open(req_dl) as res, open(zip_path, 'wb') as f:
            while True:
                chunk = res.read(65536)
                if not chunk:
                    break
                f.write(chunk)
        print(f"Saved to {zip_path}")
        
        with zipfile.ZipFile(zip_path, 'r') as z:
            z.extractall(extract_dir)
        print(f"Extracted to {extract_dir}")
        downloaded.append((name, extract_dir))
    return downloaded

if __name__ == '__main__':
    run_id = sys.argv[1] if len(sys.argv) > 1 else '41325603836'
    download_run_artifact(run_id)
