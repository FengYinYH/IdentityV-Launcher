#!/usr/bin/env python3
"""Actual Agent transport + mock GUI backend; never replaces an installed App."""
import fcntl,hashlib,json,os,pathlib,shutil,subprocess,sys,tempfile,time
with tempfile.TemporaryDirectory() as tmp:
    root=pathlib.Path(tmp).resolve(); home=root/'home'; home.mkdir()
    resources=root/'Fixture.app/Contents/Resources'; resources.mkdir(parents=True)
    manager=resources/'IdentityVProductManager'; shutil.copy2(sys.argv[1],manager)
    gui=root/'Fixture.app/Contents/MacOS/IdentityVLauncher'; gui.parent.mkdir()
    gui.write_text('#!'+sys.executable+'\n'+'''import json,os,sys,time,uuid
assert sys.argv[1]=='--launcher-agent-operation'
uuid.UUID(os.environ['IDENTITYV_AGENT_TASK_ID'])
if sys.argv[2]=='launcher-update-check':
 print(json.dumps({'available':False,'taskId':os.environ['IDENTITYV_AGENT_TASK_ID']}));sys.exit(0)
print(json.dumps({'event':'agent-state','state':'awaiting_confirmation'}),file=sys.stderr,flush=True)
time.sleep(1)
print(json.dumps({'event':'agent-state','state':'running'}),file=sys.stderr,flush=True)
print(json.dumps({'event':'progress','phase':'applying','cancellable':False}),file=sys.stderr,flush=True)
time.sleep(1)
print(json.dumps({'installed':True,'cleanupComplete':True}))
''');gui.chmod(0o755)
    env=os.environ.copy();env['HOME']=str(home);env['IDENTITYV_AGENT_TASK_ROOT']=str(root/'tasks')
    def call(*args,executable=manager):
        p=subprocess.run([str(executable),'agent',*args],env=env,text=True,capture_output=True)
        assert p.returncode==0,(args,p.stdout,p.stderr)
        return [json.loads(x) for x in p.stdout.splitlines()]
    def wait(task,predicate):
        for _ in range(150):
            record=call('task',task)[0]
            if predicate(record):return record
            time.sleep(.05)
        raise AssertionError(record)
    system_temp=pathlib.Path(subprocess.check_output(['/usr/bin/getconf','DARWIN_USER_TEMP_DIR'],text=True).strip()).resolve()
    app_identity=str((root/'Fixture.app').resolve())
    lease_directory=system_temp/'IdentityVLauncherLeases'/hashlib.sha256(app_identity.encode()).hexdigest()
    lease=lease_directory/'launcher-operation-admission.lock'
    lease.parent.mkdir(parents=True,mode=0o700,exist_ok=True)
    with lease.open('w') as fd:
        lease.chmod(0o600);fcntl.flock(fd,fcntl.LOCK_EX)
        task=call('start','launcher-update-check')[0]['taskId']
        record=wait(task,lambda x:x['state']=='failed')
        assert record['errorCode']=='launcher_update_busy'
        # Same App resources stay protected even with an isolated business HOME.
        second_home=root/'second-home';second_home.mkdir();env['HOME']=str(second_home)
        task=call('start','launcher-update-check')[0]['taskId']
        assert wait(task,lambda x:x['state']=='failed')['errorCode']=='launcher_update_busy'
        alternate_temp=root/'different-temp';alternate_temp.mkdir()
        env['TMPDIR']=str(alternate_temp)
        task=call('start','launcher-update-check')[0]['taskId']
        assert wait(task,lambda x:x['state']=='failed')['errorCode']=='launcher_update_busy'
        env['HOME']=str(home)
        if 'TMPDIR' in os.environ: env['TMPDIR']=os.environ['TMPDIR']
        else: env.pop('TMPDIR',None)
        alias=root/'Alias.app';alias.symlink_to(root/'Fixture.app',target_is_directory=True)
        task=call('start','launcher-update-check',executable=alias/'Contents/Resources/IdentityVProductManager')[0]['taskId']
        assert wait(task,lambda x:x['state']=='failed')['errorCode']=='launcher_update_busy'
        other_app=root/'Different.app';shutil.copytree(root/'Fixture.app',other_app)
        task=call('start','launcher-update-check',executable=other_app/'Contents/Resources/IdentityVProductManager')[0]['taskId']
        assert wait(task,lambda x:x['state']=='succeeded')['output']['taskId']==task
        other_lease=system_temp/'IdentityVLauncherLeases'/hashlib.sha256(str(other_app.resolve()).encode()).hexdigest()
        shutil.rmtree(other_lease)
    task=call('start','launcher-update-check')[0]['taskId']
    record=wait(task,lambda x:x['state']=='succeeded')
    assert record['output']['taskId']==task
    task=call('start','launcher-update-install')[0]['taskId']
    record=wait(task,lambda x:x['state']=='awaiting_confirmation')
    assert record['state']!='succeeded'
    call('cancel',task)
    assert wait(task,lambda x:x['state']=='cancelled')['exitCode']==130
    task=call('start','launcher-update-install')[0]['taskId']
    record=wait(task,lambda x:x.get('cancellable') is False)
    assert record['state']=='running'
    call('cancel',task)
    record=wait(task,lambda x:x['state']=='succeeded')
    assert record['output']=={'installed':True,'cleanupComplete':True}
    assert any(x['event']=='cancellation_too_late' for x in call('events',task))
    shutil.rmtree(lease_directory)
print('Updater Agent routing/UUID/live admission/confirmation/late-cancel/result tests passed (mock GUI only).')
