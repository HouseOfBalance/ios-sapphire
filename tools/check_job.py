import urllib.request, json, sys

run_id = sys.argv[1] if len(sys.argv) > 1 else '41302637147'
url = f'https://api.github.com/repos/HouseOfBalance/ios-sapphire/actions/runs/{run_id}/jobs'
req = urllib.request.Request(url, headers={'User-Agent': 'Python-GH-Check'})
try:
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read().decode())
        for job in data.get('jobs', []):
            print(f"Job {job['name']}: {job['status']} ({job['conclusion']})")
            for step in job.get('steps', []):
                print(f"  Step '{step['name']}': {step['status']} ({step['conclusion']})")
except Exception as e:
    print("Error:", e)
