import urllib.request, json
req = urllib.request.Request('http://localhost:8000/predict', method='POST', headers={'Content-Type': 'application/json'}, data=b'{"prompt": "hello"}')
print(json.loads(urllib.request.urlopen(req).read())['trace_id'])
