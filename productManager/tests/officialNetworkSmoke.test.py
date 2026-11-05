#!/usr/bin/env python3
"""Real official resolver requests via the product core; no installer/game download."""
import json
import subprocess
import sys

manager = sys.argv[1]
failed = False
for product in ('mainland', 'global'):
    result = subprocess.run([manager, 'agent', 'run', 'resolve-download', '--product', product], text=True, capture_output=True, timeout=90)
    events = [json.loads(line) for line in result.stdout.splitlines()]
    task_id = events[0]['taskId']
    task = json.loads(subprocess.check_output([manager, 'agent', 'task', task_id], text=True))
    output = task.get('output', {})
    summary = dict(product=product, state=task['state'], exitCode=result.returncode,
                   finalHost=output.get('finalHost'), filename=output.get('filename'),
                   gamePayloadDownloaded=False)
    if result.returncode != 0:
        summary['diagnostic'] = json.loads(subprocess.check_output([manager, 'agent', 'logs', task_id, 'stderr'], text=True))['text']
        failed = True
    print(json.dumps(summary, ensure_ascii=False))
sys.exit(1 if failed else 0)
